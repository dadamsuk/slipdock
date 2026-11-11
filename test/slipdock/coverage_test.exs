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
end
