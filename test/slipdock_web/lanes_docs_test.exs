defmodule SlipdockWeb.LanesDocsTest do
  @moduledoc """
  Lanes (#1621) as the docs and the skills Slipdock serves describe them:
  the manual's section and README's line, and the steps the skills add —
  each one conditional on the board or runner having it on.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the manual has the section README links to, with every part" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## Lanes$/m
    assert read("README.md") =~ "docs/manual/lanes.md"

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
    # The section is `references/lanes.md` (#3004).
    lanes = read("priv/skills/slipdock-loop/references/lanes.md")
    assert lanes =~ "## Lanes"
    assert_states(lanes, "off unless the board\nor the runner has it on")
    assert lanes =~ ~s(slipdock\n  edit <id> --paths)
    assert lanes =~ "never `git add -A`"
    assert lanes =~ "git worktree add\n  ../<repo>-lanes/card-<id> -b card-<id>"
    assert lanes =~ "`$SLIPDOCK_WORKTREE` is set"
    assert_states(lanes, "only a person overrides a lane")

    # `SKILL.md` keeps the short of it: only when on, the paths, the staging,
    # the worktree, and where the rest is.
    loop = read("priv/skills/slipdock-loop/SKILL.md")
    [_, short] = String.split(loop, "\n## Lanes\n")
    [short | _] = String.split(short, "\n## ")
    assert_states(short, "off unless the board or the runner has it on")
    assert_states(short, "The whole of it is in `references/lanes.md`")
    assert_states(short, "write the card's paths before the claim's move")
    assert_states(short, "stage only files under them, by name, never `git add -A`")
    assert_states(short, "work in a git worktree of your own")
    assert_states(short, "unless the runner already put you in one (`$SLIPDOCK_WORKTREE` is set)")
    assert_states(short, "`git worktree add ../<repo>-lanes/card-<id> -b card-<id>`")
    assert_states(short, "A job's prompt that lists the card's paths has them already")
    # Step 4 points at it.
    assert_states(loop, "On a board with lanes on, write the card's paths before the move")
    assert_states(loop, "write the card's paths before the move (see `references/lanes.md`)")
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

  test "a pending card on a push board frees its lane and dependents, said everywhere (#1661)" do
    manual = read("docs/manual.md")
    assert manual =~ "**Cards awaiting verification.**"
    assert manual =~ "`released: true`"

    assert_states(
      manual,
      "keeps its lane and keeps\nblocking its dependents until it is accepted and merged"
    )

    assert_states(
      read("docs/agents.md"),
      "ships by push, a card awaiting verification frees its lane"
    )

    assert_states(
      read("priv/skills/slipdock-loop/references/lanes.md"),
      "a card awaiting\n  verification frees its lane and stops blocking its dependents"
    )

    assert_states(
      read("priv/skills/slipdock-work/SKILL.md"),
      "On a push board a card awaiting verification\n  frees its lane and its dependents"
    )

    guide = Slipdock.DocsText.read!("lib/slipdock_web/api_guide.ex")

    assert_states(
      guide,
      "ships by push, a card awaiting verification has\n      shipped: it frees its lane"
    )
  end

  test "an epic's lane is its subcards', said everywhere (#1811)" do
    manual = read("docs/manual.md")

    assert_states(
      manual,
      "**An epic's lane is its subcards'**: an epic (a card\nwhose sub-board has cards)"
    )

    assert_states(manual, "An epic with none left\nto take is checked on its own paths.")

    assert_states(
      read("docs/agents.md"),
      "An epic's lane is its subcards': in progress it holds\nnone of its own"
    )

    assert_states(
      Slipdock.DocsText.read!(Path.join(@root, "lib/slipdock_web/api_guide.ex")),
      "An epic's lane is its subcards': in progress it holds none\n      of its own"
    )
  end

  test "lanes and the WIP limit hold work jobs only, said everywhere (#1807)" do
    manual = read("docs/manual.md")

    assert_states(
      manual,
      "Only\nwork waits: a job that verifies or merges a card edits nobody's files"
    )

    assert_states(manual, "Jobs that verify or merge a card don't: they finish work")

    assert_states(
      read("docs/agents.md"),
      "Lanes hold work jobs only, never a verify or merge\njob."
    )

    assert_states(
      Slipdock.DocsText.read!(Path.join(@root, "lib/slipdock_web/api_guide.ex")),
      "Verify and merge\n      jobs are never held, by lanes or the WIP limit"
    )
  end

  test "shared paths are described everywhere an agent or a person reads about lanes (#1971)" do
    manual = read("docs/manual.md")
    assert manual =~ "**Shared paths.**"
    assert manual =~ ~s(set-board slipdock --shared-paths "docs/manual.md,README.md")
    assert manual =~ "counts in full"
    assert_states(manual, "hook says it let it through as shared")

    assert read("docs/agents.md") =~ "A board's `shared_paths`"

    assert_states(
      read("docs/manual/every-feature-in-brief.md"),
      ~s(board's shared paths that never count toward a lane, for the files nearly\n  every card edits (`slipdock set-board --shared-paths "docs/manual.md,README.md"`\))
    )

    guide = read("lib/slipdock_web/api_guide.ex")
    assert guide =~ "**Shared paths.** A board's `shared_paths`"
    assert guide =~ "shared paths (hold no lane): "

    assert read("lib/slipdock_web/live/help_live/flow.ex") =~
             "slipdock set-board B --shared-paths docs/manual.md,README.md"

    assert read("priv/skills/slipdock/SKILL.md") =~ "slipdock set-board <board> --shared-paths"
    assert read("priv/skills/slipdock-work/SKILL.md") =~ "Paths the board shares"

    assert_states(
      read("priv/skills/slipdock-loop/references/lanes.md"),
      "Declare the files the board shares too"
    )
  end

  test "advisory lanes are described everywhere an agent or a person reads about lanes (#1972)" do
    manual = read("docs/manual.md")
    assert manual =~ "**Advisory lanes.**"
    assert manual =~ ~r/slipdock set-board\s+slipdock --lane-mode advise/
    assert manual =~ "`true` is *Hold* and `false` is\n*Off*"

    assert_states(
      manual,
      "on a board whose lanes advise, a *Lanes* block naming each card in progress"
    )

    assert read("docs/agents.md") =~ "A board's `lane_mode` is `off`, `hold`"

    assert_states(
      read("docs/manual/every-feature-in-brief.md"),
      "advisory mode starts it and names that card in the job's prompt\n  (`slipdock set-board --lane-mode advise`)"
    )

    guide = read("lib/slipdock_web/api_guide.ex")
    assert guide =~ "**Advisory lanes.** A board's `lane_mode`"
    assert_states(guide, "lanes: advise — write a card's paths before starting it")

    assert read("lib/slipdock_web/live/help_live/flow.ex") =~
             "slipdock set-board B --lane-mode advise"

    assert read("priv/skills/slipdock/SKILL.md") =~
             "slipdock set-board <board> --lane-mode off|hold|advise"

    assert_states(read("priv/skills/slipdock-work/SKILL.md"), "On a\n  board whose lanes advise")

    assert read("priv/skills/slipdock-loop/references/lanes.md") =~
             "- **The board's lanes advise**"
  end

  test "broad paths are said to be advice where paths are documented (#2698)" do
    manual = read("docs/manual/lanes.md")
    assert manual =~ "**Broad paths.**"
    assert_states(manual, "It is advice, not a refusal")
    assert manual =~ "`paths_broad`"

    agents = read("docs/agents.md")

    assert_states(
      agents,
      "is *broad*, since it\noverlaps most cards. It is advice, not a refusal"
    )

    assert agents =~ "`paths_broad`"

    guide = read("lib/slipdock_web/api_guide.ex")
    assert_states(guide, "**Broad paths.** Keep `paths` as narrow as the change")
    assert guide =~ "is advice, not a refusal"
    assert guide =~ "`broad`: `this`, `other` or `both`"
  end
end
