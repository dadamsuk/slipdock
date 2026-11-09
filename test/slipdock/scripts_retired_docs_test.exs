defmodule Slipdock.ScriptsRetiredDocsTest do
  @moduledoc """
  The shell and PowerShell runners were retired for the runner daemon
  (#2582, W-2544 §10). Nothing the repository tells a person or an agent may
  still say how to install, update or configure them: no `/runner/` install
  line, no checksums, hook examples or hook prompt, no self-update, no
  `server` or `windows` scenario. The manual's Runners page says they were
  retired and points at Machines, and the files themselves are gone.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  defp skills do
    Path.wildcard(Path.join(@root, "priv/skills/**/*.md"))
    |> Enum.map(&Path.relative_to(&1, @root))
  end

  # Everything that tells somebody how to run an agent against a board.
  defp docs do
    ["README.md", "docs/agents.md", "docs/manual.md", "cli/help.txt"] ++
      Enum.map(
        ~w(agents flow guides),
        &"lib/slipdock_web/live/help_live/#{&1}.ex"
      ) ++ skills()
  end

  # How the scripts were installed, checked, kept current and configured.
  @gone [
    "/runner/install.sh",
    "/runner/install.ps1",
    "/runner/SHA256SUMS",
    "/runner/slipdock-runner",
    "/runner/examples",
    "priv/runner/",
    "--hook-prompt",
    "--no-self-update",
    "-NoSelfUpdate",
    "SELF_UPDATE",
    "SKILLS_UPDATE",
    "$SelfUpdate",
    "Keep the runner current",
    "runner that keeps itself current",
    "X-Runner-Latest",
    "--install-name",
    "--no-slipdock-tools",
    "--mcp-servers",
    "Have Claude write this hook",
    "Linux / macOS machine",
    "daemon|server|windows",
    "`server` (the default)",
    "job_verify",
    "WORKTREE_REPO",
    "Change Settings",
    "passlog.sh"
  ]

  test "no doc, help page or skill says how to install, update or set up a shell runner" do
    for path <- docs(), text = read(path), phrase <- @gone do
      refute text =~ phrase, "#{path} still says #{inspect(phrase)}"
    end
  end

  test "the agent guide, which every agent reads, says none of it either" do
    guide = SlipdockWeb.APIGuide.markdown()
    for phrase <- @gone, do: refute(guide =~ phrase, "the guide still says #{inspect(phrase)}")

    assert String.replace(guide, ~r/\s+/, " ") =~
             "every path under `/runner/`, where they were served, answers 410 Gone"
  end

  test "the manual's Runners page says they were retired and points at Machines" do
    runners = read("docs/manual/runners.md")
    assert runners =~ "**The shell runners were retired** (#2582)"
    assert runners =~ "*410 Gone*"
    assert runners =~ "**Move to a machine**"
    assert runners =~ "[machine](machines.md)"
    assert runners =~ "[Machines page](machines.md#the-machines-page)"

    assert String.replace(runners, ~r/\s+/, " ") =~
             "*Moving a machine's runners onto the daemon*"

    machines = read("docs/manual/machines.md")
    refute machines =~ "its runners are still the\n[shell runners]"
    assert machines =~ "It replaced the shell and PowerShell runners"
  end

  test "the README, agents.md and the help page say so too" do
    flat = fn path -> path |> read() |> String.replace(~r/\s+/, " ") end
    assert flat.("README.md") =~ "were retired (#2582)"
    assert flat.("docs/agents.md") =~ "every path under `/runner/` answers 410 Gone"
    assert read("lib/slipdock_web/live/help_live/agents.ex") =~ ~s(id="help-scripts-retired")
  end

  test "the scripts, their tests and their CI job are gone from the repository" do
    refute File.exists?(Path.join(@root, "priv/runner"))

    refute File.exists?(
             Path.join(@root, "lib/slipdock_web/controllers/runner_install_controller.ex")
           )

    refute File.exists?(Path.join(@root, "lib/slipdock/runners/hook_prompt.ex"))
    refute File.exists?(Path.join(@root, "test/powershell/runner_smoke.ps1"))

    ci = read(".github/workflows/ci.yml")
    refute ci =~ "windows-runner:"
    refute ci =~ "runner on Windows PowerShell"
    refute ci =~ "runner_smoke.ps1"
  end
end
