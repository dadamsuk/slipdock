defmodule Slipdock.CoverageTest do
  @moduledoc """
  `Slipdock.Coverage`'s export and merge (#2786): CI's four partitions each
  export their share, and `mix slipdock.coverage` merges them and holds the
  total to the threshold.

  Each run is its own `elixir` process on a scratch module: `:cover` is one
  server per node, and stopping it here would throw away the coverage of the
  suite running this test under `--cover`.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # Two functions, one per partition. :cover counts the module's own lines
  # too, so `a` alone is 2 of 13 lines (15%) and `a` and `b` merged 4 of 13
  # (31%): the merge doubles what either export holds.
  @source """
  defmodule CoverageSample do
    def a do
      x = 1
      x + 1
    end

    def b do
      y = 2
      y * 3
    end
  end
  """

  setup %{tmp_dir: dir} do
    lib = Path.join(dir, "lib")
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(lib)
    File.mkdir_p!(ebin)
    File.write!(Path.join(lib, "coverage_sample.ex"), @source)

    {_, 0} =
      System.cmd("elixirc", ["--ignore-module-conflict", "-o", ebin, "lib/coverage_sample.ex"],
        cd: dir,
        stderr_to_stdout: true
      )

    %{ebin: ebin, out: Path.join(dir, "cover")}
  end

  # Runs `code` in a fresh node with this app's beams and the sample's.
  defp run(dir, code) do
    app_ebin = Application.app_dir(:slipdock, "ebin")

    System.cmd("elixir", ["-pa", app_ebin, "-e", "Mix.start()\n" <> code],
      cd: dir,
      stderr_to_stdout: true
    )
  end

  defp export(%{tmp_dir: dir, ebin: ebin, out: out}, name, call, threshold \\ 99) do
    run(dir, """
    done = Slipdock.Coverage.start(#{inspect(ebin)},
      export: #{inspect(name)}, output: #{inspect(out)}, summary: [threshold: #{threshold}])
    CoverageSample.#{call}()
    done.()
    IO.puts("finished")
    """)
  end

  defp merge(%{tmp_dir: dir, ebin: ebin, out: out}, threshold) do
    run(dir, """
    result = Slipdock.Coverage.merge(#{inspect(ebin)},
      output: #{inspect(out)}, summary: [threshold: #{threshold}])
    IO.puts("result: \#{inspect(result)}")
    """)
  end

  defp total(output) do
    [_, percent] = Regex.run(~r/^\s*([\d.]+)% \|\s+\d+ \| Total$/m, output)
    String.to_float(percent)
  end

  test "a partition exports its share to cover/NAME.coverdata, never checking the threshold",
       ctx do
    {output, 0} = export(ctx, "partition-1", :a, 99)

    assert File.regular?(Path.join(ctx.out, "partition-1.coverdata"))
    # Nothing it couldn't cover-compile, said so rather than left unsaid.
    assert File.read!(Path.join(ctx.out, "partition-1.skipped")) == ""
    assert output =~ "Coverage exported to #{Path.join(ctx.out, "partition-1.coverdata")}"
    assert output =~ "finished"
    refute output =~ "threshold not met"
    refute output =~ "| Total"
  end

  test "the merge adds the partitions' exports up, and passes at the threshold", ctx do
    {_, 0} = export(ctx, "partition-1", :a)
    {_, 0} = export(ctx, "partition-2", :b)

    {output, 0} = merge(ctx, 30)

    assert output =~ "Importing #{Path.join(ctx.out, "partition-1.coverdata")}"
    assert output =~ "Importing #{Path.join(ctx.out, "partition-2.coverdata")}"
    assert output =~ "Compiled in one call, leaving out the 0 the exports list"
    assert total(output) == 30.77
    assert output =~ "CoverageSample"
    assert output =~ "result: :ok"
    refute output =~ "threshold not met"
    assert File.regular?(Path.join(ctx.out, "CoverageSample.html"))
  end

  test "one partition's share alone is below a threshold the merge would meet", ctx do
    {_, 0} = export(ctx, "partition-1", :a)

    {output, 0} = merge(ctx, 30)

    assert total(output) == 15.38
    assert output =~ "Coverage test failed, threshold not met: 30%"
    assert output =~ "result: :below"
  end

  test "the merge refuses an output directory with nothing to import", ctx do
    File.mkdir_p!(ctx.out)

    {output, status} = merge(ctx, 90)

    assert status != 0
    assert output =~ "No coverage exports (*.coverdata) in #{ctx.out}/ to merge"
  end

  test "the task exits with status 1 below the threshold, and returns :ok at it", ctx do
    {_, 0} = export(ctx, "partition-1", :a)

    check = fn threshold ->
      run(ctx.tmp_dir, """
      try do
        result = Mix.Tasks.Slipdock.Coverage.check(#{inspect(ctx.ebin)},
          output: #{inspect(ctx.out)}, summary: [threshold: #{threshold}])
        IO.puts("returned \#{inspect(result)}")
      catch
        :exit, reason -> IO.puts("exit \#{inspect(reason)}")
      end
      """)
    end

    {below, 0} = check.(16)
    assert below =~ "exit {:shutdown, 1}"

    {met, 0} = check.(15)
    assert met =~ "returned :ok"
  end

  test "without an export, a run below the threshold fails the suite", ctx do
    {output, 0} =
      run(ctx.tmp_dir, """
      done = Slipdock.Coverage.start(#{inspect(ctx.ebin)},
        export: false, output: #{inspect(ctx.out)}, summary: [threshold: 90])
      CoverageSample.a()
      try do
        done.()
        IO.puts("passed")
      catch
        :throw, :test_failed -> IO.puts("thrown :test_failed")
      end
      """)

    assert output =~ "threshold not met: 90%"
    assert output =~ "thrown :test_failed"
    refute File.exists?(Path.join(ctx.out, "partition-1.coverdata"))

    {at, 0} =
      run(ctx.tmp_dir, """
      done = Slipdock.Coverage.start(#{inspect(ctx.ebin)},
        output: #{inspect(ctx.out)}, summary: [threshold: 15])
      CoverageSample.a()
      done.()
      IO.puts("passed")
      """)

    assert at =~ "passed"
    refute at =~ "threshold not met"
  end

  # A Mix project of its own, with the sample in `lib/` and a `mix.exs`
  # that sets `threshold`: where `mix slipdock.coverage` reads its
  # threshold from, and where it looks for `cover/` when nobody says.
  defp scratch_project(dir, threshold) do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule CoverageScratch.MixProject do
      use Mix.Project

      def project do
        [
          app: :coverage_scratch,
          version: "0.1.0",
          # The task comes from this app's ebin on the code path, which
          # isn't one of the scratch project's dependencies.
          prune_code_paths: false,
          test_coverage: [summary: [threshold: #{threshold}]]
        ]
      end
    end
    """)
  end

  # `mix` in the scratch project, with this app's beams on the code path.
  # The build goes in the project's own `_build`, whatever this suite's is.
  defp mix(dir, args) do
    app_ebin = Application.app_dir(:slipdock, "ebin")

    System.cmd("elixir", ["-pa", app_ebin, "-S", "mix" | args],
      cd: dir,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"MIX_BUILD_ROOT", nil},
        {"MIX_BUILD_PATH", nil},
        {"MIX_EXS", nil},
        {"MIX_TEST_PARTITION", nil}
      ]
    )
  end

  describe "mix slipdock.coverage, the task CI runs" do
    # The export a partition leaves in `cover/`, made in the project's own
    # build so the merge imports it into the same module.
    defp export_in_project(dir) do
      {output, 0} =
        mix(dir, [
          "run",
          "--no-start",
          "-e",
          """
          done = Slipdock.Coverage.start(Mix.Project.compile_path(), export: "partition-1")
          CoverageSample.a()
          done.()
          """
        ])

      assert output =~ "Coverage exported to cover/partition-1.coverdata"
      assert File.regular?(Path.join(dir, "cover/partition-1.coverdata"))
    end

    test "exits 1 below the threshold in mix.exs, reading cover/ unasked", %{tmp_dir: dir} do
      scratch_project(dir, 16)
      export_in_project(dir)

      {output, status} = mix(dir, ["slipdock.coverage"])

      assert output =~ "Importing cover/partition-1.coverdata"
      assert total(output) == 15.38
      assert output =~ "Coverage test failed, threshold not met: 16%"
      assert status == 1
    end

    test "exits 0 at a threshold in mix.exs the exports meet", %{tmp_dir: dir} do
      scratch_project(dir, 15)
      export_in_project(dir)

      {output, status} = mix(dir, ["slipdock.coverage"])

      assert output =~ "Importing cover/partition-1.coverdata"
      assert total(output) == 15.38
      refute output =~ "threshold not met"
      assert File.regular?(Path.join(dir, "cover/CoverageSample.html"))
      assert status == 0
    end

    test "--no-compile merges into the build as it is, compiling nothing", %{tmp_dir: dir} do
      scratch_project(dir, 15)
      export_in_project(dir)
      # A change Mix would compile, and the merge would then count: a
      # third function makes the module's lines more and its share less.
      File.write!(
        Path.join(dir, "lib/coverage_sample.ex"),
        String.replace(@source, "  def b do", "  def c, do: :c\n\n  def b do")
      )

      {output, status} = mix(dir, ["slipdock.coverage", "--no-compile"])

      refute output =~ "Compiling"
      assert output =~ "Importing cover/partition-1.coverdata"
      assert total(output) == 15.38
      assert status == 0

      # Without it, the change is compiled and counted, below the threshold.
      {compiled, 1} = mix(dir, ["slipdock.coverage"])
      assert compiled =~ "Compiling 1 file"
      assert total(compiled) == 12.5
    end

    test "--no-compile with no build there refuses, not passing on nothing", %{tmp_dir: dir} do
      scratch_project(dir, 0)
      File.mkdir_p!(Path.join(dir, "cover"))
      File.write!(Path.join(dir, "cover/partition-1.coverdata"), "")

      {output, status} = mix(dir, ["slipdock.coverage", "--no-compile"])

      refute output =~ "Compiling"
      assert output =~ ~r"No beams in \S*_build/test/lib/coverage_scratch/ebin to cover-compile"
      refute output =~ "| Total"
      assert status == 1
    end

    test "fails when cover/ holds no export", %{tmp_dir: dir} do
      scratch_project(dir, 0)

      {output, status} = mix(dir, ["slipdock.coverage"])

      assert output =~ "No coverage exports (*.coverdata) in cover/ to merge"
      assert status == 1
    end
  end

  test "the merge fails on an export it can't import", ctx do
    {_, 0} = export(ctx, "partition-1", :a)
    # Nothing :cover can open as an export: a directory under the name.
    broken = Path.join(ctx.out, "partition-2.coverdata")
    File.mkdir_p!(broken)

    {output, status} = merge(ctx, 0)

    assert status != 0
    assert output =~ "Could not import #{broken}"
    refute output =~ "result:"
    refute output =~ "| Total"
  end

  test "an export that can't be written fails the suite", ctx do
    # No `missing/` under the output directory, so the file can't be opened.
    {output, 0} =
      run(ctx.tmp_dir, """
      done = Slipdock.Coverage.start(#{inspect(ctx.ebin)},
        export: "missing/partition-1", output: #{inspect(ctx.out)})
      CoverageSample.a()
      try do
        done.()
        IO.puts("passed")
      catch
        :throw, :test_failed -> IO.puts("thrown :test_failed")
      end
      """)

    file = Path.join(ctx.out, "missing/partition-1.coverdata")
    assert output =~ "Could not export coverage to #{file}"
    assert output =~ "thrown :test_failed"
    refute output =~ "passed"
    refute output =~ "Coverage exported"
    refute File.exists?(file)
  end

  test "lists that name every beam leave nothing to compile, and nothing to probe", ctx do
    {_, 0} = export(ctx, "partition-1", :a)
    File.write!(Path.join(ctx.out, "partition-1.skipped"), "Elixir.CoverageSample\n")

    {output, 0} = merge(ctx, 90)

    assert output =~ "Compiled in one call, leaving out the 1 the exports list"
    refute output =~ "trying each chunk"
    assert output =~ "Not measured (:cover could not compile them): CoverageSample"
    refute output =~ ~r/\| CoverageSample$/m
    assert output =~ "result: :ok"
  end

  test "the merge leaves its own two modules out of what it cover-compiles", ctx do
    # As in the app's build, where they sit beside everything else: :cover
    # reloads what it compiled when it stops, and the purge kills whoever
    # is running the old code, which here is the merge itself.
    app_ebin = Application.app_dir(:slipdock, "ebin")

    for mod <- [Slipdock.Coverage, Mix.Tasks.Slipdock.Coverage] do
      File.cp!(Path.join(app_ebin, "#{mod}.beam"), Path.join(ctx.ebin, "#{mod}.beam"))
    end

    {_, 0} = export(ctx, "partition-1", :a)

    {output, 0} =
      run(ctx.tmp_dir, """
      result = Mix.Tasks.Slipdock.Coverage.check(#{inspect(ctx.ebin)},
        output: #{inspect(ctx.out)}, summary: [threshold: 15])
      IO.puts("returned \#{inspect(result)}")
      """)

    assert output =~ "returned :ok"
    assert total(output) == 15.38
    refute output =~ "Not measured"
  end

  # Beams :cover can't compile, as some of the app's are on OTP 27 (#2848):
  # one whose debug info is code that doesn't compile, which kills the
  # server and the caller mid-call as the real ones do, and one with no
  # debug info at all, which :cover refuses without dying. The `file`
  # attribute is what gets a broken one that far: without it :cover
  # refuses it too (`:no_file_attribute`), and nothing dies.
  defp write_bad_beams(ebin) do
    for {mod, debug} <- [
          {CoverageBadA, :broken},
          {CoverageBadB, :none},
          {CoverageWorse, :broken}
        ] do
      forms = [
        {:attribute, 1, :file, {~c"coverage_bad.erl", 1}},
        {:attribute, 1, :module, mod},
        {:attribute, 1, :export, [f: 0]},
        {:function, 1, :f, 0, [{:clause, 1, [], [], [{:atom, 1, :ok}]}]}
      ]

      opts =
        case debug do
          # `f` returns a variable nobody bound.
          :broken ->
            unbound = put_elem(Enum.at(forms, 3), 4, [{:clause, 1, [], [], [{:var, 1, :X}]}])
            [{:debug_info, {:erl_abstract_code, {List.replace_at(forms, 3, unbound), []}}}]

          :none ->
            []
        end

      {:ok, ^mod, beam} = :compile.forms(forms, [:binary | opts])
      File.write!(Path.join(ebin, "#{mod}.beam"), beam)
    end
  end

  # Modules from outside lib/, so the report leaves them out: enough of
  # them that the bad beams land in different chunks. CoverageWorse sorts
  # after them all, so the server it kills holds every chunk tried before
  # it, which the compile after the probe has to put back.
  defp write_fillers(%{tmp_dir: dir, ebin: ebin}, count) do
    source =
      for n <- 1..count, into: "", do: "defmodule CoverageFiller#{n}, do: def(f, do: #{n})\n"

    File.mkdir_p!(Path.join(dir, "other"))
    File.write!(Path.join(dir, "other/fillers.ex"), source)

    {_, 0} =
      System.cmd("elixirc", ["--ignore-module-conflict", "-o", ebin, "other/fillers.ex"],
        cd: dir,
        stderr_to_stdout: true
      )
  end

  test "beams :cover can't compile are named and left out, the rest measured", ctx do
    write_fillers(ctx, 70)
    write_bad_beams(ctx.ebin)

    {exported, 0} = export(ctx, "partition-1", :a)
    assert exported =~ "Coverage exported"

    # Its list goes beside the export, for the merge to go by.
    assert File.read!(Path.join(ctx.out, "partition-1.skipped")) ==
             "Elixir.CoverageBadA\nElixir.CoverageBadB\nElixir.CoverageWorse\n"

    {output, 0} = merge(ctx, 15)

    assert output =~
             "Not measured (:cover could not compile them): CoverageBadA, CoverageBadB, CoverageWorse"

    # With the list, the merge never tried them.
    assert output =~ "Compiled in one call, leaving out the 3 the exports list"
    refute output =~ "trying each chunk"
    assert total(output) == 15.38
    assert output =~ "result: :ok"

    # A list that misses some: the one call fails, and the merge finds them
    # all as the partition did. Missing B, :cover refuses it and the call
    # returns; missing A and Worse, the call dies with the server.
    for listed <- ["Elixir.CoverageBadA\nElixir.CoverageWorse\n", "Elixir.CoverageBadB\n"] do
      File.write!(Path.join(ctx.out, "partition-1.skipped"), listed)

      {stale, 0} = merge(ctx, 15)

      assert stale =~ "The exports' lists missed a module: trying each chunk"
      refute stale =~ "Compiled in one call"

      assert stale =~
               "Not measured (:cover could not compile them): CoverageBadA, CoverageBadB, CoverageWorse"

      assert total(stale) == 15.38
      assert stale =~ "result: :ok"
    end

    # No lists at all, as from an export made before them: it finds them.
    File.rm!(Path.join(ctx.out, "partition-1.skipped"))

    {unlisted, 0} = merge(ctx, 15)

    refute unlisted =~ "Compiled in one call"
    refute unlisted =~ "missed a module"

    assert unlisted =~
             "Not measured (:cover could not compile them): CoverageBadA, CoverageBadB, CoverageWorse"

    assert total(unlisted) == 15.38

    # Every filler was cover-compiled, in whichever chunk it fell.
    {modules, 0} =
      run(ctx.tmp_dir, """
      Slipdock.Coverage.start(#{inspect(ctx.ebin)}, export: "x", output: #{inspect(ctx.out)})
      IO.puts("cover: \#{:cover.modules() |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join(",")}")
      """)

    [_, listed] = Regex.run(~r/^cover: (.*)$/m, modules)
    compiled = String.split(listed, ",")
    assert length(compiled) == 71
    assert "CoverageSample" in compiled
    assert "CoverageFiller70" in compiled
    refute Enum.any?(compiled, &String.starts_with?(&1, "CoverageBad"))
    refute "CoverageWorse" in compiled
  end

  # Runs the probe with a hook in each chunk (#2917) that reports, before
  # the chunk compiles: whether it holds a bad beam (so fails), the :cover
  # server it finds, and every other process under its group leader. A
  # chunk that will fail also leaves a straggler as :cover's pmap workers
  # are: spawned from a fun by the chunk, so `initial_call` says nothing of
  # :cover, and still running when the chunk dies. Each chunk also reports
  # the group leader it runs under.
  #
  # Options: `before:`, code run first; `respawn: true`, a failing chunk
  # also leaves a spawner the way a live :cover server is one (#2917): off
  # the chunk's group leader, so stop_cover/1 doesn't list it, and linked
  # to 1000 stragglers under it. When the first of those is killed, it
  # starts one more process under the leader, which only a second look
  # finds: it runs at high priority, so it does so while stop_cover/1 is
  # still killing and waiting on the rest. Each respawned process is reported, and whether it lives on.
  defp probe_chunks(ctx, opts \\ []) do
    run(ctx.tmp_dir, """
    me = self()
    {:group_leader, outer} = Process.info(self(), :group_leader)
    respawn? = #{inspect(Keyword.get(opts, :respawn, false))}

    :persistent_term.put({Slipdock.Coverage, :chunk_hook}, fn beams ->
      {:group_leader, gl} = Process.info(self(), :group_leader)

      left =
        for p <- Process.list(), p != self(),
            Process.info(p, :group_leader) == {:group_leader, gl}, do: p

      bad = Enum.any?(beams, &(&1 =~ ~r/CoverageBad|CoverageWorse/))
      straggler = if bad, do: spawn(fn -> receive do: (:never -> :ok) end)
      born = straggler && Process.info(straggler, :initial_call)
      registered = Process.whereis(Slipdock.Coverage.ProbeLeader)
      send(me, {:chunk, bad, Process.whereis(:cover_server), left, {straggler, born}, {gl, registered}})

      if bad and respawn? do
        chunk = self()

        spawn(fn ->
          Process.flag(:trap_exit, true)
          Process.flag(:priority, :high)
          for _ <- 1..1000, do: spawn_link(fn -> receive do: (:never -> :ok) end)
          Process.group_leader(self(), outer)
          send(chunk, :spawner_ready)

          receive do
            {:EXIT, _, _} ->
              r = spawn(fn -> receive do: (:never -> :ok) end)
              Process.group_leader(r, gl)
              send(me, {:respawned, r})
          end
        end)

        receive do: (:spawner_ready -> :ok)
      end
    end)

    #{Keyword.get(opts, :before, "")}
    Slipdock.Coverage.start(#{inspect(ctx.ebin)}, export: "x", output: #{inspect(ctx.out)})

    respawned = Stream.repeatedly(fn -> receive do: ({:respawned, r} -> r), after: (0 -> nil) end)
    respawned = Enum.take_while(respawned, & &1)
    IO.puts("respawned: \#{length(respawned)}, alive \#{Enum.count(respawned, &Process.alive?/1)}")

    chunks = Stream.repeatedly(fn -> receive do: ({:chunk, _, _, _, _, _} = c -> c), after: (0 -> nil) end)
    chunks = Enum.take_while(chunks, & &1)
    IO.puts("chunks: \#{length(chunks)}")

    leaders = chunks |> Enum.map(&elem(&1, 5)) |> Enum.uniq()
    IO.puts("leaders: \#{length(leaders)}, all registered \#{Enum.all?(leaders, fn {gl, reg} -> gl == reg end)}")

    for [{:chunk, true, _, _, _, _}, {:chunk, _, server, left, _, _}] <- Enum.chunk_every(chunks, 2, 1, :discard) do
      IO.puts("after a failed chunk: server \#{inspect(server)}, left \#{length(left)}")
    end

    for {:chunk, true, _, _, {s, born}, _} <- chunks do
      IO.puts("straggler \#{inspect(born)}, alive \#{Process.alive?(s)}")
    end

    if first = Process.get(:first_server), do: IO.puts("first server alive: \#{Process.alive?(first)}")

    IO.puts("cover: \#{:cover.modules() |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join(",")}")
    """)
  end

  test "a chunk that fails stops what :cover left running before the next try", ctx do
    write_fillers(ctx, 40)
    write_bad_beams(ctx.ebin)

    {output, 0} = probe_chunks(ctx)

    # Each bad beam fails a chunk, and is halved down to alone.
    failed = Regex.scan(~r/^after a failed chunk: server (.*), left (\d+)$/m, output)
    assert length(failed) >= 3

    # The next chunk starts with nothing of the last one left: no server,
    # no worker, no straggler.
    assert Enum.all?(failed, &match?([_, "nil", "0"], &1))

    # Every chunk ran under the one registered probe leader, so what a
    # chunk that compiled left (the server it started keeps that chunk's
    # leader, and so do its workers) is found when a later one fails.
    assert output =~ ~r/^leaders: 1, all registered true$/m

    # Each straggler was spawned from a fun, as :cover's are, and is gone.
    stragglers = Regex.scan(~r/^straggler (.*)$/m, output, capture: :all_but_first)
    assert length(stragglers) > length(failed)
    assert Enum.uniq(stragglers) == [["{:initial_call, {:erlang, :apply, 2}}, alive false"]]

    [_, listed] = Regex.run(~r/^cover: (.*)$/m, output)
    compiled = String.split(listed, ",")
    assert length(compiled) == 41
    assert "CoverageSample" in compiled
    refute Enum.any?(compiled, &String.starts_with?(&1, "CoverageBad"))
  end

  test "a failed chunk looks again for what was started while it stopped :cover", ctx do
    write_fillers(ctx, 40)
    write_bad_beams(ctx.ebin)

    # A spawner off the leader starts a process under it as the first of
    # its 1000 stragglers is killed: only a second look at the leader's
    # processes finds that one, as it finds a worker a live server starts.
    {output, 0} = probe_chunks(ctx, respawn: true)

    [_, respawned, alive] = Regex.run(~r/^respawned: (\d+), alive (\d+)$/m, output)
    assert String.to_integer(respawned) >= 3
    assert alive == "0"

    failed = Regex.scan(~r/^after a failed chunk: server (.*), left (\d+)$/m, output)
    assert length(failed) >= 3
    assert Enum.all?(failed, &match?([_, "nil", "0"], &1))
  end

  test "a straggler of :cover's looks like any process: spawned from a fun", ctx do
    {output, 0} =
      run(ctx.tmp_dir, """
      {:ok, server} = :cover.start()
      IO.inspect(Process.info(server, :initial_call), label: "server")
      """)

    assert output =~ "server: {:initial_call, {:erlang, :apply, 2}}"
  end

  test "a failed chunk that leaves the server alive gets a new one", ctx do
    write_fillers(ctx, 3)
    write_bad_beams(ctx.ebin)
    File.rm!(Path.join(ctx.ebin, "Elixir.CoverageBadA.beam"))
    File.rm!(Path.join(ctx.ebin, "Elixir.CoverageWorse.beam"))

    # CoverageBadB alone: :cover refuses it and the server lives on. Started
    # here, the server isn't under the probe's group leader: it goes by name.
    {output, 0} =
      probe_chunks(ctx,
        before: """
        {:ok, first} = :cover.start()
        Process.put(:first_server, first)
        """
      )

    assert output =~ "first server alive: false"

    failed = Regex.scan(~r/^after a failed chunk: server (.*), left (\d+)$/m, output)
    assert failed != []
    assert Enum.all?(failed, &match?([_, "nil", "0"], &1))

    [_, listed] = Regex.run(~r/^cover: (.*)$/m, output)
    assert length(String.split(listed, ",")) == 4
  end
end
