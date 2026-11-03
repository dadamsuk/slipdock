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

  # Perched on the bell's shoulder, the count stood above the row and the
  # bell under it looked to hang low (#1675). It sits beside the bell now,
  # in the row, as the waiting count sits beside the hand.
  describe "the bell's count (#1675)" do
    test "sits beside the bell, in the row, not perched above it", %{
      conn: conn,
      board: board
    } do
      {:ok, _} =
        Slipdock.Automations.raise_alert(%{"board_id" => board.id, "title" => "Overdue"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      count = classes(view, "header #alerts-count")
      refute "absolute" in count
      assert "leading-5" in count

      button = classes(view, "header #alerts-bar > button")
      refute "btn-square" in button
      assert "gap-1" in button
    end

    test "with nothing to read, the bell is a square icon button like its neighbours", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(view, "header #alerts-count")
      assert "btn-square" in classes(view, "header #alerts-bar > button")
      assert "btn-square" in classes(view, "header #favourites-link")
    end
  end

  defp classes(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("class")
    |> hd()
    |> String.split()
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
