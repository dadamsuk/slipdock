defmodule Slipdock.Coverage do
  @moduledoc """
  The `mix test --cover` tool, in place of Mix's own.

  Mix hands every beam to `:cover.compile_beam/1` in one call, and on
  Elixir 1.20 / OTP 27 `:cover` cannot recompile some of them — code like
  `x in [:a, :b]` outside a guard comes back from its instrumentation as an
  "unsafe variable" error, and the whole run dies with a `MatchError` before
  a single test starts. This tries them a chunk at a time instead, each
  chunk in a server of its own, narrows a chunk that dies down to the
  beams that killed it, names the ones it had to leave out, and reports
  the rest.

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
      name when is_binary(name) -> fn -> export(name, skipped, opts) end
      _ -> fn -> report!(skipped, opts) end
    end
  end

  defp report!(skipped, opts) do
    if report(skipped, opts) == :below, do: throw(:test_failed)
  end

  @doc """
  Imports every `*.coverdata` in the output directory (`cover/`) into a
  freshly cover-compiled build, then reports as `mix test --cover` does.

  Each export comes with a `NAME.skipped` beside it, the modules that
  partition couldn't cover-compile: with those there, the merge leaves
  them out and compiles the rest in one call, rather than finding them
  again one chunk at a time. If that call fails, a list was stale, and
  it finds them as a partition does.
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
        known = known_skipped(output)
        Mix.shell().info("Cover compiling modules ...")
        skipped = cover_compile(compile_path, known)
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

  # The modules the partitions' `NAME.skipped` lists name, or nil when
  # there are none to go by.
  defp known_skipped(output) do
    case Path.wildcard(Path.join(output, "*.skipped")) do
      [] ->
        nil

      lists ->
        lists
        |> Enum.flat_map(&String.split(File.read!(&1), "\n", trim: true))
        |> MapSet.new()
    end
  end

  defp export(name, skipped, opts) do
    output = Keyword.get(opts, :output, "cover")
    File.mkdir_p!(output)
    file = Path.join(output, "#{name}.coverdata")

    case :cover.export(String.to_charlist(file)) do
      :ok ->
        File.write!(
          Path.join(output, "#{name}.skipped"),
          Enum.map_join(skipped, &(Atom.to_string(&1) <> "\n"))
        )

        Mix.shell().info(
          "\nCoverage exported to #{file}; mix slipdock.coverage merges the exports"
        )

      {:error, reason} ->
        Mix.shell().error("Could not export coverage to #{file}: #{inspect(reason)}")
        throw(:test_failed)
    end
  end

  # Beams per first try: one `:cover.compile_beam/1` call each, which
  # compiles them in parallel.
  @chunk 32

  # Cover-compiles every beam it can and returns the modules it couldn't.
  # `known` is the modules the exports say can't be (a MapSet), or nil.
  defp cover_compile(compile_path, known \\ nil) do
    # Never this module or the merge task: stopping :cover reloads what it
    # compiled, and the purge of the old code kills whoever is running it.
    beams =
      compile_path
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.reject(&Enum.member?([__MODULE__, Mix.Tasks.Slipdock.Coverage], module(&1)))

    # Nothing to compile would report 100% of nothing: a build that isn't
    # there, as after `mix slipdock.coverage --no-compile` on a cache miss.
    if beams == [], do: Mix.raise("No beams in #{compile_path} to cover-compile")

    {listed, rest} = Enum.split_with(beams, &(known && Atom.to_string(module(&1)) in known))

    cond do
      known == nil ->
        probe_and_compile(beams)

      compiled_apart?(rest) ->
        Mix.shell().info(
          "Compiled in one call, leaving out the #{length(listed)} the exports list"
        )

        Enum.map(listed, &module/1)

      true ->
        Mix.shell().info("The exports' lists missed a module: trying each chunk")
        probe_and_compile(beams)
    end
  end

  defp probe_and_compile(beams) do
    # A beam :cover cannot compile kills its server and whoever started it,
    # taking every module compiled so far along (#2848: one bad beam fails
    # the whole parallel call). So try them a chunk at a time from a process
    # of its own, halve the chunks that die until the culprits are alone,
    # then compile all the ones that survived in one call. Nothing to stop
    # in between: a beam that kills the server takes all it held, so it
    # only ever holds good ones, and compiling one again replaces it.
    {good, bad} =
      beams
      |> Enum.chunk_every(@chunk)
      |> Enum.map(&probe/1)
      |> Enum.reduce({[], []}, fn {g, b}, {gs, bs} -> {gs ++ g, bs ++ b} end)

    _ = compile(good)

    Enum.map(bad, &module/1)
  end

  # {the beams :cover compiles, the ones it can't}.
  defp probe(beams) do
    cond do
      compiled_apart?(beams) ->
        {beams, []}

      match?([_], beams) ->
        {[], beams}

      true ->
        {first, second} = Enum.split(beams, div(length(beams), 2))
        {good1, bad1} = probe(first)
        {good2, bad2} = probe(second)
        {good1 ++ good2, bad1 ++ bad2}
    end
  end

  # Compiles the beams in one call, from a process of its own so that a
  # beam that kills :cover doesn't take the merge with it: true when they
  # all compiled. They stay compiled after the process goes: the server
  # isn't linked to whoever started it.
  defp compiled_apart?(beams) do
    {pid, ref} = spawn_monitor(fn -> exit({:compiled, compile(beams)}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason == {:compiled, true}
    end
  end

  defp compile([]), do: true

  defp compile(beams) do
    _ = :cover.local_only()

    beams
    |> Enum.map(&String.to_charlist/1)
    |> :cover.compile_beam()
    |> Enum.all?(&match?({:ok, _}, &1))
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

      MIX_ENV=test mix slipdock.coverage [--no-compile]

  `--no-compile` merges into the build already in `_build`, as it is:
  CI's coverage job passes it when its cache restored the build of the
  same tree, rather than have Mix recompile it.

  Test env only: it lives in `test/support` beside `Slipdock.Coverage`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [compile: :boolean])

    # --no-compile takes the build as it is: CI's coverage job passes it when
    # the cache held the build of this very tree, which Mix would otherwise
    # recompile whole on a runner whose checkout is in another directory
    # (#2848: the manifest keeps the project's absolute path). Nothing to
    # load then: :cover reads the beams by their path, and Mix put the
    # app's ebin on the code path to find this task.
    if Keyword.get(opts, :compile, true), do: Mix.Task.run("compile")

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
