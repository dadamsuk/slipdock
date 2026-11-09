defmodule SlipdockWeb.RunnerDocsTest do
  @moduledoc """
  Runners as the docs describe them: README, the manual and docs/agents.md
  each explain them, link to the manual's section by a heading that exists,
  and name the commands and endpoints that really are there.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the manual has the section the others link to" do
    assert read("docs/manual.md") =~ ~r/^## Runners$/m
    assert read("README.md") =~ "docs/manual/runners.md"
    assert read("README.md") =~ ~r/^## Run an agent against a board$/m
    assert read("docs/agents.md") =~ "manual/runners.md"
  end

  test "each says where to start and draws the same trust line" do
    for doc <- ["README.md", "docs/manual.md", "docs/agents.md"] do
      text = read(doc)
      assert text =~ "Connect a runner", doc
      assert text =~ ~r/never\s+(calls|connects\s+to)\s+(the\s+machine|them)/, doc
    end
  end

  test "a worktree per job (#1627) is described, as a machine's runner's setting" do
    assert read("docs/manual.md") =~ "`card-<id>`"
    assert read("docs/manual/machines.md") =~ "With `worktree` on"
    assert read("README.md") =~ "a worktree per job"
    assert read("README.md") =~ "`card-<id>`"
  end

  test "the CLI commands the manual's table names are ones the CLI has" do
    help = read("cli/help.txt")

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
      assert text =~ "--allowedTools", path
      assert text =~ "allowed_tools", path
      assert text =~ "claude_ai_Slipdock", path
      assert text =~ ".claude/settings.json", path
      # The wizard's options for the shell runner went with it (#2582).
      refute text =~ "--no-slipdock-tools", path
      refute text =~ "Let it use the Slipdock tools", path
    end

    assert read("docs/agents.md") =~ "can't use the Slipdock tools"
    assert read("README.md") =~ "nobody will answer questions"
  end

  test "the docs call the preset Send cards to a runner, and the old name is gone" do
    for path <- ["docs/agents.md", "docs/manual.md"] do
      assert read(path) =~ "Send cards to a runner", path
    end

    for path <- ["docs/agents.md", "docs/manual.md", "README.md", "priv/skills/slipdock/SKILL.md"] do
      refute read(path) =~ "Send cards to a coding agent", path
    end

    assert read("docs/manual.md") =~ "**Advanced**"
  end

  test "the built-in merge kind is described in the docs (#1656)" do
    manual = read("docs/manual.md")
    assert manual =~ "**Runners merge.**"
    assert manual =~ "`gh pr merge --match-head-commit`"
    assert manual =~ "`X-Runner-Kinds`"
    assert manual =~ "`no_merge: true`"
    assert read("docs/agents.md") =~ "built-in `merge` kind"

    guide = read("lib/slipdock_web/api_guide.ex")
    assert guide =~ "`merge` jobs (merging an accepted card's pull request)"
    assert guide =~ "built into\n    the runner daemon"
    assert guide =~ "`X-Runner-Kinds`"
  end
end
