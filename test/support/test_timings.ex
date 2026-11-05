defmodule Slipdock.TestTimings do
  @moduledoc """
  An ExUnit formatter that records how long each test file took, for
  balancing CI's partitions (`Slipdock.TestPartitions`, #1858).

  It is only added when `TEST_TIMINGS_FILE` is set (test/test_helper.exs),
  and writes that file when the suite finishes: one line per test file,
  `path<TAB>async|sync<TAB>milliseconds`, the milliseconds being the wall
  time from the file's first module starting to its last finishing (setup_all
  included). A file with any `async: false` module counts as sync, since sync
  modules run one at a time after the async ones and cost their whole time.
  """
  use GenServer

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    {:ok, %{path: System.get_env("TEST_TIMINGS_FILE"), started: %{}, files: %{}}}
  end

  @impl true
  def handle_cast({:module_started, %ExUnit.TestModule{name: name}}, state) do
    {:noreply, put_in(state.started[name], System.monotonic_time(:millisecond))}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{} = module}, state) do
    {started, started_map} = Map.pop(state.started, module.name)
    ms = if started, do: System.monotonic_time(:millisecond) - started, else: 0
    {:noreply, %{state | started: started_map, files: add(state.files, module, ms)}}
  end

  def handle_cast({:suite_finished, _times}, state) do
    if state.path, do: write(state.path, state.files)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc """
  Adds one finished module to the per-file totals. The file is relative to
  the working directory, as `mix test` is given it.
  """
  def add(files, %ExUnit.TestModule{file: file, tests: tests}, ms) do
    sync? = Enum.any?(tests, &(&1.tags[:async] == false))
    key = Path.relative_to_cwd(file)

    Map.update(files, key, {sync?, ms}, fn {was_sync?, total} ->
      {was_sync? or sync?, total + ms}
    end)
  end

  @doc "The lines `write/2` puts in the file, sorted by path."
  def lines(files) do
    files
    |> Enum.sort()
    |> Enum.map(fn {file, {sync?, ms}} ->
      "#{file}\t#{if sync?, do: "sync", else: "async"}\t#{ms}\n"
    end)
  end

  defp write(path, files) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, lines(files))
  end
end
