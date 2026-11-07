defmodule SlipdockWeb.HandbookHelpTest do
  @moduledoc """
  The in-app help lists the handbook's pages the way the README, the guide
  and the manual do, Principles and Playbook (Handbook Tool 1.5.0, #2040)
  included (SPEC-10), and says what those two are for (#2041).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "/help/agents/skills names Principles and Playbook among the handbook's pages",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
    text = html |> Floki.parse_document!() |> Floki.text() |> String.replace(~r/\s+/, " ")

    assert text =~
             "shared modules, testing, operations, principles (the tie-breakers, each a PRIN rule) and the playbook (how an idea becomes cards on the board)"
  end

  test "/help/tools says what Principles and Playbook are for, and that editing them changes the process (#2041)",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/tools")
    text = html |> Floki.parse_document!() |> Floki.text() |> String.replace(~r/\s+/, " ")

    assert text =~ "How your board plans: Principles and Playbook"
    assert text =~ "Principles are the tie-breakers"
    assert text =~ "it sizes the ask as a card, a feature or a system"
    assert text =~ "A one-sentence ask stays one card."
    assert text =~ "Editing these two pages is how a board changes its process"
    assert text =~ "never touches one you've edited"
  end
end
