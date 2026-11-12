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
               ~s($RUNNER_TEMP/gitleaks git --redact --no-banner --verbose --log-opts="$BASE..$HEAD" .)
             )
    end

    test "the binary is checked against its published checksum" do
      assert Enum.any?(
               job("secrets"),
               &(&1 =~ ~r/^echo "[0-9a-f]{64}  \$RUNNER_TEMP\/gitleaks.tgz" \| sha256sum -c -$/)
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

      assert has?(
               job("test"),
               ~S|mix test --cover --export-coverage "partition-$MIX_TEST_PARTITION" $files|
             )
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

    assert Enum.any?(
             job("secrets"),
             &String.starts_with?(&1, "run: $RUNNER_TEMP/gitleaks git ")
           )

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

    test "compiles cli/ as the cli job does, with warnings as errors (#1964)" do
      assert "mix compile --warnings-as-errors" in mix_runs(job("cli"))
      assert has?(job("cli"), "working-directory: cli")

      # The step is the cli job's compile line, run in cli/.
      assert {"compile", ["--warnings-as-errors"], cd: "cli"} in Mix.Project.get!().pre_push_steps()
    end

    test "checks cli/'s formatting before its compile, as the cli job does (#2602)" do
      cli = mix_runs(job("cli"))
      assert "mix format --check-formatted" in cli

      # The cli job's format and compile, in the job's order, are pre_push's
      # steps in cli/.
      in_cli =
        for {task, argv, opts} <- Mix.Project.get!().pre_push_steps(),
            opts[:cd] == "cli",
            do: Enum.join(["mix", task | argv], " ")

      assert in_cli == Enum.filter(cli, &(&1 in in_cli))
      assert in_cli == ["mix format --check-formatted", "mix compile --warnings-as-errors"]
    end
  end

  describe "the runner daemon (#2573)" do
    test "is built, vetted and tested on Linux, macOS and Windows" do
      daemon = job("daemon")

      # All three on GitHub's runners; on the self-hosted ones (#2829), the
      # one OS they have (Slipdock.CiRunnerTest).
      assert has?(
               daemon,
               ~s<os: ${{ fromJSON(vars.CI_RUNNER && format('["{0}"]', vars.CI_RUNNER) || '["ubuntu-latest", "macos-latest", "windows-latest"]') }}>
             )

      assert has?(daemon, "runs-on: ${{ matrix.os }}")
      assert has?(daemon, "working-directory: daemon")
      # The newest Go: macOS refuses 1.22's test binaries (missing LC_UUID).
      assert has?(daemon, "go-version: stable")

      for command <- ["go build ./...", "go vet ./...", "go test -race ./..."],
          do: assert(runs?(daemon, command), "the daemon job no longer runs `#{command}`")
    end

    # A data race in a daemon test shows only under the race detector (#2664).
    test "its tests run with the race detector, here and in mix pre_push" do
      refute runs?(job("daemon"), "go test ./..."), "the daemon job runs go test without -race"
      steps = Mix.Project.get!().pre_push_steps()
      assert {"go", ["test", "-race", "./..."], cd: "daemon", exec: true} in steps
      refute {"go", ["test", "./..."], cd: "daemon", exec: true} in steps
    end

    test "one OS failing doesn't cancel the others" do
      assert has?(job("daemon"), "fail-fast: false")
    end

    test "mix pre_push runs the job's vet and tests, in daemon/" do
      steps = Mix.Project.get!().pre_push_steps()

      for "run: go " <> rest <- job("daemon"), rest != "build ./..." do
        step = {"go", String.split(rest), cd: "daemon", exec: true}
        assert step in steps, "CI's daemon job runs `go #{rest}`, which `mix pre_push` doesn't"
      end
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

      assert has?(
               test_job,
               ~S|mix test --cover --export-coverage "partition-$MIX_TEST_PARTITION" $files|
             )
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

  # release.yml's first job, and the script it runs (#1857).
  # GitHub reports a workflow that doesn't parse only as "a workflow file
  # issue" on every push, with no job run (#1916: a colon and a space in a
  # plain scalar stopped every release for an afternoon). The line checks
  # above read the text, so they pass on a file GitHub can't load.
  describe "every workflow parses (#1916)" do
    @workflows Path.wildcard(Path.join(@root, ".github/workflows/*.yml")) ++
                 Path.wildcard(Path.join(@root, "priv/deploy/examples/github-*.yml"))

    test "the list covers the workflows it must" do
      names = Enum.map(@workflows, &Path.relative_to(&1, @root))
      assert ".github/workflows/ci.yml" in names
      assert ".github/workflows/release.yml" in names
      assert "priv/deploy/examples/github-actions.yml" in names
    end

    for path <- @workflows do
      @path path
      test "#{Path.relative_to(path, @root)} is YAML with jobs" do
        assert {:ok, %{"jobs" => jobs}} = YamlElixir.read_from_file(@path),
               "#{@path} does not parse as YAML, or has no jobs"

        assert is_map(jobs) and map_size(jobs) > 0
      end
    end

    test "the deploy note reaches GitHub as the expression it was written as" do
      {:ok, release} =
        YamlElixir.read_from_file(Path.join(@root, ".github/workflows/release.yml"))

      [step] = Enum.filter(release["jobs"]["deploy"]["steps"], &(&1["id"] == "record"))

      assert step["env"]["SLIPDOCK_DEPLOY_NOTE"] ==
               "${{ needs.suite.outputs.note || 'suite: ran' }}"
    end

    test "the check catches the line that broke it, unquoted" do
      assert {:error, _} =
               YamlElixir.read_from_string("""
               env:
                 NOTE: ${{ needs.suite.outputs.note || 'suite: ran' }}
               """)
    end
  end

  describe "the post-merge suite gate" do
    @release File.read!(Path.join(@root, ".github/workflows/release.yml"))
    @gate Path.join(@root, ".github/scripts/suite-gate.sh")

    @sha String.duplicate("a", 40)
    @head String.duplicate("b", 40)
    @tested String.duplicate("c", 40)
    @tree String.duplicate("d", 40)
    @repo "owner/repo"

    defp release_job(name) do
      [_, rest] = String.split(@release, "\n  #{name}:\n", parts: 2)
      rest |> String.split(~r/\n  [a-z][a-z0-9_-]*:\n/, parts: 2) |> hd() |> lines()
    end

    test "the PR run's name carries the commit it tested" do
      assert has?(
               lines(@ci),
               ~s(run-name: "${{ github.event.pull_request.title }} · tested ${{ github.sha }}")
             )
    end

    test "release.yml runs the gate first, and the suite unless the gate said false" do
      assert has?(release_job("suite"), "run: .github/scripts/suite-gate.sh")
      test_job = release_job("test")
      assert has?(test_job, "needs: suite")
      assert has?(test_job, "if: ${{ !cancelled() && needs.suite.outputs.run != 'false' }}")
      assert has?(test_job, "uses: ./.github/workflows/ci.yml")
    end

    test "merge goes ahead on a passed suite, or one the gate skipped, and nothing else" do
      merge = release_job("merge")
      assert has?(merge, "needs: [suite, test, build]")

      assert has?(
               merge,
               "if: ${{ !cancelled() && needs.build.result == 'success' && (needs.test.result == 'success' || (needs.test.result == 'skipped' && needs.suite.outputs.run == 'false')) }}"
             )
    end

    test "the deploy record carries the gate's note" do
      assert has?(
               release_job("deploy"),
               ~s(SLIPDOCK_DEPLOY_NOTE: "${{ needs.suite.outputs.note || 'suite: ran' }}")
             )
    end

    # A fake `gh api <path>` answering from files in `dir`, one per path; a
    # path with no file is the API failing.
    defp gate(dir, answers, env \\ []) do
      bin = Path.join(dir, "bin")
      api = Path.join(dir, "api")
      out = Path.join(dir, "out")
      summary = Path.join(dir, "summary")
      # A fresh start each call, so one call's answers can't pass for the next's.
      Enum.each([api, out, summary], &File.rm_rf!/1)
      File.mkdir_p!(bin)
      File.mkdir_p!(api)

      File.write!(Path.join(bin, "gh"), """
      #!/usr/bin/env bash
      [ "$1" = api ] || exit 2
      f="#{api}/$(printf %s "$2" | tr '/?&=' '____')"
      [ -f "$f" ] || { echo "HTTP 502" >&2; exit 1; }
      cat "$f"
      """)

      File.chmod!(Path.join(bin, "gh"), 0o755)

      for {path, body} <- answers,
          do:
            File.write!(Path.join(api, String.replace(path, ~r{[/?&=]}, "_")), JSON.encode!(body))

      env =
        [
          {"PATH", bin <> ":" <> System.get_env("PATH")},
          {"EVENT_NAME", "push"},
          {"REF", "refs/heads/main"},
          {"SHA", @sha},
          {"REPO", @repo},
          {"GITHUB_OUTPUT", out},
          {"GITHUB_STEP_SUMMARY", summary},
          {"GIT_DIR", Path.join(dir, "no-repo")}
        ] ++ env

      {stdout, code} = System.cmd(@gate, [], env: env, cd: dir, stderr_to_stdout: true)
      assert code == 0, "the gate failed: #{stdout}"

      outputs =
        for line <- out |> File.read!() |> String.split("\n", trim: true), into: %{} do
          [k, v] = String.split(line, "=", parts: 2)
          {k, v}
        end

      Map.put(outputs, "summary", File.read!(summary))
    end

    defp pulls(prs \\ [%{"number" => 92, "merged_at" => "2026-11-06T05:00:00Z"}]),
      do:
        {"repos/#{@repo}/commits/#{@sha}/pulls",
         Enum.map(prs, &Map.merge(%{"merge_commit_sha" => @sha, "head" => %{"sha" => @head}}, &1))}

    defp runs(list),
      do:
        {"repos/#{@repo}/actions/workflows/ci.yml/runs?event=pull_request&head_sha=#{@head}&per_page=100",
         %{"workflow_runs" => list}}

    defp a_run(over \\ %{}),
      do:
        Map.merge(
          %{
            "id" => 500,
            "html_url" => "https://example.com/runs/500",
            "status" => "completed",
            "conclusion" => "success",
            "created_at" => "2026-11-06T04:50:00Z",
            "display_title" => "CI: a change (#1857) · tested #{@tested}"
          },
          over
        )

    defp jobs(id \\ 500, conclusions \\ ["success", "success"]),
      do:
        {"repos/#{@repo}/actions/runs/#{id}/jobs?per_page=100",
         %{"jobs" => Enum.with_index(conclusions, &%{"name" => "job #{&2}", "conclusion" => &1})}}

    defp tree(sha, tree), do: {"repos/#{@repo}/git/commits/#{sha}", %{"tree" => %{"sha" => tree}}}

    defp green, do: [pulls(), runs([a_run()]), jobs(), tree(@tested, @tree), tree(@sha, @tree)]

    defp answers(over), do: Map.merge(Map.new(green()), Map.new(over))

    defp ran!(out, why) do
      assert out["run"] == "true"
      assert out["note"] =~ "suite: ran ("
      assert out["note"] =~ why
      assert out["summary"] =~ "**Ran.**"
    end

    @tag :tmp_dir
    test "skips the suite when the PR's last run passed on the same tree", %{tmp_dir: dir} do
      out = gate(dir, green())
      assert out["run"] == "false"
      assert out["note"] == "suite: passed on PR #92 at ccccccc, same tree"
      assert out["summary"] =~ "**Skipped.** Passed on PR #92"
      assert out["summary"] =~ "[500](https://example.com/runs/500)"
      assert out["summary"] =~ @tested
      assert out["summary"] =~ @tree
    end

    @tag :tmp_dir
    test "runs it when main moved and the tree differs", %{tmp_dir: dir} do
      out = gate(dir, answers([tree(@sha, String.duplicate("e", 40))]))
      ran!(out, "main moved after PR #92's CI run 500")
    end

    @tag :tmp_dir
    test "runs it when the last run is red, or still going", %{tmp_dir: dir} do
      ran!(gate(dir, answers([runs([a_run(%{"conclusion" => "failure"})])])), "ended failure")

      ran!(
        gate(dir, answers([runs([a_run(%{"status" => "in_progress", "conclusion" => nil})])])),
        "is in_progress, not finished"
      )
    end

    @tag :tmp_dir
    test "judges the latest run, not an older green one", %{tmp_dir: dir} do
      older = a_run(%{"id" => 400, "created_at" => "2026-11-06T04:00:00Z"})
      newer = a_run(%{"id" => 600, "conclusion" => "cancelled"})
      ran!(gate(dir, answers([runs([newer, older])])), "run 600 ended cancelled")
    end

    @tag :tmp_dir
    test "runs it when a job didn't pass, though the run did", %{tmp_dir: dir} do
      ran!(gate(dir, answers([jobs(500, ["success", "skipped"])])), "not every job")
      ran!(gate(dir, answers([jobs(500, [])])), "has no jobs")
    end

    @tag :tmp_dir
    test "runs it when there is no run, or one that doesn't say what it tested", %{tmp_dir: dir} do
      ran!(gate(dir, answers([runs([])])), "PR #92 has no CI run on its last commit")

      ran!(
        gate(dir, answers([runs([a_run(%{"display_title" => "CI: a change (#1857)"})])])),
        "doesn't say which commit it tested"
      )
    end

    @tag :tmp_dir
    test "runs it for a commit no PR's merge made", %{tmp_dir: dir} do
      ran!(gate(dir, answers([pulls([])])), "no pull request's merge made aaaaaaa")

      ran!(
        gate(dir, answers([pulls([%{"number" => 92, "merged_at" => nil}])])),
        "no pull request"
      )

      ran!(
        gate(
          dir,
          answers([pulls([%{"number" => 7, "merge_commit_sha" => @tested, "merged_at" => "x"}])])
        ),
        "no pull request"
      )
    end

    @tag :tmp_dir
    test "runs it whenever the API fails, at any step", %{tmp_dir: dir} do
      [pulls_path, runs_path, jobs_path, tested_path, _] = Enum.map(green(), &elem(&1, 0))

      for {path, why} <- [
            {pulls_path, "didn't say which pull request made"},
            {runs_path, "didn't list PR #92's CI runs"},
            {jobs_path, "didn't list the jobs"},
            {tested_path, "didn't give the tree of"}
          ] do
        dir = Path.join(dir, Integer.to_string(:erlang.phash2(path)))
        ran!(gate(dir, Map.delete(answers([]), path)), why)
      end

      bad = Path.join(dir, "garbled")
      ran!(gate(bad, answers([{pulls_path, "not json"}])), "didn't parse")
    end

    @tag :tmp_dir
    test "runs it for a tag, a dispatch, or a push elsewhere, without asking the API", %{
      tmp_dir: dir
    } do
      ran!(gate(dir, green(), [{"REF", "refs/tags/v1.2.3"}]), "a push to refs/tags/v1.2.3")
      ran!(gate(dir, green(), [{"EVENT_NAME", "workflow_dispatch"}]), "a workflow_dispatch run")
      ran!(gate(dir, [], [{"EVENT_NAME", "workflow_dispatch"}]), "always tests")
    end
  end

  # After a skipped suite, release.yml's warm-cache job saves the build under
  # main's key in partition 1's place (#1913). It must save what the suite
  # would have, under the key a PR looks for, and never hold up a deploy.
  describe "warming main's build cache when the suite is skipped" do
    defp workflow(file) do
      {:ok, yaml} = YamlElixir.read_from_file(Path.join(@root, ".github/workflows/#{file}"))
      yaml
    end

    defp warm, do: workflow("release.yml")["jobs"]["warm-cache"]
    defp suite_job, do: workflow("ci.yml")["jobs"]["test"]

    defp step(job, key, value), do: Enum.find(job["steps"], &(&1[key] == value))

    defp step_at(job, key, value),
      do: Enum.find_index(job["steps"], &(&1[key] == value))

    test "runs only when the gate said the suite is skipped, after the gate" do
      assert warm()["needs"] == "suite"
      assert warm()["if"] == "${{ needs.suite.outputs.run == 'false' }}"
    end

    test "is off the merge and deploy path: no job needs it" do
      for {name, job} <- workflow("release.yml")["jobs"], name != "warm-cache" do
        refute "warm-cache" in List.wrap(job["needs"]), "#{name} needs warm-cache"
      end
    end

    test "compiles in the test environment, with the suite's toolchain" do
      assert warm()["env"]["MIX_ENV"] == "test"
      assert workflow("ci.yml")["env"]["MIX_ENV"] == "test"

      assert step(warm(), "uses", "erlef/setup-beam@v1")["with"] ==
               step(suite_job(), "uses", "erlef/setup-beam@v1")["with"]
    end

    test "uses the suite's cache keys, paths and restore order exactly" do
      assert step(warm(), "id", "keys")["run"] == step(suite_job(), "id", "keys")["run"]

      assert step(warm(), "uses", "actions/cache/restore@v4")["with"] ==
               step(suite_job(), "uses", "actions/cache/restore@v4")["with"]

      assert step(warm(), "uses", "actions/cache/save@v4")["with"] ==
               step(suite_job(), "uses", "actions/cache/save@v4")["with"]
    end

    test "backdates and compiles as the suite does, before saving" do
      name = "Backdate mix.exs and config to the cached build"
      assert step(warm(), "name", name)["run"] == step(suite_job(), "name", name)["run"]

      assert step(warm(), "name", name)["if"] =~
               step(suite_job(), "name", name)["if"]

      compile = "Compile without warnings"
      assert step(warm(), "name", compile)["run"] == step(suite_job(), "name", compile)["run"]

      assert step_at(warm(), "name", name) < step_at(warm(), "run", "mix deps.get")
      assert step_at(warm(), "run", "mix deps.get") < step_at(warm(), "name", compile)

      assert step_at(warm(), "name", compile) <
               step_at(warm(), "uses", "actions/cache/save@v4")
    end

    test "does nothing past the restore on an exact hit, so it never saves a key twice" do
      after_restore =
        warm()["steps"]
        |> Enum.drop(step_at(warm(), "uses", "actions/cache/restore@v4") + 1)

      assert after_restore != []

      for s <- after_restore do
        assert s["if"] =~ "steps.mix-cache.outputs.cache-hit != 'true'",
               "#{s["name"] || s["run"] || s["uses"]} runs on an exact hit"
      end
    end

    test "needs no database or secrets: it only compiles" do
      refute Map.has_key?(warm(), "services")
      refute Map.has_key?(warm(), "environment")
      assert warm()["permissions"] == %{"contents" => "read"}
    end
  end

  # The CLI the image serves is signed on a v* tag (#2669, W-2542): built
  # with no secrets, signed only in the protected environment, in the CLI's
  # own namespace, and the image built from those bytes.
  describe "the signed CLI" do
    defp release_jobs do
      {:ok, yaml} = YamlElixir.read_from_file(Path.join(@root, ".github/workflows/release.yml"))
      yaml["jobs"]
    end

    defp step_runs(job), do: Enum.map_join(job["steps"], "\n", &(&1["run"] || ""))

    test "is built on a v* tag only, with no secrets and no environment" do
      build = release_jobs()["cli-build"]

      assert build["if"] ==
               "${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}"

      assert build["permissions"] == %{"contents" => "read"}
      refute Map.has_key?(build, "environment")
      refute inspect(build) =~ "secrets."
      assert step_runs(build) =~ "mix escript.build"
    end

    test "is signed only in daemon-release, in the CLI's namespace, and checked against the committed key" do
      sign = release_jobs()["cli-sign"]
      assert sign["needs"] == "cli-build"
      assert sign["environment"] == "daemon-release"
      assert sign["permissions"] == %{"contents" => "read"}
      runs = step_runs(sign)

      assert runs =~
               "ssh-keygen -Y sign -q -f \"$key_file\" -n slipdock-cli dist/slipdock.escript"

      assert runs =~ ~s(namespaces="slipdock-cli,)
      assert runs =~ "-n slipdock-cli \\\n  -s dist/slipdock.escript.sig < dist/slipdock.escript"
      assert runs =~ "daemon/internal/release/release_key.pub"

      # The daemon checks in the same namespace.
      assert File.read!(Path.join(@root, "daemon/internal/release/sshsig.go")) =~
               ~s(const CLINamespace = "slipdock-cli")
    end

    test "the image waits for it on a tag, is never built without it there, and serves its bytes" do
      build = release_jobs()["build"]
      assert build["needs"] == "cli-sign"

      assert build["if"] ==
               "${{ !cancelled() && (needs.cli-sign.result == 'success' || (github.ref_type != 'tag' && needs.cli-sign.result == 'skipped')) }}"

      [download] = Enum.filter(build["steps"], &(&1["uses"] == "actions/download-artifact@v4"))
      assert download["if"] == "${{ needs.cli-sign.result == 'success' }}"
      assert download["with"] == %{"name" => "cli-signed", "path" => "priv/cli/signed"}

      dockerfile = File.read!(Path.join(@root, "Dockerfile"))
      assert dockerfile =~ "if [ -f priv/cli/signed/slipdock.escript.sig ]; then"

      assert dockerfile =~
               "mv priv/cli/signed/slipdock.escript priv/cli/signed/slipdock.escript.sig priv/cli/"
    end

    # The skills archive goes the same way (#2784): packed beside the CLI,
    # signed in its own namespace, checked, and served as those bytes.
    test "the skills archive is packed, signed in its own namespace, checked and served" do
      build = release_jobs()["cli-build"]

      assert step_runs(build) =~
               "-cf - slipdock* | gzip -n > ../../cli-dist/slipdock-skills.tar.gz"

      [upload] = Enum.filter(build["steps"], &(&1["uses"] == "actions/upload-artifact@v4"))
      assert upload["with"]["path"] =~ "cli-dist/slipdock-skills.tar.gz"

      sign = release_jobs()["cli-sign"]
      runs = step_runs(sign)

      assert runs =~
               "ssh-keygen -Y sign -q -f \"$key_file\" -n slipdock-skills dist/slipdock-skills.tar.gz"

      assert runs =~ ~s(namespaces="slipdock-cli,slipdock-skills")

      assert runs =~
               "-n slipdock-skills \\\n  -s dist/slipdock-skills.tar.gz.sig < dist/slipdock-skills.tar.gz"

      [signed] = Enum.filter(sign["steps"], &(&1["uses"] == "actions/upload-artifact@v4"))
      assert signed["with"]["path"] =~ "dist/slipdock-skills.tar.gz.sig"

      assert File.read!(Path.join(@root, "daemon/internal/release/sshsig.go")) =~
               ~s(const SkillsNamespace = "slipdock-skills")

      dockerfile = File.read!(Path.join(@root, "Dockerfile"))
      assert dockerfile =~ "if [ -f priv/cli/signed/slipdock-skills.tar.gz.sig ]; then"

      assert dockerfile =~
               "mv priv/cli/signed/slipdock-skills.tar.gz priv/cli/signed/slipdock-skills.tar.gz.sig priv/skills_signed/"

      # Moved out before the CLI's step removes priv/cli/signed.
      {skills_at, _} = :binary.match(dockerfile, "priv/skills_signed/")
      {rm_at, _} = :binary.match(dockerfile, "rm -rf /app/priv/cli/signed")
      assert skills_at < rm_at
    end
  end

  # The threshold in mix.exs is a gate only while CI checks it (#2786): each
  # partition exports its share, and the coverage job merges them and fails
  # below it.
  describe "coverage across the partitions" do
    defp coverage_job, do: workflow("ci.yml")["jobs"]["coverage"]

    test "mix.exs sets a threshold for the project's own coverage tool" do
      config = Mix.Project.config()[:test_coverage]
      assert config[:tool] == Slipdock.Coverage
      assert is_number(config[:summary][:threshold])
      assert config[:summary][:threshold] > 0
    end

    test "CONTRIBUTING.md gives the threshold mix.exs sets" do
      threshold = Mix.Project.config()[:test_coverage][:summary][:threshold]

      assert File.read!(Path.join(@root, "CONTRIBUTING.md")) =~
               "fails under the threshold in `mix.exs` (#{threshold}%)"
    end

    test "each partition runs the suite with coverage, exported under its own name" do
      test_step = step(suite_job(), "name", "Test")

      assert test_step["run"] =~
               ~S|mix test --cover --export-coverage "partition-$MIX_TEST_PARTITION" $files|

      upload =
        Enum.find(
          suite_job()["steps"],
          &(&1["with"]["name"] == "coverage-${{ matrix.partition }}")
        )

      assert upload["uses"] =~ "actions/upload-artifact@"
      assert upload["with"]["path"] == "cover/partition-${{ matrix.partition }}.coverdata"
      assert upload["with"]["if-no-files-found"] == "error"
    end

    test "the coverage job merges every partition's export and checks the threshold" do
      job = coverage_job()
      assert job["needs"] == "test"
      refute Map.has_key?(job, "if")
      refute Map.has_key?(job, "continue-on-error")

      download =
        Enum.find(
          job["steps"],
          &String.starts_with?(&1["uses"] || "", "actions/download-artifact@")
        )

      assert download["with"] == %{
               "pattern" => "coverage-*",
               "path" => "cover",
               "merge-multiple" => true
             }

      refute Map.has_key?(download, "if")
      refute Map.has_key?(download, "continue-on-error")

      # The command and nothing after it (`|| true`), on a step that always
      # runs and whose failure fails the job. An integer first: a step that
      # isn't there is `nil`, and `nil > 3` is true.
      merge_at = step_at(job, "run", "mix slipdock.coverage")
      assert is_integer(merge_at), "no step runs exactly `mix slipdock.coverage`"
      assert merge_at > Enum.find_index(job["steps"], &(&1 == download))

      merge = Enum.at(job["steps"], merge_at)
      refute Map.has_key?(merge, "if")
      refute Map.has_key?(merge, "continue-on-error")
      refute Map.has_key?(merge, "shell")
    end

    test "the coverage job restores the build the test job cached, under the same keys" do
      for name <- ["Cache keys", "Backdate mix.exs and config to the cached build"] do
        assert step(coverage_job(), "name", name) == step(suite_job(), "name", name), name
      end

      restore = &Enum.find(&1["steps"], fn s -> s["id"] == "mix-cache" end)
      assert restore.(coverage_job()) == restore.(suite_job())
    end

    test "the release's suite runs it too, as part of ci.yml" do
      assert workflow("release.yml")["jobs"]["test"]["uses"] == "./.github/workflows/ci.yml"
    end
  end
end
