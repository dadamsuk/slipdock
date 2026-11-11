defmodule Slipdock.PrePushAliasTest do
  @moduledoc """
  `mix pre_push` (in mix.exs): CI's static checks and its build, run before a
  push. `ci_workflow_test.exs` keeps the steps in step with ci.yml; this checks
  the steps themselves and that the first failure stops the run.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @root Path.expand("../..", __DIR__)
  @credo_config Path.join(@root, ".credo.exs")

  defp project, do: Mix.Project.get!()

  # A runner that records each step and answers with the given exit status.
  defp recorder(statuses \\ %{}) do
    me = self()

    fn task, argv, _opts ->
      send(me, {:ran, task, argv})
      Map.get(statuses, task, 0)
    end
  end

  defp ran, do: ran([])

  defp ran(acc) do
    receive do
      {:ran, task, _argv} -> ran([task | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "is an alias, and runs in the test environment as CI does" do
    assert is_function(Mix.Project.config()[:aliases][:pre_push], 1)
    assert project().cli()[:preferred_envs][:pre_push] == :test
  end

  test "runs CI's checks in CI's order, with CI's arguments" do
    assert project().pre_push_steps() == [
             {"compile", ["--force", "--warnings-as-errors"]},
             {"format", ["--check-formatted"]},
             {"format", ["--check-formatted"], cd: "cli"},
             {"compile", ["--warnings-as-errors"], cd: "cli"},
             {"go", ["vet", "./..."], cd: "daemon", exec: true},
             {"go", ["test", "-race", "./..."], cd: "daemon", exec: true},
             {"ecto.drop", ["--quiet"]},
             {"test", project().repo_checks()},
             {"hex.audit", []},
             {"deps.audit", []},
             {"sobelow", ["--config"]},
             {"credo",
              [
                "diff",
                "--from-git-merge-base",
                "origin/main",
                "--config-file",
                @credo_config
              ]}
           ]
  end

  test "credo's config is an absolute path, so the current .credo.exs judges both sides" do
    {"credo", argv} = List.last(project().pre_push_steps())
    config = argv |> Enum.drop_while(&(&1 != "--config-file")) |> Enum.at(1)
    assert Path.type(config) == :absolute
    assert File.regular?(config)
  end

  test "arguments replace credo's base, to check a commit against a ref" do
    assert {"credo", ["diff", "--from-git-ref", "777104a1~1", "--config-file", @credo_config]} =
             List.last(project().pre_push_steps(["--from-git-ref", "777104a1~1"]))

    # The other steps don't take them.
    assert project().pre_push_steps(["--from-git-ref", "x"]) |> Enum.drop(-1) ==
             project().pre_push_steps() |> Enum.drop(-1)
  end

  test "builds in a root of its own, so it can run beside mix test" do
    root = project().pre_push_build_root()
    assert Path.dirname(root) == Path.join(@root, "_build")
    refute String.starts_with?(Mix.Project.build_path(), root)
  end

  test "runs every step in turn and says how long it took" do
    out = capture_io(fn -> project().pre_push([], recorder()) end)

    assert ran() == [
             "compile",
             "format",
             "format",
             "compile",
             "go",
             "go",
             "ecto.drop",
             "test",
             "hex.audit",
             "deps.audit",
             "sobelow",
             "credo"
           ]

    assert out =~ "==> pre_push: mix compile --force --warnings-as-errors"
    n = length(project().repo_checks())
    assert out =~ "==> pre_push: mix test (the #{n} files in test/repo_checks.txt)\n"
    assert out =~ "==> pre_push: mix sobelow --config"
    assert out =~ ~r/all checks passed in \d+\.\d s/
  end

  test "stops at the first step that fails, with its exit status" do
    capture_io(fn ->
      error =
        assert_raise Mix.Error, fn ->
          project().pre_push([], recorder(%{"hex.audit" => 3}))
        end

      assert error.mix == 3
      assert error.message == "pre_push: mix hex.audit failed (exit 3)"
    end)

    assert ran() == [
             "compile",
             "format",
             "format",
             "compile",
             "go",
             "go",
             "ecto.drop",
             "test",
             "hex.audit"
           ]
  end

  test "a failing repo check stops the run before the audits (#1867)" do
    capture_io(fn ->
      assert_raise Mix.Error,
                   ~r/^pre_push: mix test \(the \d+ files in .*\) failed \(exit 2\)$/,
                   fn ->
                     project().pre_push([], recorder(%{"test" => 2}))
                   end
    end)

    assert ran() == ["compile", "format", "format", "compile", "go", "go", "ecto.drop", "test"]
  end

  test "runs the repo checks after the compiles and format, before the slower audits (#1867)" do
    tasks = Enum.map(project().pre_push_steps(), &elem(&1, 0))

    assert Enum.take(tasks, 8) == [
             "compile",
             "format",
             "format",
             "compile",
             "go",
             "go",
             "ecto.drop",
             "test"
           ]

    {"test", files} = Enum.at(project().pre_push_steps(), 7)
    assert "test/slipdock/nothing_personal_test.exs" in files
    assert Enum.all?(files, &File.regular?(Path.join(@root, &1)))
  end

  test "every step runs with the repo checks' own test database (#1867)" do
    # Its own, so a `mix test` beside it doesn't hold it up; every step's, so
    # the test step doesn't recompile what reads the partition from config.
    env = project().pre_push_env([], nil)
    assert {"MIX_TEST_PARTITION", project().pre_push_partition()} in env
    assert {"MIX_BUILD_ROOT", project().pre_push_build_root()} in env
    assert {"MIX_ENV", "test"} in env
    refute List.keymember?(env, "TEST_DATABASE_URL", 0)
  end

  describe "a test database per checkout (#2115)" do
    test "the partition is derived from the checkout's path" do
      partition = project().pre_push_partition()
      assert partition =~ ~r/^_pre_push_[0-9a-f]{8}$/
      assert partition == project().pre_push_partition(@root)
      # The same checkout always gets the same one, however its path is written.
      assert partition == project().pre_push_partition(Path.join(@root, "test/.."))
    end

    test "two worktrees get two databases" do
      a = project().pre_push_partition("/work/slipdock-lanes/card-1")
      b = project().pre_push_partition("/work/slipdock-lanes/card-2")
      assert a != b
      assert a == project().pre_push_partition("/work/slipdock-lanes/card-1")
      refute a == "_pre_push"
    end

    test "every step but the CLI's gets this checkout's partition" do
      assert {"MIX_TEST_PARTITION", project().pre_push_partition()} in project().pre_push_env()
      assert {"MIX_TEST_PARTITION", nil} in project().pre_push_env([cd: "cli"], nil)
    end

    test "drops this checkout's database just before the repo checks, so no stale schema carries over" do
      steps = project().pre_push_steps()
      i = Enum.find_index(steps, &(&1 == {"ecto.drop", ["--quiet"]}))
      assert {"test", _} = Enum.at(steps, i + 1)

      # The test alias creates and migrates it again before the tests run.
      assert ["ecto.create --quiet", "ecto.migrate --quiet", "test"] =
               Mix.Project.config()[:aliases][:test]
    end

    test "a failed drop stops the run before the repo checks" do
      capture_io(fn ->
        assert_raise Mix.Error, "pre_push: mix ecto.drop --quiet failed (exit 1)", fn ->
          project().pre_push([], recorder(%{"ecto.drop" => 1}))
        end
      end)

      assert ran() == ["compile", "format", "format", "compile", "go", "go", "ecto.drop"]
    end

    test "TEST_DATABASE_URL, which overrides the partition, gets it on its database's name" do
      partition = project().pre_push_partition()

      env =
        project().pre_push_env([], "postgres://postgres:postgres@localhost:5433/slipdock_test")

      assert {"TEST_DATABASE_URL",
              "postgres://postgres:postgres@localhost:5433/slipdock_test#{partition}"} in env

      assert {"MIX_TEST_PARTITION", partition} in env
    end

    test "an empty TEST_DATABASE_URL is left alone, as config/test.exs would ignore it" do
      refute List.keymember?(project().pre_push_env([], ""), "TEST_DATABASE_URL", 0)
    end

    test "the CLI's compile doesn't take TEST_DATABASE_URL" do
      env = project().pre_push_env([cd: "cli"], "postgres://localhost/slipdock_test")
      refute List.keymember?(env, "TEST_DATABASE_URL", 0)
    end

    test "pre_push_database_url/2 keeps the rest of the URL, and doesn't add the partition twice" do
      url = &project().pre_push_database_url(&1, "_pre_push_ab12cd34")

      assert url.("postgres://localhost/slipdock_test") ==
               "postgres://localhost/slipdock_test_pre_push_ab12cd34"

      assert url.("ecto://postgres:postgres@localhost:5434/other_db?ssl=true") ==
               "ecto://postgres:postgres@localhost:5434/other_db_pre_push_ab12cd34?ssl=true"

      assert url.("postgres://localhost/slipdock_test_pre_push_ab12cd34") ==
               "postgres://localhost/slipdock_test_pre_push_ab12cd34"

      # No database named: the default one's name, as config/test.exs uses.
      assert url.("postgres://localhost") ==
               "postgres://localhost/slipdock_test_pre_push_ab12cd34"

      assert url.("postgres://localhost/") ==
               "postgres://localhost/slipdock_test_pre_push_ab12cd34"
    end
  end

  test "a credo finding (exit 8) fails the run, after every other check" do
    out =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/mix credo diff .* failed \(exit 8\)/, fn ->
          project().pre_push([], recorder(%{"credo" => 8}))
        end
      end)

    assert length(ran()) == 12
    refute out =~ "all checks passed"
  end

  describe "the daemon's vet and tests (#2573)" do
    test "run go vet and go test in daemon/, as CI's daemon job does, after the CLI's compile" do
      steps = project().pre_push_steps()
      assert Enum.at(steps, 4) == {"go", ["vet", "./..."], cd: "daemon", exec: true}
      assert Enum.at(steps, 5) == {"go", ["test", "-race", "./..."], cd: "daemon", exec: true}
      assert File.regular?(Path.join([@root, "daemon", "go.mod"]))
    end

    test "say they run go, not mix, and where" do
      out = capture_io(fn -> project().pre_push([], recorder()) end)
      assert out =~ "==> pre_push: go vet ./... (in daemon/)\n"
      assert out =~ "==> pre_push: go test -race ./... (in daemon/)\n"
      refute out =~ "mix go"
    end

    test "a failing daemon test stops the run before the repo checks" do
      capture_io(fn ->
        error =
          assert_raise Mix.Error, fn ->
            project().pre_push([], fn
              "go", ["test" | _], _opts -> 1
              task, argv, _opts -> recorder().(task, argv, [])
            end)
          end

        assert error.message == "pre_push: go test -race ./... (in daemon/) failed (exit 1)"
      end)

      assert ran() == ["compile", "format", "format", "compile", "go"]
    end

    test "take none of Mix's environment" do
      assert project().pre_push_env([cd: "daemon", exec: true], "postgres://h/db") == []
    end

    test "fail, and say so, when the program isn't installed" do
      {status, out} =
        with_io(:stderr, fn ->
          project().pre_push_run("no-such-program-2573", ["vet"], cd: "daemon", exec: true)
        end)

      assert status == 127
      assert out =~ "no-such-program-2573 is not on the PATH"
    end

    @tag :tmp_dir
    test "really run the program in its directory, and pass on its exit status", %{tmp_dir: dir} do
      sh = System.find_executable("sh") || flunk("no sh")
      File.write!(Path.join(dir, "marker"), "")

      {status, out} =
        with_io(fn -> project().pre_push_run(sh, ["-c", "ls; exit 3"], cd: dir, exec: true) end)

      assert status == 3
      assert out =~ "marker"
    end
  end

  describe "a failing step's output under a locale that isn't UTF-8 (#2757)" do
    # A fresh `elixir` under LANG=C loads mix.exs and runs pre_push/2 with a
    # step that prints non-ASCII text, and a character cut short, then fails.
    # The rescue is what Mix's CLI does with a Mix.Error.
    @child """
    Mix.start()
    Code.put_compiler_option(:no_warn_undefined, :all)
    [mix_exs, sh, dir, script, how] = System.argv()
    {mod, _} = mix_exs |> Code.require_file() |> hd()

    # "exec" runs the script as a program (pre_push_exec); "mix" runs the
    # `mix` first on the PATH (pre_push_mix), a stub that runs the script.
    run =
      case how do
        "exec" -> fn _, _, _ -> mod.pre_push_run(sh, ["-c", script], cd: dir, exec: true) end
        "mix" -> fn _, _, _ -> mod.pre_push_run("test", [], cd: dir) end
      end

    try do
      mod.pre_push([], run)
    rescue
      e in Mix.Error ->
        Mix.shell().error("** (Mix) " <> Exception.message(e))
        System.halt(e.mix)
    end
    """

    @script ~S"printf 'caf\303\251 \342\206\222 done\nsplit \342\206\n'; exit 3"

    @tag :tmp_dir
    test "a program's: prints it as it came, and exits with the step's status", %{tmp_dir: dir} do
      {out, status} = run_child(dir, "exec", [])
      assert_printed_as_it_came(out, status)
    end

    # The reported case: a failing repo check is a `mix test`, which runs
    # through pre_push_mix/3. A stub `mix` first on the child's PATH stands in.
    @tag :tmp_dir
    test "a mix task's: prints it as it came, and exits with the step's status", %{tmp_dir: dir} do
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)
      stub = Path.join(bin, "mix")
      File.write!(stub, "#!/bin/sh\n" <> @script <> "\n")
      File.chmod!(stub, 0o755)

      {out, status} = run_child(dir, "mix", [{"PATH", bin <> ":" <> System.get_env("PATH")}])
      assert_printed_as_it_came(out, status)
    end

    defp run_child(dir, how, env) do
      elixir = System.find_executable("elixir") || flunk("no elixir")
      sh = System.find_executable("sh") || flunk("no sh")
      child = Path.join(dir, "child.exs")
      File.write!(child, @child)
      env = [{"LANG", "C"}, {"LC_ALL", "C"}, {"LC_CTYPE", "C"} | env]

      System.cmd(elixir, [child, Path.join(@root, "mix.exs"), sh, dir, @script, how],
        env: env,
        stderr_to_stdout: true
      )
    end

    defp assert_printed_as_it_came(out, status) do
      # Compared as bytes, and shown with inspect/1: the output isn't valid
      # UTF-8, which ExUnit's own report of a failure would crash on.
      assert status == 3, inspect(out)
      assert String.contains?(out, "café → done\n"), inspect(out)
      assert String.contains?(out, "split " <> <<0xE2, 0x86>> <> "\n"), inspect(out)

      assert String.contains?(
               out,
               "pre_push: mix compile --force --warnings-as-errors failed (exit 3)"
             ),
             inspect(out)

      refute String.contains?(out, "ArgumentError"), inspect(out)
    end
  end

  describe "the CLI's compile (#1964)" do
    test "compiles cli/ with warnings as errors, after the app's checks and the CLI's format" do
      assert Enum.at(project().pre_push_steps(), 3) ==
               {"compile", ["--warnings-as-errors"], cd: "cli"}

      assert File.regular?(Path.join([@root, "cli", "mix.exs"]))
    end

    test "is passed its directory, and says where it runs" do
      me = self()

      out =
        capture_io(fn ->
          project().pre_push([], fn task, argv, opts ->
            send(me, {:step, task, argv, opts})
            0
          end)
        end)

      assert_received {:step, "compile", ["--warnings-as-errors"], [cd: "cli"]}
      assert_received {:step, "compile", ["--force", "--warnings-as-errors"], []}
      assert out =~ "==> pre_push: mix compile --warnings-as-errors (in cli/)\n"
    end

    test "a CLI warning stops the run before the repo checks" do
      capture_io(fn ->
        error =
          assert_raise Mix.Error, fn ->
            project().pre_push([], fn
              "compile", _argv, [cd: "cli"] -> 1
              task, argv, _opts -> recorder().(task, argv, [])
            end)
          end

        assert error.mix == 1

        assert error.message ==
                 "pre_push: mix compile --warnings-as-errors (in cli/) failed (exit 1)"
      end)

      assert ran() == ["compile", "format", "format"]
    end

    test "builds as CI's cli job does, not in the app's test partition" do
      env = project().pre_push_env(cd: "cli")

      for name <- ~w(MIX_ENV MIX_BUILD_ROOT MIX_TEST_PARTITION),
          do: assert({name, nil} in env)
    end

    @tag :tmp_dir
    test "really fails on a warning in the CLI, and passes without one", %{tmp_dir: dir} do
      # A copy of cli/ without its build, so the real step runs on it.
      cli = Path.join(@root, "cli")

      for entry <- File.ls!(cli),
          entry not in ["_build", "deps"],
          do: File.cp_r!(Path.join(cli, entry), Path.join(dir, entry))

      {"compile", argv, _opts} = Enum.at(project().pre_push_steps(), 3)

      {0, out} = with_io(fn -> project().pre_push_run("compile", argv, cd: dir) end)
      refute out =~ "warning:"

      File.write!(Path.join([dir, "lib", "pre_push_warning.ex"]), """
      defmodule PrePushWarning do
        def unused(x), do: :ok
      end
      """)

      {status, out} = with_io(fn -> project().pre_push_run("compile", argv, cd: dir) end)
      assert status != 0
      assert out =~ "variable \"x\" is unused"

      # Unforced, as CI's: a second run rebuilds nothing and still fails.
      {status, out} = with_io(fn -> project().pre_push_run("compile", argv, cd: dir) end)
      assert status != 0
      assert out =~ "variable \"x\" is unused"
    end
  end

  describe "the CLI's format check (#2602)" do
    test "checks cli/'s formatting after the app's format, before the CLI's compile" do
      steps = project().pre_push_steps()

      assert Enum.slice(steps, 1..3) == [
               {"format", ["--check-formatted"]},
               {"format", ["--check-formatted"], cd: "cli"},
               {"compile", ["--warnings-as-errors"], cd: "cli"}
             ]

      assert File.regular?(Path.join([@root, "cli", ".formatter.exs"]))
    end

    test "is passed its directory, and says where it runs" do
      me = self()

      out =
        capture_io(fn ->
          project().pre_push([], fn task, argv, opts ->
            send(me, {:step, task, argv, opts})
            0
          end)
        end)

      assert_received {:step, "format", ["--check-formatted"], [cd: "cli"]}
      assert_received {:step, "format", ["--check-formatted"], []}
      assert out =~ "==> pre_push: mix format --check-formatted (in cli/)\n"
    end

    test "an unformatted CLI file stops the run before the CLI's compile" do
      capture_io(fn ->
        error =
          assert_raise Mix.Error, fn ->
            project().pre_push([], fn
              "format", _argv, [cd: "cli"] -> 1
              task, argv, _opts -> recorder().(task, argv, [])
            end)
          end

        assert error.mix == 1

        assert error.message ==
                 "pre_push: mix format --check-formatted (in cli/) failed (exit 1)"
      end)

      assert ran() == ["compile", "format"]
    end

    @tag :tmp_dir
    test "really fails on an unformatted CLI file, and passes without one", %{tmp_dir: dir} do
      # A copy of cli/ without its build, so the real step runs on it.
      cli = Path.join(@root, "cli")

      for entry <- File.ls!(cli),
          entry not in ["_build", "deps"],
          do: File.cp_r!(Path.join(cli, entry), Path.join(dir, entry))

      {"format", argv, _opts} = Enum.at(project().pre_push_steps(), 2)

      {0, _out} = with_io(fn -> project().pre_push_run("format", argv, cd: dir) end)

      File.write!(Path.join([dir, "lib", "pre_push_unformatted.ex"]), """
      defmodule PrePushUnformatted do
        def   spaced( x ),do:   x
      end
      """)

      {status, out} = with_io(fn -> project().pre_push_run("format", argv, cd: dir) end)
      assert status != 0
      assert out =~ "pre_push_unformatted.ex"
    end
  end

  describe "--prune (#2604)" do
    # A SQL runner that answers the listing with `databases` and records each
    # drop, failing those in `failing`.
    defp fake_sql(databases, failing \\ []) do
      me = self()

      fn
        "SELECT datname FROM pg_database ORDER BY datname" ->
          {:ok, Enum.map(databases, &[&1])}

        ~s(DROP DATABASE ") <> rest ->
          name = String.trim_trailing(rest, ~s("))
          send(me, {:dropped, name})
          if name in failing, do: {:error, "is being accessed by other users"}, else: {:ok, []}
      end
    end

    defp dropped(acc \\ []) do
      receive do
        {:dropped, name} -> dropped([name | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp db(root), do: "slipdock_test" <> project().pre_push_partition(root)

    test "runs no checks: mix pre_push --prune only prunes" do
      me = self()
      project().pre_push(["--prune"], recorder(), fn -> send(me, :pruned) end)

      assert_received :pruned
      assert ran() == []
    end

    test "picks the pre_push databases of checkouts that are gone, and nothing else" do
      live = "/work/live"
      gone = "/work/gone"

      databases = [
        "postgres",
        "slipdock_dev",
        "slipdock_test",
        "slipdock_test_ci",
        db(live),
        db(gone),
        # Near misses: another base, a short or upper-case hash, a suffix.
        "other_test" <> project().pre_push_partition(gone),
        "slipdock_test_pre_push_abc",
        "slipdock_test_pre_push_ABCDEF12",
        db(gone) <> "x"
      ]

      assert project().pre_push_stale_databases(databases, [live]) == [db(gone)]
      assert project().pre_push_stale_databases(databases, [live, gone]) == []

      assert project().pre_push_stale_databases(databases, [], "other_test") ==
               ["other_test" <> project().pre_push_partition(gone)]
    end

    test "drops the stale ones, says which, and keeps the live ones" do
      sql = fake_sql(["slipdock_test", db("/work/live"), db("/work/gone"), db("/work/old")])

      out =
        capture_io(fn ->
          assert project().pre_push_prune(sql, ["/work/live"]) ==
                   [db("/work/gone"), db("/work/old")]
        end)

      assert dropped() == [db("/work/gone"), db("/work/old")]
      assert out =~ "dropped #{db("/work/gone")}"
      assert out =~ "dropped #{db("/work/old")}"
    end

    test "says so when there is nothing to drop" do
      out =
        capture_io(fn ->
          assert project().pre_push_prune(fake_sql([db("/work/live")]), ["/work/live"]) == []
        end)

      assert out =~ "no databases of removed checkouts"
      assert dropped() == []
    end

    test "carries on past a database it can't drop, then fails naming it" do
      sql = fake_sql([db("/work/a"), db("/work/b")], [db("/work/a")])

      err =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            error = assert_raise Mix.Error, fn -> project().pre_push_prune(sql, []) end
            assert error.message == "pre_push --prune: couldn't drop #{db("/work/a")}"
            assert error.mix == 1
          end)
        end)

      assert dropped() == [db("/work/a"), db("/work/b")]
      assert err =~ "#{db("/work/a")} not dropped: is being accessed by other users"
    end

    test "fails when it can't list the databases, and drops nothing" do
      sql = fn _ -> {:error, "connection refused"} end

      assert_raise Mix.Error,
                   "pre_push --prune: can't list the databases: connection refused",
                   fn ->
                     project().pre_push_prune(sql, [])
                   end
    end

    @tag :tmp_dir
    test "keeps the worktrees whose directory still exists", %{tmp_dir: dir} do
      porcelain = """
      worktree #{dir}
      HEAD 84baaaed
      branch refs/heads/main

      worktree #{dir}/removed
      HEAD 891d1f47
      branch refs/heads/card-1
      prunable gitdir file points to non-existent location

      """

      assert project().pre_push_worktrees(porcelain) == [dir]
      assert project().pre_push_worktrees("") == []
    end

    test "keeps this checkout and its live worktrees" do
      checkouts = project().pre_push_checkouts()
      assert hd(checkouts) == @root
      assert Enum.all?(checkouts, &File.dir?/1)
      assert checkouts == Enum.uniq(checkouts)
    end

    test "names its databases as TEST_DATABASE_URL does, else slipdock_test" do
      assert project().pre_push_database_base(nil) == "slipdock_test"
      assert project().pre_push_database_base("") == "slipdock_test"
      assert project().pre_push_database_base("postgres://u:p@h:5432") == "slipdock_test"
      assert project().pre_push_database_base("postgres://u:p@h:5432/") == "slipdock_test"
      assert project().pre_push_database_base("postgres://u:p@h:5432/ci_test") == "ci_test"
    end

    @tag :tmp_dir
    test "really drops a removed checkout's database on the server", %{tmp_dir: dir} do
      url = Application.fetch_env!(:slipdock, Slipdock.Repo)[:url]
      sql = &project().pre_push_sql(url, &1)
      gone = Path.join(dir, "removed")
      mine = [db(dir), db(gone)]

      on_exit(fn ->
        for name <- mine, do: project().pre_push_sql(url, ~s(DROP DATABASE IF EXISTS "#{name}"))
      end)

      for name <- mine, do: assert({:ok, _} = sql.(~s(CREATE DATABASE "#{name}")))

      # Only this test's own databases: the server's others are left alone.
      only_mine = fn
        "SELECT" <> _ = statement ->
          {:ok, rows} = sql.(statement)
          {:ok, Enum.filter(rows, &(hd(&1) in mine))}

        statement ->
          sql.(statement)
      end

      capture_io(fn -> assert project().pre_push_prune(only_mine, [dir]) == [db(gone)] end)

      {:ok, rows} = sql.("SELECT datname FROM pg_database")
      names = List.flatten(rows)
      assert db(dir) in names
      refute db(gone) in names

      assert {:error, message} = sql.(~s(DROP DATABASE "#{db(gone)}"))
      assert message =~ "does not exist"
    end
  end
end
