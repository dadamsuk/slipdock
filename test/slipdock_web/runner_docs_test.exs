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

  test "the daemon keeping the skills current is described in the manual (#2614)" do
    manual = read("docs/manual.md")
    assert manual =~ "`no_skills_update: true`"
    assert manual =~ "fetches the server's\n`/api/skills.tar.gz`"
    assert manual =~ "skill folder that is a symlink"

    assert read("CLAUDE.md") =~
             "The runner daemon also puts the server's there before each agent job (#2614)"

    refute read("CLAUDE.md") =~ "installs nothing yet"
  end

  test "agents.md and the API guide say the daemon keeps the skills current, and when not (#2643)" do
    agents = read("docs/agents.md")

    assert agents =~
             "needs no step for its skills: before\neach agent job its daemon puts the server's skills in place"

    assert agents =~ "whose `local.json` sets `no_skills_update: true`"
    assert agents =~ "Under the `user` executor the job account unpacks\nthe skills itself"
    refute agents =~ "Under the `user` executor, and for a CLI the daemon doesn't write"

    guide = read("lib/slipdock_web/api_guide.ex")

    assert guide =~
             "under the `user`\n    executor the job account unpacks them; `no_skills_update` turns it\n    off"

    assert guide =~
             "For skills it doesn't update and\n    a CLI it doesn't write, run the install one-liner"

    refute guide =~ "Otherwise, run the install one-liner"
  end

  test "a container job's live transcript is described as sent, and how it is read (#2625)" do
    machines = read("docs/manual/machines.md")
    assert machines =~ "fresh,\n  empty directory of the job's own at `~/.claude/projects`"
    assert machines =~ "The live transcript is sent as it is for any other job"
    assert machines =~ "a link, a FIFO or a file over 128 MB"
    refute machines =~ "the live transcript isn't sent"

    assert read("daemon/internal/contract/contract.md") =~
             "an empty directory of its own for the agent's\n  transcript"
  end

  test "the daemon keeping the CLI current is described in the manual, agents page and help (#2631)" do
    manual = read("docs/manual.md")
    assert manual =~ "`no_cli_update: true`"
    assert manual =~ "fetches\n`/cli/slipdock.escript`, checks its SHA-256"
    assert manual =~ "A failed fetch or a wrong sum keeps the CLI there was"
    refute manual =~ "There, and for the `slipdock` CLI, run the"

    agents = read("docs/agents.md")
    assert agents =~ "`no_cli_update: true`"
    assert agents =~ "so a deploy leaves no runner *cli old*"
    refute agents =~ "The server never changes the machine: run the install"

    help = read("lib/slipdock_web/live/help_live/agents.ex")
    assert help =~ ~s(id="help-machine-keeps-current")
    assert help =~ "A failed fetch or a wrong sum keeps the CLI it had"
    assert help =~ "<code>no_cli_update</code>"

    guide = read("lib/slipdock_web/api_guide.ex")
    assert guide =~ "A daemon clears it itself"
    assert guide =~ "`no_cli_update` in `local.json` turns that off"
  end

  test "the CLI is installed only signed, and cli_checksum_only is the way round it (#2669)" do
    for path <- ["docs/manual.md", "docs/agents.md", "lib/slipdock_web/api_guide.ex"] do
      text = read(path)
      assert text =~ "`/cli/slipdock.escript.sig`", "#{path} doesn't name the signature"
      assert text =~ "cli_checksum_only", "#{path} doesn't name cli_checksum_only"
    end

    assert read("docs/manual/machines.md") =~ "`cli_checksum_only: true` lets it install a CLI"

    help = read("lib/slipdock_web/live/help_live/agents.ex")
    assert help =~ "installed only when its signature verifies"
    assert help =~ "<code>cli_checksum_only</code>"

    # The trust contract no longer says the CLI is checked only against the
    # server's checksum, except under cli_checksum_only.
    contract = read("daemon/internal/contract/contract.md")
    assert contract =~ "Give the agent a `slipdock` CLI the project didn't sign."
    assert contract =~ "With `cli_checksum_only` set in `local.json`"

    refute contract =~
             "it is checked only against the checksum the same\n  server publishes, not the release key"
  end

  test "the skills are installed only signed, and skills_unsigned is the way round it (#2784)" do
    for path <- [
          "docs/agents.md",
          "docs/manual/runners.md",
          "docs/manual/machines.md",
          "lib/slipdock_web/api_guide.ex"
        ] do
      text = read(path)
      assert text =~ "`/api/skills.tar.gz.sig`", "#{path} doesn't name the signature"
      assert text =~ "skills_unsigned", "#{path} doesn't name skills_unsigned"
    end

    assert read("docs/manual/machines.md") =~
             "`skills_unsigned: true` does the same for the skills"

    assert read("lib/slipdock_web/live/help_live/agents.ex") =~ "<code>skills_unsigned</code>"

    # docs/agents.md says what the daemon trusts the server with.
    agents = read("docs/agents.md")
    assert agents =~ "**What the daemon trusts the server with.**"
    assert agents =~ "a key the server doesn't hold"

    # The trust contract no longer says the skills are checked against
    # nothing but the server, except under skills_unsigned.
    contract = read("daemon/internal/contract/contract.md")
    assert contract =~ "Give the agent slipdock skills the project didn't sign."
    assert contract =~ "With\n  `skills_unsigned` set in `local.json`"

    refute contract =~
             "they are instructions the agent follows, checked against nothing but\n  the server"
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
