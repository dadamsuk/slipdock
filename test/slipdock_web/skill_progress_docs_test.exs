defmodule SlipdockWeb.SkillProgressDocsTest do
  @moduledoc """
  Epic passes show their progress (#1853), said where agents and people
  look: the slipdock-loop skill has a runner's pass report milestones as job
  steps and comment on the epic as each subcard closes, and fixes a build a
  closed subcard broke on a new subcard instead of reopening it (#1850); the
  manual says what the health monitor counts as a sign of work.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Compared with line breaks folded, since the skills and docs wrap their prose.
  defp flat(path), do: @root |> Path.join(path) |> File.read!() |> String.replace(~r/\s+/, " ")

  test "the loop skill has a runner's pass report steps, and the epic hear of each subcard" do
    loop = flat("priv/skills/slipdock-loop/SKILL.md")

    assert loop =~
             "in a runner's job (`$SLIPDOCK_JOB_ID` is set), each milestone as the job's step"

    assert loop =~ ~s(`slipdock job-progress --step "…"`)
    assert loop =~ "The runner holds that job, so don't claim or finish it."
    assert loop =~ "a one-line comment on the epic itself as each subcard closes"
  end

  test "a build a closed subcard broke is fixed on a new subcard, not by reopening it" do
    loop = flat("priv/skills/slipdock-loop/SKILL.md")

    assert loop =~ ~s(slipdock add <sub-board> "Build failed: #<id> <title>")
    assert loop =~ "the board refuses an agent reopening a done card"
    assert loop =~ "file the fix under that epic as in section 5"
    refute loop =~ "Take it back — `slipdock undone <id>`"
    refute loop =~ "taken back as in section 5"
  end

  test "the manual and agents.md say what counts as a sign of work" do
    assert flat("docs/manual.md") =~
             "no note on its card or on any card beneath it (an epic's pass writes on its subcards)"

    assert flat("docs/agents.md") =~ "every runner job's prompt asks for its milestones too"
  end
end
