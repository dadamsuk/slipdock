defmodule Slipdock.CiWorkflowTest do
  @moduledoc """
  The static checks in .github/workflows/ci.yml. Each one started at zero
  findings, so it only protects anything while it still runs on every pull
  request: these are the lines whose loss would go unnoticed until a finding
  slipped through.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @ci File.read!(Path.join(@root, ".github/workflows/ci.yml"))

  # Comments stripped, so a step only mentioned in a comment does not count.
  defp lines(text),
    do:
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

  # One job's lines: from `  <name>:` to the next job at the same indent.
  defp job(name) do
    [_, rest] = String.split(@ci, "\n  #{name}:\n", parts: 2)
    body = rest |> String.split(~r/\n  [a-z][a-z0-9_-]*:\n/, parts: 2) |> hd()
    lines(body)
  end

  defp has?(lines, line), do: Enum.member?(lines, line)

  # A step's `run:` line inside a job, as written.
  defp runs?(job, command), do: has?(job, "run: #{command}")

  test "the workflow runs on every pull request" do
    assert has?(lines(@ci), "pull_request:")
  end

  test "no static check is allowed to fail quietly" do
    refute Enum.any?(lines(@ci), &(&1 =~ "continue-on-error"))
  end

  test "the static checks job is not skipped on any event" do
    refute Enum.any?(job("static"), &String.starts_with?(&1, "if:"))
  end

  describe "dependency audit" do
    test "the app's dependencies are checked for retired packages and advisories" do
      static = job("static")
      assert runs?(static, "mix hex.audit")
      assert runs?(static, "mix deps.audit")
    end

    test "the CLI's dependencies are checked too" do
      assert runs?(job("cli"), "mix hex.audit")
    end

    test "mix_audit is a dependency in the environment CI runs in" do
      mix_exs = File.read!(Path.join(@root, "mix.exs"))
      assert mix_exs =~ ~r/\{:mix_audit, "[^"]+", only: \[[^\]]*:test[^\]]*\]/
      assert has?(lines(@ci), "MIX_ENV: test")
    end
  end

  describe "sobelow" do
    test "runs with its config, failing on any finding" do
      assert runs?(job("static"), "mix sobelow --config")

      {conf, _} = Code.eval_file(Path.join(@root, ".sobelow-conf"))
      assert conf[:exit] == "low"
      assert conf[:threshold] == "low"
      assert conf[:skip] == true
    end

    test "every type ignored in .sobelow-conf has its reason there" do
      {conf, _} = Code.eval_file(Path.join(@root, ".sobelow-conf"))
      text = File.read!(Path.join(@root, ".sobelow-conf"))

      for type <- conf[:ignore] do
        assert text =~ ~r/^#\s+#{Regex.escape(type)}\s+\S/m, "no reason for #{type}"
      end
    end

    test "every skip in the code has a reason on the line above" do
      skips =
        for file <- Path.wildcard(Path.join(@root, "lib/**/*.ex")),
            [prev, line] <- file |> File.read!() |> String.split("\n") |> Enum.chunk_every(2, 1),
            line =~ ~r/#\s*sobelow_skip\s*\[/,
            do: {Path.relative_to(file, @root), String.trim(prev)}

      assert skips != []

      for {file, prev} <- skips do
        assert String.starts_with?(prev, "# Not a hole: "), "#{file}: a skip with no reason"
      end
    end

    test "no fingerprint skips, which would break on the next edit above them" do
      refute File.exists?(Path.join(@root, ".sobelow-skips"))
    end
  end

  describe "gitleaks" do
    test "scans the commits each pull request adds, failing on a hit" do
      secrets = job("secrets")

      assert has?(secrets, "if: github.event_name == 'pull_request'")
      assert has?(secrets, "fetch-depth: 0")
      assert has?(secrets, "BASE: ${{ github.event.pull_request.base.sha }}")
      assert has?(secrets, "HEAD: ${{ github.event.pull_request.head.sha }}")

      assert runs?(
               secrets,
               ~s(/tmp/gitleaks git --redact --no-banner --verbose --log-opts="$BASE..$HEAD" .)
             )
    end

    test "the binary is checked against its published checksum" do
      assert Enum.any?(
               job("secrets"),
               &(&1 =~ ~r/^echo "[0-9a-f]{64}  \/tmp\/gitleaks.tgz" \| sha256sum -c -$/)
             )
    end

    test "every allowlist in .gitleaks.toml says why, and extends gitleaks' own rules" do
      toml = File.read!(Path.join(@root, ".gitleaks.toml"))
      assert toml =~ ~r/^\[extend\]\nuseDefault = true$/m

      blocks = toml |> String.split("[[allowlists]]") |> tl()
      assert blocks != []

      for block <- blocks do
        assert block =~ ~r/^description = "[^"]{20,}"$/m
      end
    end
  end

  describe "credo" do
    test "lints only what a change adds, against where it left main" do
      static = job("static")

      assert runs?(
               static,
               ~s(mix credo diff --from-git-merge-base origin/main --config-file "$PWD/.credo.exs")
             )

      # The merge base needs the history.
      assert has?(static, "fetch-depth: 0")
    end

    test ".credo.exs loads our own checks and gives a reason for each tuning" do
      text = File.read!(Path.join(@root, ".credo.exs"))
      {config, _} = Code.eval_string(text)
      [default] = config.configs

      assert default.requires == ["credo/checks/"]

      assert {Slipdock.Credo.InOutsideGuard, _} =
               List.keyfind(default.checks.enabled, Slipdock.Credo.InOutsideGuard, 0)

      # Our own tunings of credo's defaults each have a comment above them.
      for name <- ["Slipdock.Credo.InOutsideGuard", "Credo.Check.Readability.LargeNumbers"] do
        assert text =~ ~r/#[^\n]*\n\s*\{#{Regex.escape(name)}, \[[^\]]/,
               "#{name} is tuned without a reason"
      end

      # Nothing credo turns on by default is off, and the opt-ins left off say why.
      assert text =~ "Nothing that credo turns on by default is off here."
    end
  end

  describe "context boundaries" do
    test "are checked by the suite CI runs on every partition" do
      assert File.exists?(Path.join(@root, "test/slipdock/boundaries_test.exs"))
      assert has?(job("test"), "mix test $files")
    end
  end

  # The epic's bar (#1766): every static check in one place, so losing any
  # one of them fails here as well as in its own describe block above.
  test "all five static checks run on a pull request, for the app and the CLI where they apply" do
    static = job("static")

    for command <- [
          "mix hex.audit",
          "mix deps.audit",
          "mix sobelow --config",
          ~s(mix credo diff --from-git-merge-base origin/main --config-file "$PWD/.credo.exs")
        ] do
      assert runs?(static, command), "static checks no longer run `#{command}`"
    end

    assert Enum.any?(job("secrets"), &String.starts_with?(&1, "run: /tmp/gitleaks git "))
    assert File.exists?(Path.join(@root, "test/slipdock/boundaries_test.exs"))

    # The CLI: no dependencies to read for deps.audit; credo covers it from
    # the root; gitleaks scans the whole repository; sobelow is Phoenix-only.
    assert runs?(job("cli"), "mix hex.audit")
    assert File.read!(Path.join(@root, ".credo.exs")) =~ ~s("cli/lib/")
  end

  describe "mix pre_push (#1866)" do
    # The alias's steps as CI writes them: credo's absolute config path is
    # CI's "$PWD/.credo.exs".
    defp pre_push_commands do
      config = Path.join(@root, ".credo.exs")

      for {task, argv} <- Mix.Project.get!().pre_push_steps() do
        argv = Enum.map(argv, &if(&1 == config, do: ~s("$PWD/.credo.exs"), else: &1))
        Enum.join(["mix", task | argv], " ")
      end
    end

    defp mix_runs(job) do
      for "run: mix " <> _ = line <- job,
          line != "run: mix deps.get",
          do: String.replace_prefix(line, "run: ", "")
    end

    test "runs every mix command the static checks job runs" do
      static = mix_runs(job("static"))
      assert "mix sobelow --config" in static

      for command <- static do
        assert command in pre_push_commands(),
               "CI's static checks run `#{command}`, which `mix pre_push` doesn't"
      end
    end

    test "in the static job's order" do
      static = mix_runs(job("static"))
      assert Enum.filter(pre_push_commands(), &(&1 in static)) == static
    end

    test "covers the build's compile and format checks, before the static ones" do
      test_job = mix_runs(job("test"))
      assert "mix compile --warnings-as-errors" in test_job
      assert "mix format --check-formatted" in test_job

      assert [
               "mix compile --force --warnings-as-errors",
               "mix format --check-formatted" | _
             ] = pre_push_commands()
    end
  end

  # The build cache and the partition split (#1858).
  describe "build cache" do
    defp step_index(job, line), do: Enum.find_index(job, &(&1 == line))

    test "is keyed on the toolchain, the lock, mix.exs and config, then the code" do
      test_job = job("test")

      assert has?(
               test_job,
               ~S|deps="${{ runner.os }}-mix-${{ steps.beam.outputs.elixir-version }}-| <>
                 ~S|${{ steps.beam.outputs.otp-version }}-${{ hashFiles('**/mix.lock') }}"|
             )

      assert has?(test_job, ~S|config="$deps-${{ hashFiles('mix.exs', 'config/**') }}"|)

      assert Enum.any?(
               test_job,
               &(&1 =~ ~S|echo "code=$config-${{ hashFiles('lib/**', 'test/support/**',|)
             )

      assert has?(test_job, "key: ${{ steps.keys.outputs.code }}")
    end

    test "restores the newest build sharing the longest prefix, most specific first" do
      test_job = job("test")
      [_ | rest] = Enum.drop_while(test_job, &(&1 != "restore-keys: |"))

      assert Enum.take(rest, 3) == [
               "${{ steps.keys.outputs.config }}-",
               "${{ steps.keys.outputs.deps }}-",
               "${{ runner.os }}-mix-${{ steps.beam.outputs.elixir-version }}-" <>
                 "${{ steps.beam.outputs.otp-version }}-"
             ]

      assert has?(test_job, "- uses: actions/cache/restore@v4")
    end

    test "backdates mix.exs and config only when the build came from the same ones" do
      test_job = job("test")
      touch = step_index(test_job, "run: touch -d 2000-01-01 mix.exs config/*.exs")
      assert touch

      assert Enum.at(test_job, touch - 1) ==
               "if: startsWith(steps.mix-cache.outputs.cache-matched-key, " <>
                 "format('{0}-', steps.keys.outputs.config))"

      # Before anything compiles.
      assert touch < step_index(test_job, "run: mix deps.get")
    end

    test "partition 1 saves the build under this tree's key after a clean compile" do
      test_job = job("test")
      compile = step_index(test_job, "run: mix compile --warnings-as-errors")
      save = step_index(test_job, "- uses: actions/cache/save@v4")

      assert compile < save
      assert save < step_index(test_job, "- name: Test")

      assert Enum.at(test_job, save + 1) ==
               "if: matrix.partition == 1 && steps.mix-cache.outputs.cache-hit != 'true'"

      assert test_job |> Enum.drop(save) |> Enum.find(&String.starts_with?(&1, "key:")) ==
               "key: ${{ steps.keys.outputs.code }}"
    end

    test "the compile still fails on any warning, old or new" do
      refute Enum.any?(lines(@ci), &(&1 =~ "--no-all-warnings"))
      assert runs?(job("test"), "mix compile --warnings-as-errors")
    end

    test "the static checks keep a cache of their own" do
      keys = Enum.filter(job("static"), &String.starts_with?(&1, "key: "))
      assert [key] = keys
      assert key =~ "-mix-static-"
      refute Enum.any?(job("static"), &(&1 =~ "steps.keys.outputs"))
    end

    @tag :tmp_dir
    test "Mix reports an unchanged file's warning again, so the build still fails", %{
      tmp_dir: dir
    } do
      File.write!(Path.join(dir, "mix.exs"), """
      defmodule WarnOnce.MixProject do
        use Mix.Project
        def project, do: [app: :warn_once, version: "0.1.0"]
      end
      """)

      File.mkdir_p!(Path.join(dir, "lib"))

      File.write!(
        Path.join(dir, "lib/warn_once.ex"),
        "defmodule WarnOnce do\n  def f(x), do: 1\nend\n"
      )

      mix = fn args ->
        System.cmd("mix", args, cd: dir, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])
      end

      # The first compile writes the warning into the manifest and passes.
      assert {out, 0} = mix.(["compile"])
      assert out =~ "variable \"x\" is unused"

      # Nothing changed, nothing recompiles, and the stored warning still fails it.
      assert {out, status} = mix.(["compile", "--warnings-as-errors"])
      assert status != 0
      assert out =~ "variable \"x\" is unused"
    end
  end

  describe "test partitions" do
    alias Slipdock.TestPartitions

    defp weights,
      do: TestPartitions.parse(File.read!(Path.join(@root, TestPartitions.weights_path())))

    defp files, do: TestPartitions.test_files(@root)

    test "the test job splits the files by runtime, four ways, not by mix's round robin" do
      test_job = job("test")
      refute Enum.any?(test_job, &(&1 =~ "--partitions"))
      assert has?(test_job, "partition: [1, 2, 3, 4]")

      assert has?(
               test_job,
               ~S|files=$(elixir test/support/test_partitions.exs split 4 "$MIX_TEST_PARTITION")|
             )

      assert has?(test_job, "mix test $files")
    end

    test "each partition records its timings and uploads them" do
      test_job = job("test")

      assert has?(
               test_job,
               "TEST_TIMINGS_FILE: test-timings/test-timings-${{ matrix.partition }}.tsv"
             )

      assert has?(test_job, "name: test-timings-${{ matrix.partition }}")
    end

    test "every test file runs in exactly one partition" do
      partitions = TestPartitions.split(files(), weights(), 4)

      assert length(partitions) == 4
      assert Enum.all?(partitions, &(&1 != []))
      assert partitions |> List.flatten() |> Enum.sort() == files()
    end

    test "the checked-in weights split within 10% of each other" do
      weights = weights()
      loads = files() |> TestPartitions.split(weights, 4) |> TestPartitions.loads(weights)
      [first | rest] = loads
      loads = [first + TestPartitions.first_partition_extra_ms() | rest]
      assert Enum.max(loads) <= Enum.min(loads) * 1.1, inspect(loads)
    end

    test "the weights know most of the test files" do
      known = Enum.count(files(), &Map.has_key?(weights(), &1))

      assert known >= length(files()) * 0.8,
             "only #{known} of #{length(files())} test files have a runtime: refresh " <>
               "test/support/partition_weights.tsv (test/support/test_partitions.exs)"
    end

    test "an async file costs a seventh of its time, a sync file all of it" do
      assert TestPartitions.cost({true, 700}) == 700
      assert TestPartitions.cost({false, 700}) == 100

      # One sync file is worth seven async ones as long. Partition 1's
      # head start puts the sync file in partition 2.
      weights =
        Map.new(1..7, &{"a#{&1}", {false, 700_000}}) |> Map.put("s1", {true, 700_000})

      [first, second] = TestPartitions.split(Map.keys(weights), weights, 2)
      assert second == ["s1"]
      assert length(first) == 7
      assert TestPartitions.loads([first, second], weights) == [700_000.0, 700_000]
    end

    test "partition 1 gets less of the suite, for the checks only it runs" do
      test_job = job("test")
      assert Enum.count(test_job, &(&1 == "if: matrix.partition == 1")) >= 3

      extra = TestPartitions.first_partition_extra_ms()
      assert extra > 0
      weights = Map.new(1..3, &{"s#{&1}", {true, extra}})

      # Three equal files over two partitions: without the head start
      # partition 1 would take two; one file behind, it takes one.
      [first, second] = TestPartitions.split(Map.keys(weights), weights, 2)
      assert {length(first), length(second)} == {1, 2}
    end

    test "the costliest files are spread out first" do
      weights = %{
        "big" => {true, 300_000},
        "a1" => {false, 1_400_000},
        "a2" => {false, 700_000}
      }

      partitions = TestPartitions.split(Map.keys(weights), weights, 2)
      assert partitions == [["a1", "a2"], ["big"]]
      assert TestPartitions.loads(partitions, weights) == [300_000.0, 300_000]
    end

    test "a new file goes where its path's hash says, and moves no other file" do
      weights = weights()
      before = TestPartitions.split(files(), weights, 4)
      new_file = "test/slipdock/zz_brand_new_test.exs"
      after_ = TestPartitions.split([new_file | files()], weights, 4)

      index = :erlang.phash2(new_file, 4)
      assert new_file in Enum.at(after_, index)
      assert Enum.map(after_, &List.delete(&1, new_file)) == before
    end

    test "the same weights always give the same split" do
      assert TestPartitions.split(files(), weights(), 4) ==
               TestPartitions.split(Enum.reverse(files()), weights(), 4)
    end

    test "with no weights at all every file still runs once" do
      partitions = TestPartitions.split(files(), %{}, 4)
      assert partitions |> List.flatten() |> Enum.sort() == files()
    end

    test "merging runs averages each file, keeps sync, and drops deleted files" do
      run1 = %{"a" => {false, 100}, "b" => {false, 10}, "gone" => {false, 5}}
      run2 = %{"a" => {true, 300}}

      assert TestPartitions.merge([run1, run2], ["a", "b"]) ==
               %{"a" => {true, 200}, "b" => {false, 10}}
    end

    test "render and parse round-trip, comments ignored" do
      weights = %{"test/a_test.exs" => {true, 12}, "test/b_test.exs" => {false, 3}}
      text = TestPartitions.render(weights)
      assert text =~ ~r/^# /
      assert TestPartitions.parse(text) == weights
    end

    test "the script prints a partition's files, and refuses a partition out of range" do
      script = Path.join(@root, "test/support/test_partitions.exs")

      {out, 0} = System.cmd("elixir", [script, "split", "4", "3"], cd: @root)

      assert String.split(out, "\n", trim: true) ==
               Enum.at(TestPartitions.split(files(), weights(), 4), 2)

      assert {_, 2} =
               System.cmd("elixir", [script, "split", "4", "5"],
                 cd: @root,
                 stderr_to_stdout: true
               )

      assert {_, 2} =
               System.cmd("elixir", [script, "nonsense"], cd: @root, stderr_to_stdout: true)
    end

    @tag :tmp_dir
    test "the script won't write weights from a directory with no timings", %{tmp_dir: dir} do
      script = Path.join(@root, "test/support/test_partitions.exs")
      before = File.read!(Path.join(@root, TestPartitions.weights_path()))

      assert {out, 1} =
               System.cmd("elixir", [script, "weights", dir], cd: @root, stderr_to_stdout: true)

      assert out =~ "no test-timings-*.tsv"
      assert File.read!(Path.join(@root, TestPartitions.weights_path())) == before
    end
  end

  describe "Slipdock.TestTimings" do
    alias Slipdock.TestTimings

    defp module(file, async?),
      do: %ExUnit.TestModule{
        name: Some,
        file: Path.join(File.cwd!(), file),
        tests: [%ExUnit.Test{name: :t, tags: %{async: async?}}]
      }

    test "adds up each file's modules, sync if any of them is" do
      files =
        %{}
        |> TestTimings.add(module("test/a_test.exs", true), 40)
        |> TestTimings.add(module("test/a_test.exs", false), 2)
        |> TestTimings.add(module("test/b_test.exs", true), 7)

      assert files == %{"test/a_test.exs" => {true, 42}, "test/b_test.exs" => {false, 7}}

      assert TestTimings.lines(files) == [
               "test/a_test.exs\tsync\t42\n",
               "test/b_test.exs\tasync\t7\n"
             ]
    end

    test "writes lines the partitioner reads back" do
      files = TestTimings.add(%{}, module("test/c_test.exs", true), 9)
      text = IO.iodata_to_binary(TestTimings.lines(files))
      assert Slipdock.TestPartitions.parse(text) == %{"test/c_test.exs" => {false, 9}}
    end

    test "a module with no tests run counts as async" do
      files =
        TestTimings.add(%{}, %ExUnit.TestModule{name: X, file: "test/d_test.exs", tests: []}, 3)

      assert files == %{"test/d_test.exs" => {false, 3}}
    end
  end
end
