defmodule SlipdockWeb.SnoozeDocsTest do
  @moduledoc """
  Snooze as the docs describe it (W-1803): the guide's model, recipe and
  board counts, the manual's section the others link to (with quick add's
  `snooze:` and the `z` key), README, docs/agents.md, /help and /help/agents,
  the keyboard sheet, and the slipdock and slipdock-work skills.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the guide has the field, the recipe and the counts; MCP's update_card names it" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "**Snoozed cards** — a card can be hidden until a day"
    assert guide =~ "**Snoozing a card.** `POST /api/cards/:id/snooze`"
    assert guide =~ "`GET /api/boards/:board/cards?snoozed=only`"
    assert guide =~ ~s("snoozed_until": null, "snooze": null)
    assert guide =~ "Snoozed cards are not in it"
    assert SlipdockWeb.APIGuide.short() =~ "the checklist, recurrence, snooze"
  end

  test "the manual has the section, quick add's snooze:, the z key and the commands" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## Snoozing cards$/m
    assert manual =~ "[Snoozing cards](#snoozing-cards)"
    assert manual =~ "`snooze: mon`, `snooze: next week`"
    assert manual =~ "- `z` — **snooze** the card"
    assert manual =~ "slipdock snooze 12 next week"
    assert manual =~ "POST   /api/cards/:id/snooze"
    assert manual =~ "(`card_woken`)"
    assert manual =~ "a snoozed subcard still counts as open"
  end

  test "README and docs/agents.md link to it" do
    assert read("README.md") =~ "docs/manual.md#snoozing-cards"
    agents = read("docs/agents.md")
    assert agents =~ "manual.md#snoozing-cards"
    assert agents =~ "snooze it rather than flag it `waiting`"
  end

  test "both copies of the skills have it: commands, when to snooze, never pick one" do
    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ "slipdock snooze <id>... <when> [--note T] [--notify]"
    assert skill =~ "slipdock wake <id>..."
    assert skill =~ "--snoozed include"
    assert skill =~ "Never pick a snoozed card to work on"

    work = read("priv/skills/slipdock-work/SKILL.md")
    assert work =~ "blocked, waiting, snoozed, or assigned to someone else"
    assert work =~ "when what it waits for has a date, snooze it instead"
  end

  test "the keyboard sheet lists z" do
    keys =
      SlipdockWeb.Shortcuts.sections() |> Enum.flat_map(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

    assert Enum.count(keys, &(&1 == "z")) == 2
  end

  test "/help and /help/agents describe it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/boards")
    assert html =~ "<strong>Snooze</strong>"
    assert html =~ "snooze: mon"

    {:ok, _view, html} = live(conn, ~p"/help/agents")
    assert html =~ "Snooze a card until a day, or wake it"

    {:ok, _view, html} = live(conn, ~p"/help/agents/mcp")
    assert html =~ "snoozed_until"
  end
end
