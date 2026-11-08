defmodule SlipdockWeb.VerifiedDocsTest do
  @moduledoc """
  Verified work (#1620) is written down where people and agents look: the
  manual and README, agents.md, and the skills Slipdock serves, which tell a
  pass what changes on a board with each check on.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))

  test "the manual has the section, each check, and verify_card in its tool table" do
    manual = read("docs/manual.md")
    assert manual =~ "## Verified work"

    for heading <- [
          "### The bar",
          "### Evidence",
          "### A second agent verifies",
          "### Verify jobs",
          "### Shipping by pull request"
        ],
        do: assert(manual =~ heading)

    assert manual =~ "| `verify_card` |"
    assert manual =~ "job_verify"
  end

  test "README and agents.md name it" do
    assert read("README.md") =~ "**Verified work**"
    # Ship by PR (#1653): the merge, the pending-lane release, self-update.
    readme = "README.md" |> read() |> String.replace(~r/\s+/, " ")
    assert readme =~ "`slipdock verify 12 merged`"
    assert readme =~ "a card awaiting verification frees its lane and its dependents"
    assert readme =~ "keep themselves current between jobs"
    assert read("README.md") =~ "`verify_card`"
    assert read("docs/agents.md") =~ "**Verified work.**"
    assert read("docs/agents.md") =~ "**ship by pull request**"
    assert read("README.md") =~ "--ship-via pull-request"
  end

  test "the skills say what changes in a pass, and the CLI skill names the commands" do
    loop = read("priv/skills/slipdock-loop/SKILL.md")
    assert loop =~ "## Verified work"
    assert loop =~ "slipdock edit <id> --bar"
    assert loop =~ "--evidence-commit"
    assert loop =~ "slipdock verify <id> accept"
    assert loop =~ "Submitted for verification"
    # #1626: never change a locked bar; structured evidence; a clean tree;
    # never verify your own.
    assert loop =~ "never try to change it"
    assert loop =~ "--suite"
    assert loop =~ "git worktree add"
    assert loop =~ "Never verify a card you built"

    work = read("priv/skills/slipdock-work/SKILL.md")
    assert work =~ "**Verified work, where a board has it on**"
    assert work =~ "read that reason first"
    assert work =~ "clean tree"

    cli = read("priv/skills/slipdock/SKILL.md")
    assert cli =~ "slipdock verify <id> accept|reject"
    assert cli =~ "--verify-pool"

    # #1655: shipping by pull request — never push main, the PR's checks, done --pr.
    # Compared with its line breaks folded, since the skills wrap their prose.
    for skill <- [loop, work], skill = String.replace(skill, ~r/\s+/, " ") do
      assert skill =~ "ships by pull request"
      assert skill =~ "gh pr create --head card-<id>"
      assert skill =~ "slipdock done <id> --pr <url>"
    end

    assert String.replace(loop, ~r/\s+/, " ") =~ "never push the default branch"
    assert String.replace(loop, ~r/\s+/, " ") =~ "gh pr checks card-<id> --watch"
    assert cli =~ "--ship-via pull-request"
    assert cli =~ "--pr https://"
  end

  test "builders check the bar at pickup and ask when a part needs a person (#1883)" do
    flat = fn text -> String.replace(text, ~r/\s+/, " ") end
    # The packaged skills: their one source is priv/skills/ (#2048).
    for skill <- ["slipdock-loop", "slipdock-work"],
        path = Path.join([@root, "priv/skills", skill, "SKILL.md"]),
        text = flat.(File.read!(path)) do
      assert text =~ "**Check the bar at pickup**, before building", path
      assert text =~ "needs a person (a handbook rule added, reworded or dropped, a merge", path
      assert text =~ ~s(slipdock wait <id> "…"), path
      assert text =~ "the conflict to the verifier", path

      assert text =~
               ~s|"proposed as a garden proposal (rule id, wording)", never "W-x has rule Y"|,
             path
    end

    manual = flat.(read("docs/manual.md"))
    assert manual =~ "**Checked at pickup.**"
    assert manual =~ "**Write a bar that can be met.**"

    assert manual =~
             ~s|"proposed as a garden proposal (rule id, wording)", never "W-x has rule Y"|

    assert flat.(read("docs/agents.md")) =~
             ~s|a rule change "proposed as a garden proposal (rule id, wording)", never "W-x has rule Y"|

    assert flat.(read("docs/agents.md")) =~ "the builder checks it at pickup and asks with a wait"
  end

  test "builders run the project's own pre-push checks and watch with --fail-fast (#1866)" do
    flat = fn path -> path |> read() |> String.replace(~r/\s+/, " ") end

    for path <- [
          "priv/skills/slipdock-loop/SKILL.md",
          "priv/skills/slipdock-work/SKILL.md",
          "lib/slipdock_web/api_guide.ex",
          "docs/manual.md"
        ],
        text = flat.(path) do
      assert text =~ "the project's own pre-push checks", path
      assert text =~ "contributing guide or handbook", path
      assert text =~ "formatting and a compile that fails on warnings", path
      assert text =~ "--watch --fail-fast", path
      refute text =~ "the quick checks", path
    end

    assert flat.("docs/manual.md") =~ "Slipdock's own is `mix pre_push`"
  end

  test "accepting on a pull request board merges, said everywhere (#1657)" do
    flat = fn path -> path |> read() |> String.replace(~r/\s+/, " ") end

    assert flat.("docs/manual.md") =~ "**Accepting merges.**"
    assert flat.("docs/manual.md") =~ "press **Merged it myself** (`slipdock verify 12 merged"
    assert flat.("docs/agents.md") =~ "accepting a card there queues the merge"
    assert flat.("lib/slipdock_web/api_guide.ex") =~ ~s(sets `verify_state: "merging"`)
    assert flat.("priv/skills/slipdock-loop/SKILL.md") =~ "the card shows *merging* until then"

    assert flat.("priv/skills/slipdock-work/SKILL.md") =~
             "A failed merge sends the card back rejected"

    assert flat.("priv/skills/slipdock/SKILL.md") =~ "slipdock verify <id> merged"
    assert flat.("cli/help.txt") =~ "verify <id> accept|reject|merged"
  end

  test "done stays done, said where people and agents look (#1850)" do
    flat = fn path -> path |> read() |> String.replace(~r/\s+/, " ") end

    assert flat.("docs/manual.md") =~
             "**Done stays done.** An agent can't reopen a completed card"

    assert flat.("docs/manual.md") =~ "or accepted and waiting for its pull request to merge"
    assert flat.("docs/agents.md") =~ "**Done stays done.** On every board, with no switch"
    assert flat.("README.md") =~ "reopen a done card: done stays done unless a person reopens it"
    assert flat.("lib/slipdock_web/api_guide.ex") =~ "or reopen a done card**"
    assert flat.("priv/skills/slipdock-loop/SKILL.md") =~ "Nor can an agent reopen a done card"
    assert flat.("priv/skills/slipdock/SKILL.md") =~ "an agent can't undo or move a done card"
  end

  test "an epic on a pull request board completes without a PR of its own (#1917)" do
    flat = fn path -> path |> read() |> String.replace(~r/\s+/, " ") end

    assert flat.("lib/slipdock_web/api_guide.ex") =~
             "complete the epic without `--pr`"

    assert flat.("docs/agents.md") =~ "An epic there names none of its own"
    assert flat.("docs/manual.md") =~ "**Epics have no pull request of their own.**"
    assert flat.("README.md") =~ "completes without a pull request of its own"
    loop = flat.("priv/skills/slipdock-loop/SKILL.md")
    assert loop =~ "complete the epic without `--pr`"
    assert loop =~ "never open a token PR"
    assert flat.("priv/skills/slipdock-work/SKILL.md") =~ "An epic names no PR"

    assert flat.("priv/skills/slipdock/SKILL.md") =~
             "completes with --evidence alone and accepting merges nothing"
  end
end
