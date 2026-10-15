defmodule SlipdockWeb.BoardDefaultViewTest do
  @moduledoc """
  A board's default view: what opening it shows from the board list, the
  switcher and favourites — its wiki, its table, or the board itself. The
  view menu still reaches every view.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias SlipdockWeb.SwimlaneComponents

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)
    %{conn: conn, board: board, user: user}
  end

  defp set!(board, view) do
    {:ok, board} = Boards.update_board(board, %{"default_view" => view})
    board
  end

  describe "Board.home_view/1" do
    test "is the board until something else is chosen", %{board: board} do
      assert board.default_view == nil
      assert Board.home_view(board) == "board"
      assert Board.home_view(set!(board, "wiki")) == "wiki"
      assert Board.home_view(set!(board, "table")) == "table"
    end

    test "choosing the board stores nothing, and so does clearing it", %{board: board} do
      assert set!(board, "board").default_view == nil
      board = set!(board, "wiki")
      assert set!(board, "").default_view == nil
    end

    test "refuses a view there is no such thing as", %{board: board} do
      assert {:error, changeset} = Boards.update_board(board, %{"default_view" => "gallery"})
      assert {message, _} = changeset.errors[:default_view]
      assert message =~ "must be one of"
      assert Boards.get_board!(board.id).default_view == nil
    end

    test "a simple board falls back to the board for a view it hides", %{board: board} do
      board = set!(board, "timeline")
      assert Board.home_view(board) == "timeline"

      {:ok, board} = Boards.update_board(board, %{"simple" => true})
      assert Board.home_view(board) == "board"
      # Kept, so turning simple off brings it back.
      assert board.default_view == "timeline"
    end
  end

  test "board_home_path/1 is each view's own URL, the wiki included", %{board: board} do
    assert SwimlaneComponents.board_home_path(board) == "/boards/#{board.id}"
    assert SwimlaneComponents.board_home_path(set!(board, "wiki")) == "/boards/#{board.id}/wiki"

    assert SwimlaneComponents.board_home_path(set!(board, "swimlanes")) ==
             "/boards/#{board.id}/swimlanes"

    assert SwimlaneComponents.board_home_path(set!(board, "calendar")) ==
             "/boards/#{board.id}/calendar"
  end

  test "the board list opens it on its default view", %{conn: conn, board: board, user: user} do
    other = board_fixture(%{"name" => "Product", "code" => "product"}, owner: user)
    set!(board, "wiki")

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(a[href="/boards/#{board.id}/wiki"]))
    assert has_element?(view, ~s(a[href="/boards/#{other.id}"]))
    refute has_element?(view, ~s(a[href="/boards/#{board.id}"]))

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element(~s(a[href="/boards/#{board.id}/wiki"])) |> render_click()

    assert to == "/boards/#{board.id}/wiki"
  end

  test "the board switcher opens it on its default view", %{conn: conn, board: board} do
    set!(board, "table")

    {:ok, view, _} = live(conn, ~p"/")
    render_hook(view, "shortcut_panel", %{"panel" => "boards"})
    assert has_element?(view, ~s(a[data-shortcut][href="/boards/#{board.id}/table"]))
  end

  test "a favourite board opens on its default view, on the page and over the API", %{
    conn: conn,
    board: board,
    user: user
  } do
    {:ok, _} = Slipdock.Favourites.add(user, :board, board.id)
    set!(board, "wiki")

    {:ok, view, _} = live(conn, ~p"/favourites")
    assert has_element?(view, ~s(a[href="/boards/#{board.id}/wiki"]))

    body =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/favourites")
      |> json_response(200)

    assert Enum.any?(body["favourites"], &(&1["url"] == "/boards/#{board.id}/wiki"))
  end

  test "the board's own address still shows the board", %{conn: conn, board: board} do
    set!(board, "wiki")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, "#board-columns, [id^='column-']")
  end

  test "it is set in the board's settings, without the views a simple board hides", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    assert has_element?(view, "#board-default-view option[value=wiki]")
    assert has_element?(view, "#board-default-view option[value=timeline]")

    view |> form("#board-form", board: %{"default_view" => "wiki"}) |> render_submit()
    assert Boards.get_board!(board.id).default_view == "wiki"

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    assert has_element?(view, "#board-default-view option[value=wiki][selected]")

    {:ok, _} = Boards.update_board(Boards.get_board!(board.id), %{"simple" => true})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    refute has_element?(view, "#board-default-view option[value=timeline]")
    refute has_element?(view, "#board-default-view option[value=prioritise]")
  end

  test "a sub-board has no default view to set", %{conn: conn, board: board} do
    card = card_fixture(hd(board.columns), %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, _} = sub_board(card, t)
    sub = Boards.get_card!(card.id).sub_board

    {:ok, view, _} = live(conn, ~p"/boards/#{sub}/settings")
    refute has_element?(view, "#board-default-view")
  end

  test "the API reads and sets it, and refuses an unknown view", %{conn: conn, board: board} do
    conn = put_req_header(conn, "accept", "application/json")

    body = conn |> get(~p"/api/boards/#{board.code}") |> json_response(200)
    assert body["board"]["default_view"] == "board"

    body =
      conn
      |> patch(~p"/api/boards/#{board.code}", %{"default_view" => "wiki"})
      |> json_response(200)

    assert body["board"]["default_view"] == "wiki"

    body = conn |> get(~p"/api/boards/#{board.code}") |> json_response(200)
    assert body["board"]["default_view"] == "wiki"

    assert conn
           |> patch(~p"/api/boards/#{board.code}", %{"default_view" => "gallery"})
           |> json_response(422)

    assert Boards.get_board!(board.id).default_view == "wiki"
  end

  test "export and import carry it; an older export or a strange value means the board", %{
    board: board,
    user: user
  } do
    set!(board, "wiki")
    doc = user |> Slipdock.Portable.export() |> Jason.encode!()
    {:ok, _} = Slipdock.Portable.import(user, doc)

    copies = Slipdock.Repo.all(from b in Board, where: b.name == "Handbook" and b.id != ^board.id)
    assert [%{default_view: "wiki"}] = copies

    for value <- [:drop, "gallery"] do
      Slipdock.Repo.delete_all(from b in Board, where: b.name == "Handbook" and b.id != ^board.id)

      altered =
        doc
        |> Jason.decode!()
        |> update_in(["boards"], fn trees ->
          Enum.map(
            trees,
            &update_in(&1, ["root"], fn root ->
              if value == :drop,
                do: Map.delete(root, "default_view"),
                else: Map.put(root, "default_view", value)
            end)
          )
        end)
        |> Jason.encode!()

      {:ok, _} = Slipdock.Portable.import(user, altered)

      assert [%{default_view: nil}] =
               Slipdock.Repo.all(
                 from b in Board, where: b.name == "Handbook" and b.id != ^board.id
               )
    end
  end
end
