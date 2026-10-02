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
  @code_length 6
  # Six digits is a small space; a handful of wrong guesses kills the code.
  @code_attempt_limit 5
  @session_validity_days 30

  # What an API token is allowed to do. `write` is everything the person
  # themselves may do; `read` is the same set, minus anything that changes
  # state. A scope only ever *narrows* the account's own permissions — it can
  # never widen them. Enforcement lives in `Slipdock.Access`.
  @scopes ~w(read write)

  schema "users_tokens" do
    # A short code that opens the same door as the long token, for when the
    # link cannot be clicked. See the migration for why it is not hashed.
    field :code, :string
    field :code_attempts, :integer, default: 0
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :label, :string
    field :scope, :string, default: "write"
    # Board ids this token is confined to; `[]` means the whole account.
    field :scope_boards, {:array, :integer}, default: []
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :last_used_ip, :string
    belongs_to :user, Slipdock.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def session_validity_days, do: @session_validity_days
  def magic_validity_minutes, do: @magic_validity_minutes
  def scopes, do: @scopes

  @doc "Whether `token` has an expiry and it has passed."
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

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

  @doc """
  Returns `{url_safe_token, struct}`; only the hash is stored.

  `opts[:code]` attaches a short sign-in code to the same row, so the code and
  the link are two ways through one door and using either closes both.
  """
  def build_hashed_token(user, context, opts \\ []) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{
       token: hashed,
       code: opts[:code],
       context: context,
       sent_to: opts[:sent_to],
       label: opts[:label],
       scope: opts[:scope] || "write",
       scope_boards: opts[:scope_boards] || [],
       expires_at: opts[:expires_at],
       user_id: user.id
     }}
  end

  @doc "How many digits a sign-in code has, and how many tries it gets."
  def code_length, do: @code_length
  def code_attempt_limit, do: @code_attempt_limit

  @doc """
  A fresh sign-in code: `@code_length` digits, zero-padded, from a
  cryptographically strong source rather than `:rand`.
  """
  def generate_code do
    max = Integer.pow(10, @code_length)

    :crypto.strong_rand_bytes(8)
    |> :binary.decode_unsigned()
    |> rem(max)
    |> Integer.to_string()
    |> String.pad_leading(@code_length, "0")
  end

  @doc """
  The live magic token for `email` whose code is `code`, with attempts still
  left. Matching on the address as well as the code is what keeps the space at
  a million per address rather than a million across the whole server.
  """
  def verify_code_query(email, code) do
    from(t in __MODULE__,
      join: u in assoc(t, :user),
      where:
        t.context == "magic" and t.code == ^code and t.sent_to == ^email and
          t.sent_to == u.email and t.code_attempts < @code_attempt_limit and
          t.inserted_at > ago(@magic_validity_minutes, "minute"),
      select: {u, t}
    )
  end

  @doc "Every live magic token for this address, to count a wrong guess against."
  def live_codes_query(email) do
    from(t in __MODULE__,
      where:
        t.context == "magic" and t.sent_to == ^email and
          t.inserted_at > ago(@magic_validity_minutes, "minute")
    )
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

      now = DateTime.utc_now()

      {:ok,
       from(t in by_token_and_context(hashed, "api"),
         join: u in assoc(t, :user),
         where: is_nil(t.expires_at) or t.expires_at > ^now,
         select: {u, t}
       )}
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
