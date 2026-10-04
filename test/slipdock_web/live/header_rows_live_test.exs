defmodule SlipdockWeb.HeaderRowsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup do
    %{board: board_fixture(%{"name" => "Product Launch for the Autumn Campaign"})}
  end

  test "a board's name and buttons sit in a row of their own, not the app's", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

    assert has_element?(view, "#subheader", board.name)
    refute has_element?(view, "#topbar", board.name)

    # Sharing is in the board's ... menu, not a button of its own.
    assert has_element?(view, "#subheader .dropdown #board-share", "Share this board")
    refute has_element?(view, "#subheader > div > a[title='Share this board']")

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

  test "from lg up the two rows are one: each row's box gives way to the header's", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

    assert has_element?(view, "header > #topbar.lg\\:contents")
    assert has_element?(view, "header > #subheader.lg\\:contents")
  end

  test "the mark says where it goes, and on one row the Boards crumb gives way to it", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

    assert has_element?(view, "#topbar a[href='/'][title='Boards']")
    assert has_element?(view, "#subheader nav a.lg\\:hidden[href='/']", "Boards")
  end

  test "a sub-board names its card once, as the board, not again as a crumb", %{
    conn: conn,
    board: board
  } do
    card = card_fixture(hd(board.columns), %{"title" => "Big long card title"})
    {:ok, t} = Slipdock.Boards.find_template("Simple")
    {:ok, _} = Slipdock.Boards.create_sub_board(card, t)
    sub = Slipdock.Boards.get_card!(card.id).sub_board

    {:ok, view, _html} = live(conn, ~p"/boards/#{sub}")
    html = view |> element("#subheader nav") |> render()

    # Shown once as text (the Parent card button's tooltip names it too).
    assert length(Regex.scan(~r/>\s*Big long card title\s*</, html)) == 1
    assert has_element?(view, "#subheader nav a[href='/boards/#{board.id}']", board.name)
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
