defmodule Slipdock.Config do
  @moduledoc """
  `Application.get_env(:slipdock, key, default)`, with one difference that only
  the test suite ever sees: a test can override a key for itself.

  ## Why this exists

  A test about rate limiting, the AI provider or trusted proxies has to change
  the application's config, and `Application.put_env/3` changes it for every
  test running at the same time. So each of those files was `async: false`,
  and the synchronous tail of the suite grew with them.

  An override set with `override/2` is seen by the test process and by
  everything that names it in `$callers`: the LiveViews it mounts, the tasks
  they start, the request a `ConnTest` makes in its own process. Other tests
  keep reading the application env. What it cannot reach is a process started
  at boot (the search indexer, the automation scheduler), which never had the
  test as a caller — a test about one of those still has to be synchronous.

  The override table only exists when `config :slipdock, :config_overrides,
  true` is compiled in (the test environment); everywhere else `get/2` is
  `Application.get_env/3` and nothing more.
  """

  @overridable Application.compile_env(:slipdock, :config_overrides, false)

  @doc "The value of `key` in the `:slipdock` application, or `default`."
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil)

  if @overridable do
    @table __MODULE__.Overrides

    def get(key, default) do
      case overridden(key) do
        {:ok, value} -> value
        :none -> Application.get_env(:slipdock, key, default)
      end
    end

    @doc """
    Creates the override table. Called once, from `test/test_helper.exs`, so
    that it belongs to a process that lives as long as the run.
    """
    def start_overrides do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      end

      :ok
    end

    @doc """
    Sets `key` to `value` for the calling process and its callers' descendants
    until `clear_overrides/1`. Use `Slipdock.TestConfig.put/2` from a test,
    which clears up after itself.
    """
    def override(key, value) do
      :ets.insert(@table, {{self(), key}, value})
      :ok
    end

    @doc "Drops every override `pid` set."
    def clear_overrides(pid) do
      :ets.match_delete(@table, {{pid, :_}, :_})
      :ok
    end

    defp overridden(key) do
      if :ets.whereis(@table) == :undefined do
        :none
      else
        Enum.find_value([self() | Process.get(:"$callers", [])], :none, fn pid ->
          case :ets.lookup(@table, {pid, key}) do
            [{_, value}] -> {:ok, value}
            [] -> nil
          end
        end)
      end
    end
  else
    def get(key, default), do: Application.get_env(:slipdock, key, default)
  end
end
