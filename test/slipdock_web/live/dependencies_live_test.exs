defmodule SlipdockWeb.DependenciesLiveTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture(%{"name" => "Deps"})
    [backlog | _] = board.columns
    a = card_fixture(backlog, %{"title" => "Ship it"})
    b = card_fixture(backlog, %{"title" => "Write tests"})
    %{board: reload(board), a: a, b: b}
  end

  test "adding and removing a dependency from the card modal", %{
    conn: conn,
    board: board,
    a: a,
    b: b
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{a.id}")
    assert render(view) =~ "Dependencies"

    view |> form("form[phx-change=dep_search]", %{"q" => "tests"}) |> render_change()

    assert has_element?(
             view,
             "button[phx-click=add_dependency][phx-value-id='#{b.id}']",
             "Write tests"
           )

    view |> element("button[phx-click=add_dependency][phx-value-id='#{b.id}']") |> render_click()
    assert Enum.map(Boards.get_card!(a.id).blocked_by, & &1.id) == [b.id]

    assert has_element?(
             view,
             "#dep-by-#{b.id} a[href='/boards/#{board.id}/cards/#{b.id}']",
             "Write tests"
           )

    # The board card behind the modal shows the blocked badge.
    assert has_element?(view, "#card-#{a.id} span[title^='Blocked by: Write tests']")
    assert has_element?(view, "#card-#{b.id} span[title^='Blocks Ship it']")

    # Now the reverse direction is a cycle and is refused with a flash.
    view
    |> element("button[phx-click=dep_direction][phx-value-direction=blocks]")
    |> render_click()

    view |> form("form[phx-change=dep_search]", %{"q" => "tests"}) |> render_change()
    refute has_element?(view, "button[phx-click=add_dependency][phx-value-id='#{b.id}']")

    view |> element("#dep-by-#{b.id} button[phx-click=remove_dependency]") |> render_click()
    assert Boards.get_card!(a.id).blocked_by == []
    refute has_element?(view, "#dep-by-#{b.id}")
  end

  test "swimlane dependencies axis renders", %{conn: conn, board: board, a: a, b: b} do
    {:ok, _} = Boards.add_dependency(a, b)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes?rows=dependencies&cols=none")
    grid = view |> element("#swim-grid") |> render()
    assert grid =~ "Blocked" and grid =~ "Blocks others"
    refute has_element?(view, "#swim-cell-0-0 button", "Add")
  end
end
