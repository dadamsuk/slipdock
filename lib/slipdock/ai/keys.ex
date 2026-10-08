defmodule Slipdock.AI.Keys do
  @moduledoc """
  Where each person's AI provider settings live: one JSON file on the server,
  outside the database, keyed by user id.

      {"users": {"1": {"email": "you@example.com",
                       "api_key": "sk-or-v1-…",
                       "base_url": "http://llm.local:1234/v1",
                       "model": "qwen/qwen3.5-9b",
                       "embed_model": "text-embedding-nomic-embed-text-v1.5",
                       "updated_at": "2026-10-01T15:40:00Z"}}}

  Four fields, all optional, all per person:

    * `api_key` — their OpenRouter key, or the key their own endpoint wants;
    * `base_url` — an OpenAI-compatible endpoint of their own (LM Studio,
      Ollama, llama.cpp, vLLM, a company gateway) instead of OpenRouter. A
      local endpoint usually needs no key at all, so a `base_url` on its own
      is enough to turn the AI features on;
    * `model` — which model to ask, from that endpoint's `/v1/models`;
    * `embed_model` — the embedding model for semantic search, when the
      endpoint serves one (a local endpoint will not have OpenRouter's).

  The file is named by `config :slipdock, :ai, key_file:`
  (`SLIPDOCK_AI_KEY_FILE`, default `ai_keys.json` in the app's working
  directory). It holds secrets in the clear, so it is created `0600` and the
  directory is left alone otherwise — back it up like you would a `.env`.

  Settings are read on demand rather than cached: the file is a few lines,
  reads are rare next to the API call that follows, and a key edited by hand
  takes effect without a restart. Writes are serialised under a lock, go to
  a temporary file of their own and are renamed over the original, so a
  crash mid-write cannot leave half a file behind and two saves at once
  cannot lose one. A file that will not parse is never written over: that
  would replace everybody's settings with one person's.

  `Slipdock.AI` does the resolving (see `Slipdock.AI.provider/1`); this module
  only stores. Someone with nothing here, on a server with no shared key,
  runs no AI features — that is the point of it.
  """

  require Logger

  alias Slipdock.Accounts.User

  @type settings :: %{
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          model: String.t() | nil,
          embed_model: String.t() | nil,
          updated_at: String.t() | nil
        }

  @type entry :: %{email: String.t() | nil, api_key: String.t(), updated_at: String.t()}

  # The settable fields, in the order they are written.
  @fields ~w(api_key base_url model embed_model)a

  @doc """
  Everything stored for a user (a `%User{}` or an id), with `nil` for each
  field they have not set. Never raises and never returns `nil` itself, so
  callers can read `.base_url` straight off it.
  """
  @spec settings(User.t() | integer() | binary() | nil) :: settings()
  def settings(nil), do: blank()
  def settings(%User{id: id}), do: settings(id)

  def settings(id) do
    case read()["users"][to_string(id)] do
      %{} = entry ->
        %{
          api_key: value(entry["api_key"]),
          base_url: value(entry["base_url"]),
          model: value(entry["model"]),
          embed_model: value(entry["embed_model"]),
          updated_at: entry["updated_at"]
        }

      _ ->
        blank()
    end
  end

  @doc "The key for a user (a `%User{}` or an id), or nil when they have none."
  @spec get(User.t() | integer() | binary() | nil) :: String.t() | nil
  def get(user), do: settings(user).api_key

  @doc "The endpoint this user has pointed at, or nil for OpenRouter."
  @spec endpoint(User.t() | integer() | nil) :: String.t() | nil
  def endpoint(user), do: settings(user).base_url

  @doc "The model this user picked, or nil for the server's default."
  @spec model(User.t() | integer() | nil) :: String.t() | nil
  def model(user), do: settings(user).model

  @doc "Whether this user has a key of their own."
  @spec configured?(User.t() | integer() | nil) :: boolean()
  def configured?(user), do: is_binary(get(user))

  @doc """
  Whether this user has brought enough of their own to run AI: a key, or an
  endpoint of their own (which commonly wants no key).
  """
  @spec own?(User.t() | integer() | nil) :: boolean()
  def own?(user), do: usable?(settings(user))

  @doc "Whether a settings map can be used to make a call at all."
  @spec usable?(settings()) :: boolean()
  def usable?(%{api_key: key, base_url: url}),
    do: is_binary(key) or is_binary(url)

  @doc """
  Stores `key` for `user`, replacing any key they had. A blank key removes
  theirs instead, leaving the rest of their settings alone. Returns `:ok` or
  `{:error, message}`.
  """
  @spec put(User.t(), String.t()) :: :ok | {:error, String.t()}
  def put(%User{} = user, key) when is_binary(key),
    do: put_settings(user, %{api_key: key})

  @doc """
  Stores some of a user's settings, leaving the fields not mentioned as they
  were. Keys are `:api_key`, `:base_url`, `:model` and `:embed_model`; a
  blank or nil value clears that one. When nothing is left set, the whole
  entry goes.

      Keys.put_settings(user, %{base_url: "http://box:1234/v1", api_key: ""})

  Returns `:ok` or `{:error, message}`.
  """
  @spec put_settings(User.t(), map()) :: :ok | {:error, String.t()}
  def put_settings(%User{} = user, attrs) when is_map(attrs) do
    id = to_string(user.id)

    update(fn data ->
      with {:ok, merged} <- merge(data["users"][id] || %{}, attrs) do
        if Enum.any?(@fields, &Map.has_key?(merged, to_string(&1))) do
          entry =
            merged
            |> Map.put("email", user.email)
            |> Map.put(
              "updated_at",
              DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
            )

          {:ok, put_in(data, ["users", id], entry)}
        else
          {:ok, update_in(data, ["users"], &Map.delete(&1, id))}
        end
      end
    end)
  end

  defp merge(entry, attrs) do
    Enum.reduce_while(@fields, {:ok, entry}, fn field, {:ok, acc} ->
      case fetch(attrs, field) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case normalise(field, value) do
            {:ok, nil} -> {:cont, {:ok, Map.delete(acc, to_string(field))}}
            {:ok, value} -> {:cont, {:ok, Map.put(acc, to_string(field), value)}}
            {:error, message} -> {:halt, {:error, message}}
          end
      end
    end)
  end

  # Tolerates string keys, so a controller can hand params straight over.
  defp fetch(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, to_string(field))
    end
  end

  defp normalise(_field, nil), do: {:ok, nil}

  defp normalise(field, value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed when field == :base_url -> normalise_url(trimmed)
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalise(field, value), do: {:error, "#{field} must be a string, got #{inspect(value)}."}

  # An endpoint is an OpenAI-compatible API root: the thing `/chat/completions`
  # hangs off. People paste the base with a trailing slash, or the completions
  # URL itself, or forget the scheme — all three are worth fixing rather than
  # refusing, because the alternative is a confusing 404 an hour later.
  defp normalise_url(url) do
    url = String.trim_trailing(url, "/")

    url =
      cond do
        String.ends_with?(url, "/chat/completions") ->
          String.replace_suffix(url, "/chat/completions", "")

        String.ends_with?(url, "/completions") ->
          String.replace_suffix(url, "/completions", "")

        true ->
          url
      end

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, url}

      _ ->
        {:error,
         "That endpoint doesn't look like a URL — it needs to be the API root, " <>
           "like http://llm.local:1234/v1 or https://openrouter.ai/api/v1."}
    end
  end

  @doc "Removes everything stored for this user. Returns `:ok` even when there was nothing."
  @spec delete(User.t() | integer()) :: :ok | {:error, String.t()}
  def delete(%User{id: id}), do: delete(id)

  def delete(id) do
    update(&{:ok, update_in(&1, ["users"], fn users -> Map.delete(users, to_string(id)) end)})
  end

  @doc """
  Every stored entry, as `%{user_id => entry}` with the key itself included.
  For the admin mix task; the web UI shows `masked/1` instead.
  """
  @spec all() :: %{optional(String.t()) => map()}
  def all do
    read()["users"]
    |> Enum.map(fn {id, entry} ->
      {id,
       %{
         email: entry["email"],
         api_key: entry["api_key"],
         base_url: entry["base_url"],
         model: entry["model"],
         embed_model: entry["embed_model"],
         updated_at: entry["updated_at"]
       }}
    end)
    |> Map.new()
  end

  @doc """
  When this user's settings were last changed, as an ISO 8601 string, or nil.
  """
  @spec updated_at(User.t() | integer() | nil) :: String.t() | nil
  def updated_at(user), do: settings(user).updated_at

  @doc """
  The settings to use for work nobody is sitting in front of — the search
  indexer, scheduled automations. See `system_source/0` for how they are
  chosen; this is just its `:settings`.
  """
  @spec system_settings() :: settings()
  def system_settings, do: system_source().settings

  @doc """
  Where unattended work's AI settings come from, and why. In order:

    * `:server_key` — the server-wide `config :slipdock, :ai, :api_key`
      (`OPENROUTER_API_KEY`), a key shared with everyone;
    * `:chosen` — the admin an admin picked on the Configuration page (the
      `ai_system_user` setting), as long as they are still an admin, still
      enabled and have settings of their own;
    * `:environment` — the person `SLIPDOCK_AI_SYSTEM_USER` names by email;
    * `:sole_admin` — on a server with registration closed, when exactly one
      person has settings of their own and that person is an admin, theirs —
      a single-user install should not have to say so twice;
    * `:none` — none of that holds, and background AI work stays off.

  Returns `%{source: atom, user: %User{} | nil, settings: settings}`; `user`
  is whose settings they are, nil for a shared key or none.

  The indexer sends every board's content through these settings, and every
  search query too, so they are never a person's own endpoint or key unless
  an admin put them there. Hence no guessing on a server others can join, and
  no guessing a non-admin: the first person to point their account at a
  server of their own would otherwise receive everybody's cards.
  """
  @spec system_source() :: %{source: atom(), user: User.t() | nil, settings: settings()}
  def system_source do
    cond do
      is_binary(value(config()[:api_key])) ->
        source(:server_key, nil, %{blank() | api_key: value(config()[:api_key])})

      found = chosen_system_settings() ->
        found

      found = named_system_settings() ->
        found

      found = sole_settings() ->
        found

      true ->
        source(:none, nil, blank())
    end
  end

  defp source(source, user, settings), do: %{source: source, user: user, settings: settings}

  @doc "The key unattended work spends, or nil. See `system_settings/0`."
  @spec system_key() :: String.t() | nil
  def system_key, do: system_settings().api_key

  # Checked again on every read, not only when it was saved: someone demoted
  # or disabled since stops being the server's AI at once, and the next rule
  # decides instead.
  defp chosen_system_settings do
    with id when is_integer(id) <- Slipdock.Settings.get().ai_system_user_id,
         %User{admin: true, disabled_at: nil} = user <- user(id),
         settings = settings(id),
         true <- usable?(settings) do
      source(:chosen, user, settings)
    else
      _ -> nil
    end
  end

  defp named_system_settings do
    with email when is_binary(email) <-
           config()[:system_user] || System.get_env("SLIPDOCK_AI_SYSTEM_USER"),
         {id, _entry} <-
           Enum.find(read()["users"], fn {_id, e} ->
             is_binary(e["email"]) and String.downcase(e["email"]) == String.downcase(email)
           end) do
      source(:environment, user(id), settings(id))
    else
      _ -> nil
    end
  end

  defp sole_settings do
    with :closed <- Slipdock.Settings.signup_mode(),
         [{id, _entry}] <- Enum.filter(read()["users"], fn {id, _e} -> usable?(settings(id)) end),
         %User{admin: true, disabled_at: nil} = user <- user(id) do
      source(:sole_admin, user, settings(id))
    else
      _ -> nil
    end
  end

  defp user(id) do
    case Integer.parse(to_string(id)) do
      {int, ""} -> Slipdock.Repo.get(User, int)
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

  @doc "The file the settings are read from and written to."
  @spec path() :: String.t()
  def path, do: config()[:key_file] || "ai_keys.json"

  defp blank,
    do: %{api_key: nil, base_url: nil, model: nil, embed_model: nil, updated_at: nil}

  defp value(string) when is_binary(string) do
    case String.trim(string) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp value(_), do: nil

  # ── the file itself ────────────────────────────────────────────────────

  # Readers tolerate a broken file and see nobody's settings; `update/1`
  # does not, see `load/0`.
  defp read do
    case load() do
      {:ok, data} ->
        data

      {:error, reason} ->
        Logger.warning("Could not read AI keys from #{path()}: #{inspect(reason)}")
        empty()
    end
  end

  defp load do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"users" => users} = data} when is_map(users) <- Jason.decode(body) do
      {:ok, data}
    else
      {:error, :enoent} ->
        {:ok, empty()}

      {:ok, %{"users" => _}} ->
        {:error, :malformed}

      {:ok, %{} = data} ->
        # A file written before "users" existed, or edited by hand.
        {:ok, Map.put(data, "users", %{})}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :malformed}
    end
  end

  defp empty, do: %{"users" => %{}}

  # One writer at a time on this node, so a read-modify-write cannot lose a
  # concurrent one; and each write its own temporary file, so two cannot
  # interleave into it either. `fun` gets the current contents and answers
  # `{:ok, new_contents}` or `{:error, message}`.
  defp update(fun) do
    :global.trans({__MODULE__, self()}, fn -> write(fun) end)
  end

  defp write(fun) do
    case load() do
      {:ok, data} ->
        with {:ok, data} <- fun.(data), do: save(data)

      {:error, reason} ->
        Logger.error(
          "Not writing AI keys: #{path()} could not be read (#{inspect(reason)}), " <>
            "and saving over it would lose everybody else's settings"
        )

        {:error,
         "The server's AI settings file is unreadable, so nothing was saved — " <>
           "an admin needs to look at #{Path.basename(path())}."}
    end
  end

  defp save(data) do
    tmp = "#{path()}.#{System.unique_integer([:positive])}.tmp"

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

  defp config, do: Slipdock.Config.get(:ai, [])
end
