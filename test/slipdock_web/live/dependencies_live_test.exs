defmodule SlipdockWeb.DependenciesLiveTest do
  use SlipdockWeb.ConnCase, async: true

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

  describe "across boards" do
    setup do
      other = board_fixture(%{"name" => "Platform", "code" => "plat"})
      foreign = card_fixture(hd(other.columns), %{"title" => "Auth service"})
      %{other: other, foreign: foreign}
    end

    test "the picker finds cards on other boards and shows their board code",
         %{conn: conn, board: board, a: a, foreign: foreign} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{a.id}")

      view |> form("form[phx-change=dep_search]", %{"q" => "auth"}) |> render_change()

      assert has_element?(
               view,
               "button[phx-click=add_dependency][phx-value-id='#{foreign.id}']",
               "plat"
             )

      view
      |> element("button[phx-click=add_dependency][phx-value-id='#{foreign.id}']")
      |> render_click()

      assert Enum.map(Boards.get_card!(a.id).blocked_by, & &1.id) == [foreign.id]

      # Listed with its board's code, linking to it on its own board.
      assert has_element?(
               view,
               "#dep-by-#{foreign.id} a[href='/boards/#{foreign.board_id}/cards/#{foreign.id}']",
               "Auth service"
             )

      assert has_element?(view, "#dep-by-#{foreign.id}", "plat")
    end

    test "a card on a board the reader can't see is shown as hidden",
         %{board: board, a: a, foreign: foreign} do
      {:ok, _} = Boards.add_dependency(a, foreign)
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      share_fixture(board, reader, "read")

      {:ok, view, html} = live(conn_as(reader), ~p"/boards/#{board}/cards/#{a.id}")

      refute html =~ "Auth service"
      assert has_element?(view, "#dep-by-#{foreign.id}", "A card you can't see")
      refute has_element?(view, "#dep-by-#{foreign.id} a")
      assert has_element?(view, "#card-#{a.id} span[title^='Blocked by: A card you can']")
    end

    test "making a card on another board wait needs write on that board",
         %{board: board, a: a, other: other, foreign: foreign} do
      writer = user_fixture("writer-#{System.unique_integer([:positive])}@example.com")
      share_fixture(board, writer, "write")
      share_fixture(other, writer, "read")

      {:ok, view, _} = live(conn_as(writer), ~p"/boards/#{board}/cards/#{a.id}")

      view
      |> element("button[phx-click=dep_direction][phx-value-direction=blocks]")
      |> render_click()

      view |> form("form[phx-change=dep_search]", %{"q" => "auth"}) |> render_change()

      view
      |> element("button[phx-click=add_dependency][phx-value-id='#{foreign.id}']")
      |> render_click()

      assert render(view) =~ "be made to wait"
      assert Boards.get_card!(foreign.id).blocked_by == []
    end
  end
end
