defmodule SlipdockWeb.HeaderRowsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup do
    %{board: board_fixture(%{"name" => "Product Launch for the Autumn Campaign"})}
  end

  test "a board's name sits in a row of its own, not the app's", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

    assert has_element?(view, "#subheader", board.name)
    refute has_element?(view, "#topbar", board.name)

    # What is the same on every page stays on the top row.
    assert has_element?(view, "header #search-link")
    assert has_element?(view, "header #quick-add-open")
    assert has_element?(view, "header #alerts-bar")
  end

  describe "the board's own buttons (#1133)" do
    test "sit in its toolbar, right of Views, and nowhere in the header", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(view, "main #board-actions #board-chat")
      # Sharing is in the board's ... menu, not a button of its own.
      assert has_element?(view, "main #board-actions .dropdown #board-share", "Share this board")
      refute has_element?(view, "header #board-actions")
      refute has_element?(view, "header #board-chat")
      refute has_element?(view, "header #board-share")

      assert_right_of_views(view)
    end

    test "follow the toolbar into the other views", %{conn: conn, board: board} do
      for mode <- ~w(table swimlanes calendar timeline outline) do
        {:ok, view, _html} = live(conn, "/boards/#{board.id}/#{mode}")

        assert has_element?(view, "main #board-actions #board-chat"), mode
        refute has_element?(view, "header #board-actions"), mode
        assert_right_of_views(view)
      end
    end

    test "leave no empty, ruled-off box behind in the header", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(view, "#subheader > div.order-4")
    end
  end

  # The board's buttons come after the Views dropdown in the toolbar's markup.
  defp assert_right_of_views(view) do
    html = render(view)
    views = :binary.match(html, ~s(title="Saved views")) |> elem(0)
    actions = :binary.match(html, ~s(id="board-actions")) |> elem(0)
    assert views < actions
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
    {:ok, t} = Slipdock.Boards.find_template(nil, "Simple")
    {:ok, _} = sub_board(card, t)
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
