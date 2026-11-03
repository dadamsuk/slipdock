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
    assert flat.("cli/lib/slipdock_cli.ex") =~ "verify <id> accept|reject|merged"
  end
end
