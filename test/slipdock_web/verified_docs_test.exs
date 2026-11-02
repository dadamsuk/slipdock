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
          "### Verify jobs"
        ],
        do: assert(manual =~ heading)

    assert manual =~ "| `verify_card` |"
    assert manual =~ "job_verify"
  end

  test "README and agents.md name it" do
    assert read("README.md") =~ "**Verified work**"
    assert read("README.md") =~ "`verify_card`"
    assert read("docs/agents.md") =~ "**Verified work.**"
  end

  test "the skills say what changes in a pass, and the CLI skill names the commands" do
    loop = read("priv/skills/slipdock-loop/SKILL.md")
    assert loop =~ "## Verified work"
    assert loop =~ "slipdock edit <id> --bar"
    assert loop =~ "--evidence-commit"
    assert loop =~ "slipdock verify <id> accept"
    assert loop =~ "Submitted for verification"

    assert read("priv/skills/slipdock-work/SKILL.md") =~
             "**Verified work, where a board has it on**"

    cli = read("priv/skills/slipdock/SKILL.md")
    assert cli =~ "slipdock verify <id> accept|reject"
    assert cli =~ "--verify-pool"
  end
end
