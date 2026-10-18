defmodule SlipdockWeb.RecurrenceDocsTest do
  @moduledoc """
  Recurring cards as the docs describe them (W-1802): the guide's model and
  recipe, the manual's section the others link to (with quick add's
  `every:`), README, docs/agents.md, /help and /help/agents, and the
  slipdock skill.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the guide has the field, the copy endpoint and the recipe; MCP's update_card names it" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "**Recurring cards** — a card can repeat"
    assert guide =~ "`POST /api/cards/:id/copy`"
    assert guide =~ "**A recurring card.** `PUT /api/cards/:id/recurrence`"
    assert guide =~ "`GET /api/boards/:board/recurring`"
    assert guide =~ ~s("recurrence": null, "series_id": null)
    assert SlipdockWeb.APIGuide.short() =~ "dependencies, the checklist, recurrence"
  end

  test "the manual has the section, quick add's every: and the commands" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## Recurring cards$/m
    assert manual =~ "`every: mon`, `every: weekday`"
    assert manual =~ "slipdock repeat 12 \"every mon\""
    assert manual =~ "PUT    /api/cards/:id/recurrence"
    assert manual =~ "**Not stacking up.**"
    assert manual =~ "falls on that month's last day"
    assert manual =~ "**Duplicate.**"
  end

  test "README and docs/agents.md link to it" do
    assert read("README.md") =~ "docs/manual.md#recurring-cards"
    assert read("docs/agents.md") =~ "manual.md#recurring-cards"
  end

  test "the slipdock skill has repeat, recurring and copy" do
    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ ~s(slipdock repeat <id> "every mon")
    assert skill =~ "slipdock recurring <board>"
    assert skill =~ "slipdock copy <id>"
    assert skill =~ "Remind me to review invoices every Monday"
  end

  test "/help and /help/agents describe it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/boards")
    assert html =~ "Recurring cards"
    assert html =~ "every: mon"

    {:ok, _view, html} = live(conn, ~p"/help/agents")
    assert html =~ "Make a card recurring, skip or stop one"

    {:ok, _view, html} = live(conn, ~p"/help/agents/mcp")
    assert html =~ "making a card repeat"
  end
end
