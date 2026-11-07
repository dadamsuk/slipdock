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
             {"compile", ["--warnings-as-errors"], cd: "cli"},
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
             "compile",
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

    assert ran() == ["compile", "format", "compile", "test", "hex.audit"]
  end

  test "a failing repo check stops the run before the audits (#1867)" do
    capture_io(fn ->
      assert_raise Mix.Error,
                   ~r/^pre_push: mix test \(the \d+ files in .*\) failed \(exit 2\)$/,
                   fn ->
                     project().pre_push([], recorder(%{"test" => 2}))
                   end
    end)

    assert ran() == ["compile", "format", "compile", "test"]
  end

  test "runs the repo checks after the compiles and format, before the slower audits (#1867)" do
    tasks = Enum.map(project().pre_push_steps(), &elem(&1, 0))
    assert Enum.take(tasks, 4) == ["compile", "format", "compile", "test"]

    {"test", files} = Enum.at(project().pre_push_steps(), 3)
    assert "test/slipdock/nothing_personal_test.exs" in files
    assert Enum.all?(files, &File.regular?(Path.join(@root, &1)))
  end

  test "every step runs with the repo checks' own test database (#1867)" do
    # Its own, so a `mix test` beside it doesn't hold it up; every step's, so
    # the test step doesn't recompile what reads the partition from config.
    env = project().pre_push_env()
    assert {"MIX_TEST_PARTITION", "_pre_push"} in env
    assert {"MIX_BUILD_ROOT", project().pre_push_build_root()} in env
    assert {"MIX_ENV", "test"} in env
  end

  test "a credo finding (exit 8) fails the run, after every other check" do
    out =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/mix credo diff .* failed \(exit 8\)/, fn ->
          project().pre_push([], recorder(%{"credo" => 8}))
        end
      end)

    assert length(ran()) == 8
    refute out =~ "all checks passed"
  end

  describe "the CLI's compile (#1964)" do
    test "compiles cli/ with warnings as errors, after the app's compile and format" do
      assert Enum.at(project().pre_push_steps(), 2) ==
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

      assert ran() == ["compile", "format"]
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

      {"compile", argv, _opts} = Enum.at(project().pre_push_steps(), 2)

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
end
