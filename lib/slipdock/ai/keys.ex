defmodule Slipdock.AI.Keys do
  @moduledoc """
  Where each person's OpenRouter API key lives: one JSON file on the server,
  outside the database, keyed by user id.

      {"users": {"1": {"email": "you@example.com",
                       "api_key": "sk-or-v1-…",
                       "updated_at": "2026-10-01T15:40:00Z"}}}

  The file is named by `config :slipdock, :ai, key_file:`
  (`SLIPDOCK_AI_KEY_FILE`, default `ai_keys.json` in the app's working
  directory). It holds secrets in the clear, so it is created `0600` and the
  directory is left alone otherwise — back it up like you would a `.env`.

  Keys are read on demand rather than cached: the file is a few lines, reads
  are rare next to the API call that follows, and a key edited by hand takes
  effect without a restart. Writes go to a temporary file and are renamed
  over the original, so a crash mid-write cannot leave half a file behind.

  `Slipdock.AI` does the resolving (see `Slipdock.AI.api_key/1`); this module
  only stores. A user without a key here runs no AI features — that is the
  point of it.
  """

  require Logger

  alias Slipdock.Accounts.User

  @type entry :: %{email: String.t() | nil, api_key: String.t(), updated_at: String.t()}

  @doc "The key for a user (a `%User{}` or an id), or nil when they have none."
  @spec get(User.t() | integer() | binary() | nil) :: String.t() | nil
  def get(nil), do: nil
  def get(%User{id: id}), do: get(id)

  def get(id) do
    case read()["users"][to_string(id)] do
      %{"api_key" => key} when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  @doc "Whether this user has a key of their own."
  @spec configured?(User.t() | integer() | nil) :: boolean()
  def configured?(user), do: is_binary(get(user))

  @doc """
  Stores `key` for `user`, replacing any key they had. A blank key removes
  theirs instead (see `delete/1`). Returns `:ok` or `{:error, message}`.
  """
  @spec put(User.t(), String.t()) :: :ok | {:error, String.t()}
  def put(%User{} = user, key) when is_binary(key) do
    case String.trim(key) do
      "" ->
        delete(user)

      key ->
        entry = %{
          "email" => user.email,
          "api_key" => key,
          "updated_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }

        update(&put_in(&1, ["users", to_string(user.id)], entry))
    end
  end

  @doc "Removes this user's key. Returns `:ok` even when they had none."
  @spec delete(User.t() | integer()) :: :ok | {:error, String.t()}
  def delete(%User{id: id}), do: delete(id)

  def delete(id) do
    update(&update_in(&1, ["users"], fn users -> Map.delete(users, to_string(id)) end))
  end

  @doc """
  Every stored entry, as `%{user_id => entry}` with the key itself included.
  For the admin mix task; the web UI shows `masked/1` instead.
  """
  @spec all() :: %{optional(String.t()) => entry()}
  def all do
    read()["users"]
    |> Enum.map(fn {id, entry} ->
      {id,
       %{
         email: entry["email"],
         api_key: entry["api_key"],
         updated_at: entry["updated_at"]
       }}
    end)
    |> Map.new()
  end

  @doc """
  When this user's key was last set, as an ISO 8601 string, or nil.
  """
  @spec updated_at(User.t() | integer() | nil) :: String.t() | nil
  def updated_at(nil), do: nil
  def updated_at(%User{id: id}), do: updated_at(id)
  def updated_at(id), do: read()["users"][to_string(id)]["updated_at"]

  @doc """
  The key to use for work nobody is sitting in front of — the search
  indexer, scheduled automations. The server-wide `config :slipdock, :ai,
  :api_key` when one is set; otherwise, when `SLIPDOCK_AI_SYSTEM_USER` names a
  user by email, that person's key; otherwise, when exactly one person has a
  key at all, theirs — a single-user install should not have to say so
  twice. Nil when none of that holds, and background AI work then stays off.
  """
  @spec system_key() :: String.t() | nil
  def system_key do
    config()[:api_key] || named_system_key() || sole_key()
  end

  defp named_system_key do
    with email when is_binary(email) <-
           config()[:system_user] || System.get_env("SLIPDOCK_AI_SYSTEM_USER"),
         {_id, entry} <-
           Enum.find(read()["users"], fn {_id, e} ->
             is_binary(e["email"]) and String.downcase(e["email"]) == String.downcase(email)
           end) do
      entry["api_key"]
    else
      _ -> nil
    end
  end

  defp sole_key do
    case Enum.filter(read()["users"], fn {_id, e} -> is_binary(e["api_key"]) end) do
      [{_id, entry}] -> entry["api_key"]
      _ -> nil
    end
  end

  @doc """
  A key with its middle hidden, for showing someone what they have stored:
  `sk-or-v1-…a91c`. Nil passes through.
  """
  @spec masked(String.t() | nil) :: String.t() | nil
  def masked(nil), do: nil

  def masked(key) when is_binary(key) do
    case String.length(key) do
      n when n <= 10 -> String.duplicate("•", n)
      _ -> String.slice(key, 0, 8) <> "…" <> String.slice(key, -4, 4)
    end
  end

  @doc "The file the keys are read from and written to."
  @spec path() :: String.t()
  def path, do: config()[:key_file] || "ai_keys.json"

  # ── the file itself ────────────────────────────────────────────────────

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"users" => users} = data} when is_map(users) <- Jason.decode(body) do
      data
    else
      {:error, :enoent} ->
        empty()

      {:ok, %{} = data} ->
        # A file written before "users" existed, or edited by hand.
        Map.put(data, "users", %{})

      other ->
        Logger.warning("Could not read AI keys from #{path()}: #{inspect(other)}")
        empty()
    end
  end

  defp empty, do: %{"users" => %{}}

  defp update(fun) do
    data = fun.(read())
    tmp = path() <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(Path.expand(path()))),
         :ok <- File.write(tmp, Jason.encode_to_iodata!(data, pretty: true)),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path()) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        Logger.error("Could not write AI keys to #{path()}: #{inspect(reason)}")
        {:error, "Couldn't save the key on the server (#{:file.format_error(reason)})."}
    end
  end

  defp config, do: Application.get_env(:slipdock, :ai, [])
end
