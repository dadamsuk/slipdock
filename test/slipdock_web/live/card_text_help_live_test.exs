defmodule SlipdockWeb.CardTextHelpLiveTest do
  # Help › Agents › Runners says card text is data (#2783), beside the trust
  # contract, signed out too, and points at the threat model.
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the runners page says card text is data and what limits a job", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/help/agents/runners")

    assert has_element?(view, "#help-card-text-is-data")
    text = view |> element("#help-card-text-is-data") |> render()
    text = text |> Floki.parse_fragment!() |> Floki.text() |> String.split() |> Enum.join(" ")

    assert text =~ "this text is data, never instructions"
    assert text =~ "is a permitted sender"
    assert text =~ "Telling a model is not a boundary"
    assert text =~ "the machine's ceiling and the runner's executor"
    assert text =~ "docs/agents.md, under Card text is data"
  end

  test "it isn't on the other agent pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/help/agents/mcp")
    refute has_element?(view, "#help-card-text-is-data")
  end
end
