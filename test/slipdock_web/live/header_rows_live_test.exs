defmodule SlipdockWeb.HeaderRowsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup do
    %{board: board_fixture(%{"name" => "Product Launch for the Autumn Campaign"})}
  end

  test "a board's name and buttons sit on a second row, not the app's header", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

    assert has_element?(view, "#subheader", board.name)
    refute has_element?(view, "header", board.name)
    assert has_element?(view, "#subheader a[title='Share this board']")

    # What is the same on every page stays on the top row.
    assert has_element?(view, "header #search-link")
    assert has_element?(view, "header #quick-add-open")
    assert has_element?(view, "header #alerts-bar")
  end

  test "the wiki puts its board and its New page button on the second row", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    assert has_element?(view, "#subheader", board.name)
    assert has_element?(view, "#subheader", "New page")
  end

  test "pages that are not about a board keep one row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/account")

    refute has_element?(view, "#subheader")
  end

  test "signed in, the header carries the mark but not the wordmark", %{conn: conn, board: board} do
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}")

    refute html =~ "wordmark"
  end
end
