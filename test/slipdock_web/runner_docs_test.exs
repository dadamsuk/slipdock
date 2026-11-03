defmodule SlipdockWeb.RunnerDocsTest do
  @moduledoc """
  Runners as the docs describe them: README, the manual and docs/agents.md
  each explain them, link to the manual's section by a heading that exists,
  and name the commands and endpoints that really are there.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the manual has the section the others link to" do
    assert read("docs/manual.md") =~ ~r/^## Runners$/m
    assert read("README.md") =~ "docs/manual.md#runners"
    assert read("README.md") =~ ~r/^## Run an agent against a board$/m
    assert read("docs/agents.md") =~ "manual.md#runners"
  end

  test "each says where to start and draws the same trust line" do
    for doc <- ["README.md", "docs/manual.md", "docs/agents.md"] do
      text = read(doc)
      assert text =~ "Connect a runner", doc
      assert text =~ ~r/never\s+(calls|connects\s+to)\s+(the\s+machine|them)/, doc
    end
  end

  test "a worktree per job (#1627) is described, with the settings the runners read" do
    runner = read("priv/runner/slipdock-runner")
    ps = read("priv/runner/slipdock-runner.ps1")

    for setting <- ["WORKTREE=1", "WORKTREE_REPO", "WORKTREE_DIR", "$SLIPDOCK_WORKTREE"] do
      assert read("docs/manual.md") =~ setting
    end

    for {setting, script} <- [{"WORKTREE_REPO", runner}, {"$WorktreeRepo", ps}],
        do: assert(script =~ setting)

    assert read("README.md") =~ "A git worktree per job"
    assert read("README.md") =~ "`card-<id>`"
  end

  test "the installers named are the ones served" do
    for path <- ["/runner/install.sh", "/runner/install.ps1", "/runner/SHA256SUMS"] do
      assert read("docs/manual.md") =~ path
    end

    served = SlipdockWeb.RunnerInstallController.files() |> Map.keys()

    assert Enum.sort(served) == [
             "SHA256SUMS",
             "install.ps1",
             "install.sh",
             "slipdock-runner",
             "slipdock-runner.ps1"
           ]
  end

  test "the CLI commands the manual's table names are ones the CLI has" do
    help = read("cli/lib/slipdock_cli.ex")

    for command <- [
          "runner new",
          "runner setup",
          "runner token",
          "runner rm",
          "jobs",
          "job",
          "cancel-job",
          "claim-job",
          "job-progress",
          "finish-job"
        ] do
      assert read("docs/manual.md") =~ "slipdock #{command}", command
      assert help =~ command, command
    end
  end

  test "the slipdock skill knows the runner action and commands" do
    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ ~s({"type": "runner", "pool": "default", "kind": "claude"})
    assert skill =~ "slipdock runner new <board>"
    assert skill =~ "slipdock cancel-job <id>"
  end

  test "the docs say a runner may use the Slipdock tools, and how to fix it when it can't" do
    for path <- ["docs/agents.md", "docs/manual.md", "priv/skills/slipdock/SKILL.md"] do
      text = read(path)
      assert text =~ "--allowedTools" or text =~ "--mcp-servers", path
      assert text =~ "claude_ai_Slipdock", path
      assert text =~ ".claude/settings.json", path
    end

    assert read("docs/agents.md") =~ "can't use the Slipdock tools"
    assert read("docs/manual.md") =~ "--no-slipdock-tools"
    assert read("README.md") =~ "nobody will answer questions"
    assert read("docs/manual.md") =~ "another user's `~bob/…` is refused"
    assert read("docs/agents.md") =~ "can't cd to ~/"
  end

  test "the docs call the preset Send cards to a runner, and the old name is gone" do
    for path <- ["docs/agents.md", "docs/manual.md"] do
      assert read(path) =~ "Send cards to a runner", path
    end

    for path <- ["docs/agents.md", "docs/manual.md", "README.md", "priv/skills/slipdock/SKILL.md"] do
      refute read(path) =~ "Send cards to a coding agent", path
    end

    assert read("docs/manual.md") =~ "**Verify the\nscript**"
    assert read("docs/manual.md") =~ "**Advanced**"
  end

  test "the built-in merge kind is described in the scripts and the docs (#1656)" do
    sh = read("priv/runner/slipdock-runner")
    ps = read("priv/runner/slipdock-runner.ps1")
    assert sh =~ "Built in: the merge kind (#1656)"
    assert sh =~ "MERGE=0 in the config turns it off"
    assert ps =~ "Built in: the merge kind (#1656)"
    assert ps =~ "$Merge = $false in the config turns"

    manual = read("docs/manual.md")
    assert manual =~ "**Runners merge.**"
    assert manual =~ "`gh pr merge --match-head-commit`"
    assert manual =~ "`X-Runner-Kinds`"
    assert read("docs/agents.md") =~ "built-in `merge` kind"

    guide = read("lib/slipdock_web/api_guide.ex")
    assert guide =~ "`merge` jobs are built into the"
    assert guide =~ "`X-Runner-Kinds`"
  end
end
