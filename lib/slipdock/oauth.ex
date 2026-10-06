defmodule Slipdock.OAuth do
  @moduledoc """
  The authorization-server half of signing in from a third-party app (OAuth
  2.1): the clients that have registered themselves, the codes a person's
  approval produces, and the tokens those codes are traded for.

  What it hands out in the end is an **ordinary API token** — a `users_tokens`
  row in the `api` context, labelled with the client's name, scoped `read` or
  `write`, and expiring after an hour. The refresh token that renews it lives
  on the same row, so one connection is one row under Account → API tokens,
  and deleting that row ends it. Everything that already guards an API token
  guards these.

  The decisions behind it (which RFCs, which redirect URIs, why there is no
  client secret, why refresh tokens rotate) are on the wiki page W-21.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.{User, UserToken}
  alias Slipdock.OAuth.{Client, Code}
  alias Slipdock.Repo

  @code_seconds 60
  @access_seconds 3600
  @refresh_days 90
  # Used and expired codes are kept this long after they expire, so a code
  # replayed late is still recognised as a replay and takes its token back.
  @code_retention_seconds 3600
  # A client that registered and never got a token after this long is a
  # connection somebody abandoned. claude.ai registers afresh every time.
  @unused_client_hours 24

  def access_token_seconds, do: @access_seconds

  # ── clients ────────────────────────────────────────────────────────────

  @doc """
  Registers a client (RFC 7591). `attrs` takes `client_name`, `redirect_uris`
  and `registered_ip`; anything else a client sent has already been decided by
  the server and is not stored.
  """
  def register_client(attrs) do
    # Cheap, and it means abandoned registrations never pile up. There is no
    # scheduled job to forget to run.
    purge_unused_clients()
    attrs |> Client.registration_changeset() |> Repo.insert()
  end

  @doc "The client with this `client_id`, or nil."
  def get_client(client_id) when is_binary(client_id),
    do: Repo.get_by(Client, client_id: client_id)

  def get_client(_), do: nil

  @doc """
  Deletes clients that registered over a day ago and hold no token. A client
  with a live code is less than a minute old, so is never one of them.
  """
  def purge_unused_clients do
    cutoff = DateTime.utc_now() |> DateTime.add(-@unused_client_hours, :hour)

    {count, _} =
      Repo.delete_all(
        from(c in Client,
          as: :client,
          where: c.inserted_at < ^cutoff,
          where:
            not exists(from(t in UserToken, where: t.oauth_client_id == parent_as(:client).id))
        )
      )

    count
  end

  # ── the authorization request ──────────────────────────────────────────

  @doc """
  Checks a `GET /oauth/authorize` request, given the base URL this server was
  reached at. Three kinds of answer, because RFC 6749 §4.1.2.1 treats them
  differently:

    * `{:ok, request}` — ask the person.
    * `{:error, :invalid_client}` or `{:error, :invalid_redirect_uri}` — say
      so here and **do not redirect**: sending somebody to an address that
      was never registered is the open redirect the rules exist to prevent.
    * `{:error, {:redirect, redirect_uri, error, description}}` — the client
      is known and so is where it lives, so tell it there.
  """
  def validate_authorization(params, base) do
    with %Client{} = client <- get_client(params["client_id"]) || {:error, :invalid_client},
         {:ok, redirect_uri} <- resolve_redirect_uri(client, params["redirect_uri"]) do
      back = fn error, description -> {:error, {:redirect, redirect_uri, error, description}} end

      cond do
        params["response_type"] != "code" ->
          back.("unsupported_response_type", "only response_type=code is supported")

        params["code_challenge_method"] != "S256" or
            not valid_pkce_string?(params["code_challenge"]) ->
          back.("invalid_request", "PKCE is required, with code_challenge_method=S256")

        not valid_resource?(params["resource"], base) ->
          back.("invalid_target", "the resource must be this server's /mcp")

        true ->
          {:ok,
           %{
             client: client,
             redirect_uri: redirect_uri,
             state: params["state"],
             code_challenge: params["code_challenge"],
             scope: grant_scope(params["scope"]),
             resource: params["resource"]
           }}
      end
    end
  end

  # The redirect URI may be left out only when there is exactly one it could
  # be; otherwise it must be one that was registered.
  defp resolve_redirect_uri(%Client{redirect_uris: [only]}, nil), do: {:ok, only}

  defp resolve_redirect_uri(client, given) do
    if Client.redirect_uri_registered?(client, given),
      do: {:ok, given},
      else: {:error, :invalid_redirect_uri}
  end

  @doc """
  The scope a request is granted: `write` if it asks for write or for
  nothing, `read` otherwise. `admin` is never granted this way — whoever starts
  an OAuth request is anonymous, as with the device flow.
  """
  def grant_scope(scope) when is_binary(scope) do
    words = String.split(scope)

    cond do
      words == [] -> "write"
      "write" in words -> "write"
      true -> "read"
    end
  end

  def grant_scope(_), do: "write"

  # RFC 8707: clients name what they want a token for. This server is the
  # only resource it issues tokens for, so the answer is either that or no.
  defp valid_resource?(nil, _base), do: true

  defp valid_resource?(resource, base),
    do: resource in [base <> "/mcp", base, base <> "/"]

  # RFC 7636 §4.1: 43 to 128 characters from the unreserved set. A challenge
  # is the same shape, being a base64url SHA-256.
  defp valid_pkce_string?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9\-._~]{43,128}\z/, value)

  defp valid_pkce_string?(_), do: false

  @doc """
  Records a person's approval of `request` as a code, and returns the code to
  hand back to the client. `scope` is what they approved, which may be less
  than was asked for but never more.
  """
  def issue_code(%User{} = user, request, scope \\ nil) do
    purge_old_codes()
    raw = :crypto.strong_rand_bytes(32)
    scope = if request.scope == "write" and scope != "read", do: "write", else: "read"

    Repo.insert!(%Code{
      code_hash: hash(raw),
      client_id: request.client.id,
      user_id: user.id,
      redirect_uri: request.redirect_uri,
      code_challenge: request.code_challenge,
      scope: scope,
      resource: request.resource,
      expires_at: DateTime.utc_now(:second) |> DateTime.add(@code_seconds, :second)
    })

    encode(raw)
  end

  defp purge_old_codes do
    cutoff = DateTime.utc_now() |> DateTime.add(-@code_retention_seconds, :second)
    Repo.delete_all(from(c in Code, where: c.expires_at < ^cutoff))
  end

  # ── the token endpoint ─────────────────────────────────────────────────

  @doc """
  The `authorization_code` grant. Returns `{:ok, token_response}` or
  `{:error, error_code, description}` with the RFC 6749 §5.2 error code.

  The code is spent by the first attempt, right or wrong, so a stolen code
  cannot be tried against a list of verifiers. A code presented after it has
  been spent revokes the token it was spent on: one of the two presenting it
  is not who they say they are, and there is no telling which.
  """
  def exchange_code(params, base) do
    with {:ok, client} <- fetch_client(params["client_id"]),
         {:ok, hashed} <- decode(params["code"], "the code is not valid"),
         %Code{} = code <- Repo.get_by(Code, code_hash: hashed) || invalid_grant("unknown code"),
         :ok <- spend(code),
         :ok <- check(code.client_id == client.id, "the code was issued to another client"),
         :ok <- check(not expired?(code.expires_at), "the code has expired"),
         :ok <-
           check(
             params["redirect_uri"] in [nil, code.redirect_uri],
             "redirect_uri differs from the one the code was issued for"
           ),
         :ok <- check(pkce_ok?(params["code_verifier"], code.code_challenge), "PKCE failed"),
         :ok <- check_resource(params["resource"], base),
         %User{disabled_at: nil} = user <-
           Repo.get(User, code.user_id) || invalid_grant("the account is gone") do
      mint(user, client, code)
    else
      %User{} -> invalid_grant("the account is disabled")
      {:error, _, _} = error -> error
    end
  end

  defp spend(%Code{} = code) do
    now = DateTime.utc_now(:second)

    case Repo.update_all(from(c in Code, where: c.id == ^code.id and is_nil(c.used_at)),
           set: [used_at: now]
         ) do
      {1, _} ->
        :ok

      _ ->
        # Replayed. Take back whatever the first use got.
        token_id = Repo.one(from(c in Code, where: c.id == ^code.id, select: c.token_id))
        if token_id, do: Repo.delete_all(from(t in UserToken, where: t.id == ^token_id))
        invalid_grant("the code has already been used")
    end
  end

  defp mint(user, client, code) do
    Repo.transaction(fn ->
      {access, row} =
        UserToken.build_hashed_token(user, "api",
          label: client.client_name || "OAuth client",
          scope: code.scope,
          expires_at: access_expiry()
        )

      refresh = :crypto.strong_rand_bytes(32)

      row =
        Repo.insert!(%{
          row
          | oauth_client_id: client.id,
            refresh_token_hash: hash(refresh),
            refresh_expires_at: refresh_expiry()
        })

      Repo.update_all(from(c in Code, where: c.id == ^code.id), set: [token_id: row.id])
      token_response(access, encode(refresh), row.scope)
    end)
  end

  @doc """
  The `refresh_token` grant. Rotates both secrets on the same row: the access
  token and the refresh token presented are both dead afterwards, so a refresh
  token works once (W-21 §5).
  """
  def refresh(params) do
    now = DateTime.utc_now()

    with {:ok, client} <- fetch_client(params["client_id"]),
         {:ok, hashed} <- decode(params["refresh_token"], "the refresh token is not valid"),
         {%UserToken{} = row, %User{disabled_at: nil}} <-
           Repo.one(
             from(t in UserToken,
               join: u in assoc(t, :user),
               where: t.context == "api" and t.refresh_token_hash == ^hashed,
               where: t.oauth_client_id == ^client.id and t.refresh_expires_at > ^now,
               select: {t, u}
             )
           ) || invalid_grant("the refresh token is unknown, spent or expired") do
      rotate(row, hashed)
    else
      {%UserToken{}, %User{}} -> invalid_grant("the account is disabled")
      {:error, _, _} = error -> error
    end
  end

  defp rotate(row, old_hash) do
    access = :crypto.strong_rand_bytes(32)
    refresh = :crypto.strong_rand_bytes(32)

    # Only lands if nobody rotated it first, so two refreshes racing with the
    # same token leave one winner.
    query =
      from(t in UserToken, where: t.id == ^row.id and t.refresh_token_hash == ^old_hash)

    case Repo.update_all(query,
           set: [
             token: hash(access),
             expires_at: access_expiry(),
             refresh_token_hash: hash(refresh),
             refresh_expires_at: refresh_expiry()
           ]
         ) do
      {1, _} -> {:ok, token_response(encode(access), encode(refresh), row.scope)}
      _ -> invalid_grant("the refresh token has already been used")
    end
  end

  defp token_response(access, refresh, scope) do
    %{
      access_token: access,
      token_type: "Bearer",
      expires_in: @access_seconds,
      refresh_token: refresh,
      scope: scope
    }
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp fetch_client(client_id) do
    case get_client(client_id) do
      %Client{} = client -> {:ok, client}
      nil -> {:error, "invalid_client", "unknown client_id"}
    end
  end

  defp pkce_ok?(verifier, challenge) do
    valid_pkce_string?(verifier) and
      Plug.Crypto.secure_compare(encode(:crypto.hash(:sha256, verifier)), challenge)
  end

  defp check_resource(resource, base) do
    if valid_resource?(resource, base),
      do: :ok,
      else: {:error, "invalid_target", "the resource must be this server's /mcp"}
  end

  defp check(true, _description), do: :ok
  defp check(false, description), do: invalid_grant(description)

  defp invalid_grant(description), do: {:error, "invalid_grant", description}

  defp decode(value, description) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, raw} -> {:ok, hash(raw)}
      :error -> invalid_grant(description)
    end
  end

  defp decode(_value, description), do: invalid_grant(description)

  defp expired?(at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp access_expiry, do: DateTime.utc_now(:second) |> DateTime.add(@access_seconds, :second)
  defp refresh_expiry, do: DateTime.utc_now(:second) |> DateTime.add(@refresh_days, :day)

  defp hash(raw), do: :crypto.hash(:sha256, raw)
  defp encode(raw), do: Base.url_encode64(raw, padding: false)
end
