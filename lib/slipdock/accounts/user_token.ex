defmodule Slipdock.Accounts.UserToken do
  @moduledoc """
  Tokens for magic-link sign-in ("magic"), browser sessions ("session") and
  API access ("api"). Magic-link and API tokens are stored hashed; the
  session token is random and stored as-is (it only ever lives in the
  signed session cookie).
  """
  use Ecto.Schema
  import Ecto.Query

  @rand_size 32
  @hash_algorithm :sha256
  @magic_validity_minutes 15
  @session_validity_days 30

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :label, :string
    field :last_used_at, :utc_datetime
    belongs_to :user, Slipdock.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def session_validity_days, do: @session_validity_days
  def magic_validity_minutes, do: @magic_validity_minutes

  ## Sessions

  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: token, context: "session", user_id: user.id}}
  end

  def verify_session_token_query(token) do
    query =
      from(t in by_token_and_context(token, "session"),
        join: u in assoc(t, :user),
        where: t.inserted_at > ago(@session_validity_days, "day"),
        select: u
      )

    {:ok, query}
  end

  ## Hashed tokens (magic link, api)

  @doc "Returns `{url_safe_token, struct}`; only the hash is stored."
  def build_hashed_token(user, context, opts \\ []) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{
       token: hashed,
       context: context,
       sent_to: opts[:sent_to],
       label: opts[:label],
       user_id: user.id
     }}
  end

  def verify_magic_token_query(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false) do
      hashed = :crypto.hash(@hash_algorithm, decoded)

      query =
        from(t in by_token_and_context(hashed, "magic"),
          join: u in assoc(t, :user),
          where: t.inserted_at > ago(@magic_validity_minutes, "minute") and t.sent_to == u.email,
          select: {u, t}
        )

      {:ok, query}
    else
      :error -> :error
    end
  end

  def verify_api_token_query(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false) do
      hashed = :crypto.hash(@hash_algorithm, decoded)

      {:ok,
       from(t in by_token_and_context(hashed, "api"), join: u in assoc(t, :user), select: {u, t})}
    else
      :error -> :error
    end
  end

  def by_token_and_context(token, context) do
    from(__MODULE__, where: [token: ^token, context: ^context])
  end

  def by_user_and_contexts(user, :all), do: from(t in __MODULE__, where: t.user_id == ^user.id)

  def by_user_and_contexts(user, contexts) when is_list(contexts) do
    from(t in __MODULE__, where: t.user_id == ^user.id and t.context in ^contexts)
  end
end
