defmodule SlipdockWeb.SkillProgressDocsTest do
  @moduledoc """
  Epic passes show their progress (#1853), said where agents and people
  look: the slipdock-loop skill has a runner's pass report milestones as job
  steps, and fixes a build a closed subcard broke on a new subcard instead of
  reopening it (#1850); the manual says what the health monitor counts as a
  sign of work. The epic's progress lines are the server's (#1881): the skill
  leaves them to it and asks for what only the agent knows,
  and the manual describes them.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2, assert_states: 3]

  @root Path.expand("../..", __DIR__)

  # Compared with line breaks folded, since the skills and docs wrap their prose.
  defp flat(path),
    do: @root |> Path.join(path) |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")

  test "the loop skill has a runner's pass report steps, and the epic hear of each subcard" do
    loop = flat("priv/skills/slipdock-loop/SKILL.md")

    assert_states(
      loop,
      "in a runner's job (`$SLIPDOCK_JOB_ID` is set), each milestone as the job's step"
    )

    assert loop =~ ~s(`slipdock job-progress --step "…"`)
    assert_states(loop, "The runner holds that job, so don't claim or finish it.")
  end

  test "the loop leaves an epic's progress lines to the server (#1881)" do
    path = Path.join(@root, "priv/skills/slipdock-loop/SKILL.md")
    loop = path |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")

    refute loop =~ "a one-line comment on the epic itself as each subcard closes", path
    assert_states(loop, "the server posts each subcard's progress on the epic itself", path)
    assert loop =~ "Don't repeat those.", path

    assert_states(
      loop,
      "Comment on the epic only what the server can't know: a decision, a surprise, " <>
        "a dead end, a change of plan",
      path
    )
  end

  test "the manual describes an epic's comments (#1881)" do
    manual = flat("docs/manual.md")
    assert_states(manual, "the server posts a line on the epic")
    assert_states(manual, "consecutive lines within 10 seconds share one comment")
    assert_states(manual, "follows its subcards (done ÷ all, rounded down)")
  end

  test "a build a closed subcard broke is fixed on a new subcard, not by reopening it" do
    loop = flat("priv/skills/slipdock-loop/SKILL.md")

    assert loop =~ ~s(slipdock add <sub-board> "Build failed: #<id> <title>")
    assert_states(loop, "the board refuses an agent reopening a done card")
    assert_states(loop, "file the fix under that epic as in section 5")
    refute loop =~ "Take it back — `slipdock undone <id>`"
    refute loop =~ "taken back as in section 5"
  end

  test "the manual and agents.md say what counts as a sign of work" do
    assert_states(
      flat("docs/manual.md"),
      "no note on its card or on any card beneath it (an epic's pass writes on its subcards)"
    )

    assert_states(flat("docs/agents.md"), "every runner job's prompt asks for its milestones too")
  end
end
