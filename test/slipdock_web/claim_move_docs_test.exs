defmodule SlipdockWeb.ClaimMoveDocsTest do
  @moduledoc """
  A claimed card moves to the doing list on claim (#2633), said where agents
  and people look: the slipdock-loop skill skips the move for a runner's
  `list_top` job and uses the list its prompt names, and a bar or paths
  written then come after the move; the README's runner bullet, the agents
  page, the API guide and the Right now manual page say what the server now
  does. The help page's stage
  is pinned in `SlipdockWeb.HelpLive.FlowTest`, the code in
  `Slipdock.Runners.ClaimMoveTest`.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)

  # Compared with line breaks folded, since the skills and docs wrap their prose.
  defp flat(path),
    do: @root |> Path.join(path) |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")

  test "the loop skill's claim step leaves a runner's list_top move to the server" do
    loop = flat("priv/skills/slipdock-loop/SKILL.md")

    assert_states(loop, "**A runner's `list_top` job is moved already.**")

    assert_states(
      loop,
      "the server moved the card to the top of its board's doing list at the claim"
    )

    assert_states(loop, "it is the prompt's name to use if you ever do move it by hand")
    assert_states(loop, "on a board with no doing list the prompt says to leave it where it is")
  end

  test "the loop skill's bar and lanes parts say the claim has moved the card already" do
    loop = flat("priv/skills/slipdock-loop/SKILL.md")

    assert_states(
      loop,
      "In a runner's `list_top` job the claim has made that move already (step 4), so the bar is locked"
    )

    assert_states(
      loop,
      "so paths you write now are checked as an in-progress card's paths edit"
    )
  end

  test "the README's list_top bullet says the claim moves the card and the prompt names the list" do
    readme = flat("README.md")

    assert_states(
      readme,
      "The moment a runner claims that rule's job, the server moves the card to the top of its board's doing list"
    )

    assert_states(readme, "the job's prompt names the list")
  end

  test "the agents page says the claim moves the card, and what Right now lists" do
    agents = flat("docs/agents.md")

    assert_states(
      agents,
      "The moment a runner claims that rule's job, the server moves the card to the top of its board's doing list"
    )

    assert_states(agents, "The job's prompt names the list the card is in")
    assert_states(agents, "with `in_doing: false` when that is outside a doing list")
  end

  test "the API guide's runner section says the claim moves the card and the prompt names the list" do
    guide = SlipdockWeb.APIGuide.markdown() |> String.replace(~r/\s+/, " ")

    assert_states(
      guide,
      "When a runner claims a `list_top` rule's job, the server moves the card to the top of its board's doing list"
    )

    assert_states(guide, "The claimed job's prompt names the list the card is in")
  end

  test "Right now's manual page names every job kind that doesn't count as building" do
    page = flat("docs/manual/right-now.md")

    assert_states(page, "a verify, merge, overseer or probe job), wherever it sits")
    assert page =~ "`in_doing: false`"
  end
end
