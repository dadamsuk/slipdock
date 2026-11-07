defmodule SlipdockWeb.HandbookHelpTest do
  @moduledoc """
  The in-app help lists the handbook's pages the way the README, the guide
  and the manual do, Principles and Playbook (Handbook Tool 1.5.0, #2040)
  included (SPEC-10).
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
end
