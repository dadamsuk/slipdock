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
end
