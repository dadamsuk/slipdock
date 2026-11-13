defmodule SlipdockWeb.ScheduledListDocsTest do
  @moduledoc """
  The Scheduled list (#2100) is never where "what next" is answered from,
  and every place that tells an agent or a person how to pick work says so:
  the loop and work skills, the API guide, docs/agents.md, the manual and
  the README and the in-app help (HelpLive.Guides, HelpLive.Flow).
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)
  # Line breaks folded, for prose that is rewrapped as it changes.
  defp flat(path),
    do: @root |> Path.join(path) |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")

  test "the loop skill never takes from it, even with the ready list empty" do
    loop = flat("priv/skills/slipdock-loop/references/picking.md")
    assert_states(loop, "Nor from a **Scheduled** list (category `scheduled`")
    assert loop =~ "`scheduled: worked by feed rules`"
    assert_states(loop, "never takes from it, even when the ready list is empty")
    assert_states(loop, "a card from it comes to a pass only as a job")
  end

  test "the work skill never picks from it" do
    work = flat("priv/skills/slipdock-work/SKILL.md")

    assert_states(
      work,
      "or a *Scheduled* one (category `scheduled`: recurring agent work, worked by feed rules)"
    )
  end

  test "the API guide's own words" do
    guide = flat("lib/slipdock_web/api_guide.ex")
    assert_states(guide, "**Never take work from a Scheduled list.**")
    assert guide =~ "Feed rules work it"
    assert_states(guide, "it is never the ready list or the backlog")
    assert_states(guide, "the board's Scheduled list when it has one, else its ready list")
    assert guide =~ "(`scheduled_missed`)"
  end

  test "docs/agents.md" do
    agents = flat("docs/agents.md")

    assert_states(
      agents,
      "Never take work from a **Scheduled** list either (category `scheduled`"
    )

    assert agents =~ "Feed rules work it"
    assert agents =~ "`list_boards` names it as `scheduled` beside `ready` and `done`"
    assert agents =~ "(`scheduled_missed`)"
    assert agents =~ "MCP `create_list`"
  end

  test "the manual" do
    manual = flat("docs/manual.md")
    assert_states(manual, "**The Scheduled list.** A list in the `scheduled` category")
    assert_states(manual, "Nobody picks from it, people or agents.")
    assert manual =~ "*Work Scheduled with the … runners*"
    assert manual =~ "(`scheduled_missed`)"

    assert_states(
      manual,
      "the stock **Slipdock** and **Simple** templates have one, called Scheduled, after To Do"
    )

    assert_states(
      manual,
      "the list you named, else the board's **Scheduled** list when it has one, else its ready list"
    )

    assert_states(manual, "`scheduled` for where recurring agent work lands")
  end

  test "the feature digest" do
    readme = flat("docs/manual/every-feature-in-brief.md")
    assert readme =~ "A board's **Scheduled** list (category `scheduled`"
    assert readme =~ "nobody picks from it"
  end

  test "the in-app help" do
    guides = flat("lib/slipdock_web/live/help_live/guides.ex")
    assert guides =~ "nobody picks from it"
    assert_states(guides, "Scheduled cards not started by the end of their day")

    flow = flat("lib/slipdock_web/live/help_live/flow.ex")
    assert_states(flow, "Nobody picks from it, people or agents asked what to do next.")
    assert_states(flow, "every rule working the ready list gets one beside it, for the same pool")
  end
end
