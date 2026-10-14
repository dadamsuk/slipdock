defmodule Slipdock.Google do
  @moduledoc """
  A person's Google Drive connection (W-1690): the OAuth authorization-code
  flow that makes one, the tokens it leaves behind, and the access token the
  Drive client (`Slipdock.Google.Drive`) asks for on each call.

  The operator registers an OAuth client in Google Cloud and gives the server
  its id and secret (`GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`, read into
  `config :slipdock, :google`). Without them the feature is not there at all:
  `configured?/0` is false and the account page shows nothing.

  The scope is `drive.readonly` and nothing else, asked for with
  `access_type=offline` and `prompt=consent` so Google always hands back a
  refresh token. That token, and each access token traded for it, are stored
  encrypted with a key derived from the endpoint's `secret_key_base`, so a
  copy of the database alone does not open anybody's Drive. A refresh Google
  refuses (`invalid_grant`: the person removed the app, or an admin did)
  marks the connection revoked rather than deleting it, so the account page
  can say what happened.

  Tokens are never logged; `Slipdock.Google.Connection` redacts them.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Google.Connection
  alias Slipdock.Repo

  @scope "https://www.googleapis.com/auth/drive.readonly"
  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @revoke_url "https://oauth2.googleapis.com/revoke"
  @about_url "https://www.googleapis.com/drive/v3/about"
  @encryption_salt "google connection token"
  # An access token is traded in a little before Google says it expires, so
  # one cannot run out between being handed over and being used.
  @expiry_skew_seconds 60

  def scope, do: @scope

  @doc "Whether the operator has given the server an OAuth client."
  def configured?, do: present?(config()[:client_id]) and present?(config()[:client_secret])

  @doc """
  The Google consent screen to send a person to, carrying `state` (checked on
  the way back) and the `redirect_uri` Google will send them back to.
  """
  def authorize_url(state, redirect_uri) do
    query =
      URI.encode_query(%{
        "client_id" => config()[:client_id],
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => @scope,
        "access_type" => "offline",
        "prompt" => "consent",
        "include_granted_scopes" => "true",
        "state" => state
      })

    @authorize_url <> "?" <> query
  end

  @doc """
  Trades the `code` Google sent back for tokens, and stores them as `user`'s
  connection, replacing any earlier one. `{:ok, connection}`, or
  `{:error, message}` in words the account page can show.
  """
  def connect(%User{} = user, code, redirect_uri) when is_binary(code) do
    with {:ok, tokens} <-
           token_request(%{
             "grant_type" => "authorization_code",
             "code" => code,
             "redirect_uri" => redirect_uri
           }),
         {:ok, refresh} <- refresh_token(tokens),
         {:ok, access} <- access_token_from(tokens) do
      email = connected_as(access)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        user_id: user.id,
        email: email,
        refresh_token: encrypt(refresh),
        access_token: encrypt(access),
        access_expires_at: expires_at(tokens),
        revoked_at: nil,
        inserted_at: now,
        updated_at: now
      }

      Repo.insert(struct(Connection, attrs),
        on_conflict:
          {:replace,
           [:email, :refresh_token, :access_token, :access_expires_at, :revoked_at, :updated_at]},
        conflict_target: :user_id,
        returning: true
      )
    end
  end

  def connect(_user, _code, _redirect_uri), do: {:error, "Google sent no authorization code."}

  defp refresh_token(%{"refresh_token" => token}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp refresh_token(_),
    do: {:error, "Google did not hand back a refresh token, so the connection could not be kept."}

  defp access_token_from(%{"access_token" => token}) when is_binary(token), do: {:ok, token}
  defp access_token_from(_), do: {:error, "Google did not hand back an access token."}

  # Who the person connected as, for the account page. Asked of Drive itself,
  # which the read-only scope allows, rather than widening the scope for it.
  defp connected_as(access) do
    case Req.get(req(), url: @about_url, params: [fields: "user"], auth: {:bearer, access}) do
      {:ok, %{status: 200, body: %{"user" => %{"emailAddress" => email}}}} -> email
      _ -> nil
    end
  end

  @doc "`user`'s connection, revoked or not, or nil."
  def connection(%User{id: id}), do: connection(id)
  def connection(user_id) when is_integer(user_id), do: Repo.get_by(Connection, user_id: user_id)
  def connection(_), do: nil

  @doc """
  Where `user` stands: `:not_configured` (no OAuth client on this server),
  `:not_connected`, `:revoked`, or `{:connected, email}`.
  """
  def status(user) do
    if configured?() do
      case connection(user) do
        nil -> :not_connected
        %Connection{revoked_at: %DateTime{}} -> :revoked
        %Connection{email: email} -> {:connected, email}
      end
    else
      :not_configured
    end
  end

  @doc """
  A live access token for `user` (a `%User{}` or an id): the stored one while
  it has time left, otherwise a fresh one traded for the refresh token.
  `{:error, :not_connected}` with no connection, `{:error, :revoked}` once
  Google has refused it, `{:error, :unavailable}` when Google could not be
  asked. `force: true` trades one in whatever the clock says — what the Drive
  client does when Drive turns a token down.
  """
  def access_token(user, opts \\ []) do
    case connection(user) do
      nil ->
        {:error, :not_connected}

      %Connection{revoked_at: %DateTime{}} ->
        {:error, :revoked}

      %Connection{} = c ->
        if !opts[:force] and fresh?(c),
          do: decrypt(c.access_token),
          else: refresh(c)
    end
  end

  defp fresh?(%Connection{access_token: token, access_expires_at: %DateTime{} = at})
       when is_binary(token),
       do: DateTime.compare(at, DateTime.add(DateTime.utc_now(), @expiry_skew_seconds)) == :gt

  defp fresh?(_), do: false

  defp refresh(%Connection{} = c) do
    with {:ok, refresh} <- decrypt(c.refresh_token) do
      case token_request(%{"grant_type" => "refresh_token", "refresh_token" => refresh}) do
        {:ok, %{"access_token" => access} = tokens} ->
          c
          |> Ecto.Changeset.change(
            access_token: encrypt(access),
            access_expires_at: expires_at(tokens)
          )
          |> Repo.update!()

          {:ok, access}

        {:error, :invalid_grant} ->
          mark_revoked(c)
          {:error, :revoked}

        _ ->
          {:error, :unavailable}
      end
    else
      # A token the key cannot open (the secret key base changed): as good as
      # revoked, and only connecting again mends it.
      _ ->
        mark_revoked(c)
        {:error, :revoked}
    end
  end

  defp mark_revoked(%Connection{} = c) do
    c
    |> Ecto.Changeset.change(
      revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
      access_token: nil,
      access_expires_at: nil
    )
    |> Repo.update!()
  end

  @doc """
  Ends `user`'s connection: tells Google to revoke the token (best effort —
  a token Google has already forgotten is still deleted here) and deletes it.
  """
  def disconnect(user) do
    case connection(user) do
      nil ->
        :ok

      %Connection{} = c ->
        with {:ok, token} <- decrypt(c.refresh_token) do
          Req.post(req(), url: @revoke_url, form: [token: token])
        end

        Repo.delete!(c)
        :ok
    end
  end

  # Both grants go to the same endpoint, with the client's credentials in the
  # form. Google says `invalid_grant` for a refresh token it no longer honours
  # and for a code already used or expired.
  defp token_request(form) do
    form =
      Map.merge(form, %{
        "client_id" => config()[:client_id],
        "client_secret" => config()[:client_secret]
      })

    case Req.post(req(), url: @token_url, form: form) do
      {:ok, %{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %{body: %{"error" => "invalid_grant"}}} ->
        {:error, :invalid_grant}

      {:ok, %{status: status, body: body}} ->
        {:error, "Google refused the request (#{status}#{google_error(body)})."}

      {:error, _} ->
        {:error, "Google could not be reached."}
    end
  end

  defp google_error(%{"error_description" => d}) when is_binary(d), do: ": " <> d
  defp google_error(%{"error" => e}) when is_binary(e), do: ": " <> e
  defp google_error(_), do: ""

  defp expires_at(%{"expires_in" => seconds}) when is_integer(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

  defp expires_at(_), do: DateTime.utc_now() |> DateTime.add(3000) |> DateTime.truncate(:second)

  ## Encryption ---------------------------------------------------------------

  @doc """
  `value` encrypted (AES-GCM, via `Plug.Crypto`) with a key derived from the
  endpoint's secret key base.
  """
  def encrypt(value) when is_binary(value),
    do: Plug.Crypto.encrypt(secret(), @encryption_salt, value)

  @doc "`{:ok, value}` for something `encrypt/1` made, `{:error, reason}` otherwise."
  def decrypt(nil), do: {:error, :missing}

  def decrypt(encrypted) when is_binary(encrypted),
    do: Plug.Crypto.decrypt(secret(), @encryption_salt, encrypted, max_age: :infinity)

  defp secret, do: SlipdockWeb.Endpoint.config(:secret_key_base)

  ## Plumbing -----------------------------------------------------------------

  @doc false
  def req(opts \\ []) do
    Req.new([retry: false, redirect: false] ++ opts ++ (config()[:req_options] || []))
  end

  defp config, do: Slipdock.Config.get(:google, [])

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
