defmodule Slipdock.Coverage do
  @moduledoc """
  The `mix test --cover` tool, in place of Mix's own.

  Mix hands every beam to `:cover.compile_beam/1` in one call, and on
  Elixir 1.20 / OTP 27 `:cover` cannot recompile some of them — code like
  `x in [:a, :b]` outside a guard comes back from its instrumentation as an
  "unsafe variable" error, and the whole run dies with a `MatchError` before
  a single test starts. This compiles them one at a time instead, names the
  ones it had to leave out, and reports the rest.

  Prints a table of modules under `lib/`, worst covered first, and writes
  an HTML page per module to `cover/`. `--cover` takes the same
  `:summary` threshold as Mix's tool (`test_coverage: [summary: ...]`).

  CI runs the suite in four partitions, and no one of them reaches the
  threshold alone. So `mix test --cover --export-coverage NAME` writes
  `cover/NAME.coverdata` instead of the report, and `mix slipdock.coverage`
  (`merge/2`) imports every export there and reports, and fails, on the
  whole. Mix's own `mix test.coverage` would do that, but it cover-compiles
  every beam in one call, which is the crash this module exists to avoid.
  """

  @compile {:no_warn_undefined, :cover}

  @doc false
  def start(compile_path, opts) do
    Mix.shell().info("Cover compiling modules ...")
    Mix.ensure_application!(:tools)
    skipped = cover_compile(compile_path)

    case Keyword.get(opts, :export) do
      name when is_binary(name) -> fn -> export(name, opts) end
      _ -> fn -> report!(skipped, opts) end
    end
  end

  defp report!(skipped, opts) do
    if report(skipped, opts) == :below, do: throw(:test_failed)
  end

  @doc """
  Imports every `*.coverdata` in the output directory (`cover/`) into a
  freshly cover-compiled build, then reports as `mix test --cover` does.
  Returns `:ok`, or `:below` when the total misses the threshold; raises
  when there is nothing to import.
  """
  def merge(compile_path, opts) do
    Mix.ensure_application!(:tools)
    output = Keyword.get(opts, :output, "cover")

    case Path.wildcard(Path.join(output, "*.coverdata")) do
      [] ->
        Mix.raise("No coverage exports (*.coverdata) in #{output}/ to merge")

      exports ->
        Mix.shell().info("Cover compiling modules ...")
        skipped = cover_compile(compile_path)
        Enum.each(exports, &import!/1)
        report(skipped, opts)
    end
  end

  defp import!(file) do
    Mix.shell().info("Importing #{file}")

    case :cover.import(String.to_charlist(file)) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Could not import #{file}: #{inspect(reason)}")
    end
  end

  defp export(name, opts) do
    output = Keyword.get(opts, :output, "cover")
    File.mkdir_p!(output)
    file = Path.join(output, "#{name}.coverdata")

    case :cover.export(String.to_charlist(file)) do
      :ok ->
        Mix.shell().info(
          "\nCoverage exported to #{file}; mix slipdock.coverage merges the exports"
        )

      {:error, reason} ->
        Mix.shell().error("Could not export coverage to #{file}: #{inspect(reason)}")
        throw(:test_failed)
    end
  end

  # Cover-compiles every beam it can and returns the modules it couldn't.
  defp cover_compile(compile_path) do
    # Never this module or the merge task: stopping :cover reloads what it
    # compiled, and the purge of the old code kills whoever is running it.
    beams =
      compile_path
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.reject(&Enum.member?([__MODULE__, Mix.Tasks.Slipdock.Coverage], module(&1)))

    # A beam :cover cannot compile kills its server and whoever started it,
    # taking every module compiled so far along. So try each one from a
    # process of its own first, then compile only the ones that survived.
    {good, bad} = Enum.split_with(beams, &compiles?/1)
    _ = :cover.stop()
    Enum.each(good, &compile/1)

    Enum.map(bad, &module/1)
  end

  defp compiles?(beam) do
    {pid, ref} = spawn_monitor(fn -> exit({:compiled, compile(beam)}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        _ = :cover.stop()
        reason == {:compiled, true}
    end
  end

  defp compile(beam) do
    _ = :cover.local_only()
    match?({:ok, _}, :cover.compile_beam(String.to_charlist(beam)))
  end

  defp module(beam), do: beam |> Path.basename(".beam") |> String.to_atom()

  defp report(skipped, opts) do
    output = Keyword.get(opts, :output, "cover")
    File.mkdir_p!(output)

    rows =
      for mod <- :cover.modules(), from_lib?(mod) do
        {:ok, {^mod, {covered, missed}}} = :cover.analyse(mod, :coverage, :module)
        _ = :cover.analyse_to_file(mod, ~c"#{output}/#{inspect(mod)}.html", [:html])
        {mod, covered, missed}
      end

    {covered, missed} =
      Enum.reduce(rows, {0, 0}, fn {_, c, m}, {cs, ms} -> {cs + c, ms + m} end)

    threshold =
      case Keyword.get(opts, :summary, true) do
        opts when is_list(opts) -> Keyword.get(opts, :threshold, 90)
        _ -> 90
      end

    Mix.shell().info("\nPercentage | Missed | Module")
    Mix.shell().info("-----------|--------|--------------------------")

    rows
    |> Enum.sort_by(fn {_, c, m} -> percent(c, m) end)
    |> Enum.each(fn {mod, c, m} ->
      Mix.shell().info(
        "#{pad(percent(c, m))} | #{String.pad_leading("#{m}", 6)} | #{inspect(mod)}"
      )
    end)

    Mix.shell().info("-----------|--------|--------------------------")

    Mix.shell().info(
      "#{pad(percent(covered, missed))} | #{String.pad_leading("#{missed}", 6)} | Total"
    )

    if skipped != [] do
      Mix.shell().info(
        "\nNot measured (:cover could not compile them): " <>
          Enum.map_join(skipped, ", ", &inspect/1)
      )
    end

    Mix.shell().info("\nHTML per module in #{output}/")

    if percent(covered, missed) < threshold do
      Mix.shell().error("Coverage test failed, threshold not met: #{threshold}%")
      :below
    else
      :ok
    end
  end

  defp from_lib?(mod) do
    source = mod.module_info(:compile)[:source]
    source != nil and String.contains?(to_string(source), "/lib/")
  end

  defp percent(_, 0), do: 100.0
  defp percent(covered, missed), do: covered * 100 / (covered + missed)

  defp pad(percent),
    do: String.pad_leading(:erlang.float_to_binary(percent / 1, decimals: 2) <> "%", 10)
end

defmodule Mix.Tasks.Slipdock.Coverage do
  @shortdoc "Merges the partitions' coverage exports and checks the threshold"
  @moduledoc """
  Merges the `cover/*.coverdata` that `mix test --cover --export-coverage
  NAME` wrote, one per CI partition, prints the report and exits non-zero
  when the total is below `mix.exs`'s `test_coverage` threshold.

      MIX_ENV=test mix slipdock.coverage

  Test env only: it lives in `test/support` beside `Slipdock.Coverage`.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("compile")
    project = Mix.Project.config()
    check(Mix.Project.compile_path(project), project[:test_coverage] || [])
  end

  @doc "Merges as `run/1` does, exiting with status 1 below the threshold."
  def check(compile_path, opts) do
    case Slipdock.Coverage.merge(compile_path, opts) do
      :ok -> :ok
      :below -> exit({:shutdown, 1})
    end
  end
end
