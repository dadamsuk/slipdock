defmodule SlipdockWeb.LanesDocsTest do
  @moduledoc """
  Lanes (#1621) as the docs and the skills Slipdock serves describe them:
  the manual's section and README's line, and the steps the skills add —
  each one conditional on the board or runner having it on.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the manual has the section README links to, with every part" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## Lanes$/m
    assert read("README.md") =~ "docs/manual.md#lanes"

    for part <- [
          "**Paths on a card.**",
          "**The board switch.**",
          "**A worktree per runner job.**",
          "**The lane-check hook.**",
          "slipdock hook install lane-check",
          ~r/slipdock\s+set-board slipdock --lanes/,
          "Lane: overlaps #N, in progress"
        ],
        do: assert(manual =~ part, inspect(part))
  end

  test "the loop skill writes paths, stages only them and uses a worktree, all only when on" do
    loop = read("priv/skills/slipdock-loop/SKILL.md")
    assert loop =~ "## Lanes"
    assert loop =~ "off unless the board\nor the runner has it on"
    assert loop =~ ~s(slipdock\n  edit <id> --paths)
    assert loop =~ "never `git add -A`"
    assert loop =~ "git worktree add\n  ../<repo>-lanes/card-<id> -b card-<id>"
    assert loop =~ "`$SLIPDOCK_WORKTREE` is set"
    assert loop =~ "only a person overrides a lane"
    # Step 4 points at it.
    assert loop =~ "On a board with lanes on, write the card's paths before the move"
  end

  test "the work skill and the CLI skill say the same" do
    work = read("priv/skills/slipdock-work/SKILL.md")
    assert work =~ "**Lanes, where they are on**"
    assert work =~ "stage only files under them"
    assert work =~ "$SLIPDOCK_WORKTREE"

    cli = read("priv/skills/slipdock/SKILL.md")
    assert cli =~ "slipdock set-board <board> --lanes | --no-lanes"
    assert cli =~ "slipdock edit <id> --paths"
    assert cli =~ "slipdock hook install lane-check"
  end
end
