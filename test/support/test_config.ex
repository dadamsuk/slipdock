defmodule Slipdock.TestConfig do
  @moduledoc """
  Changes the application's config for one test only (see `Slipdock.Config`),
  so the test can stay `async: true`. Instead of

      previous = Application.get_env(:slipdock, :ai)
      Application.put_env(:slipdock, :ai, Keyword.put(previous, :provider, "custom"))
      on_exit(fn -> Application.put_env(:slipdock, :ai, previous) end)

  write

      Slipdock.TestConfig.merge(:ai, provider: "custom")

  The override is dropped when the test exits. It reaches the test process and
  what it starts; not processes started at boot.
  """

  alias Slipdock.Config

  @doc "Sets `key` to `value` for this test."
  def put(key, value) do
    test_pid = self()
    Config.override(key, value)
    ExUnit.Callbacks.on_exit({Config, key}, fn -> Config.clear_overrides(test_pid) end)
    :ok
  end

  @doc """
  Gives this test an uploads directory of its own, empty, removed when the
  test exits — so a test can look at what is on disk without another test's
  files being there, or wiping its own. Named for the OS process as well as
  a number unique within this run: the numbers start again in every run, and
  a run that was killed leaves its directories behind (#2831).
  """
  def own_uploads_dir do
    name = "slipdock-uploads-#{System.pid()}-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), name)
    put(:uploads_dir, dir)
    ExUnit.Callbacks.on_exit({__MODULE__, :uploads_dir}, fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc "Merges `opts` into the keyword list `key` currently holds, for this test."
  def merge(key, opts) when is_list(opts) do
    put(key, Keyword.merge(Config.get(key, []), opts))
  end
end
