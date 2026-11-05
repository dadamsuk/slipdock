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

    fn task, argv ->
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
    assert project().pre_push_steps(["--from-git-ref", "x"]) |> Enum.take(5) ==
             project().pre_push_steps() |> Enum.take(5)
  end

  test "builds in a root of its own, so it can run beside mix test" do
    root = project().pre_push_build_root()
    assert Path.dirname(root) == Path.join(@root, "_build")
    refute String.starts_with?(Mix.Project.build_path(), root)
  end

  test "runs every step in turn and says how long it took" do
    out = capture_io(fn -> project().pre_push([], recorder()) end)

    assert ran() == ["compile", "format", "hex.audit", "deps.audit", "sobelow", "credo"]
    assert out =~ "==> pre_push: mix compile --force --warnings-as-errors"
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

    assert ran() == ["compile", "format", "hex.audit"]
  end

  test "a credo finding (exit 8) fails the run, after every other check" do
    out =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/mix credo diff .* failed \(exit 8\)/, fn ->
          project().pre_push([], recorder(%{"credo" => 8}))
        end
      end)

    assert length(ran()) == 6
    refute out =~ "all checks passed"
  end
end
