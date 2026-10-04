defmodule SlipdockWeb.SimpleBoardTest do
  @moduledoc """
  A simple board: a plain to-do list, with the project-tracking details out
  of sight. Hidden, never deleted — turning it off brings everything back.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Swimlanes.Config

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Groceries", "code" => "groceries"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Milk", "percent_complete" => 40})
    %{conn: conn, board: board, card: card, user: user}
  end

  defp simple!(board) do
    {:ok, board} = Boards.update_board(board, %{"simple" => true})
    board
  end

  test "a board is not simple until it is made so, in its settings", %{conn: conn, board: board} do
    refute board.simple

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    assert has_element?(view, "#board-simple")

    view |> form("#board-form", board: %{"simple" => "true"}) |> render_submit()
    assert Boards.get_board!(board.id).simple

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    view |> form("#board-form", board: %{"simple" => "false"}) |> render_submit()
    refute Boards.get_board!(board.id).simple
  end

  test "the card leaves out the tracking details, and keeps the to-do ones", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")
    assert has_element?(view, "#card-percent-complete")
    assert has_element?(view, "#card-time")
    assert has_element?(view, "#card-status")
    assert has_element?(view, "[data-section-key=p]")

    simple!(board)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")

    for hidden <- ~w(#card-percent-complete #card-time #card-status #card-precision) do
      refute has_element?(view, hidden), "#{hidden} should be hidden"
    end

    refute has_element?(view, "[data-section-key=p]")
    refute has_element?(view, ~s|input[name="card[start_date]"]|)
    refute has_element?(view, "[id^=card-votes]")

    assert has_element?(view, ~s|input[name="card[due_date]"]|)
    assert has_element?(view, ~s|select[name="card[priority]"]|)
    assert has_element?(view, "#card-assignees")
    assert has_element?(view, "[data-section-key=s]")
  end

  test "tiles drop the tracking badges, and the view menu its tooling views", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, ~s|#card-#{card.id} [title="40% complete"]|)
    assert has_element?(view, ~s|#view-menu a[href="/boards/#{board.id}/timeline"]|)

    simple!(board)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, ~s|#card-#{card.id} [title="40% complete"]|)
    refute has_element?(view, ~s|#view-menu a[href="/boards/#{board.id}/timeline"]|)
    refute has_element?(view, ~s|#view-menu a[href="/boards/#{board.id}/prioritise"]|)
    assert has_element?(view, ~s|#view-menu a[href="/boards/#{board.id}/table"]|)

    # Nothing was taken off the card.
    assert Boards.get_card!(card.id).percent_complete == 40
  end

  test "the board's hidden facets never reach a saved view" do
    config = Config.hide(Config.defaults("board"), Board.technical_facets())

    refute MapSet.member?(Config.shown(config), "percent_complete")
    assert "percent_complete" in Map.fetch!(Config.to_map(config), "show")
    refute Map.has_key?(Config.to_map(config), "hidden")

    # Unticking what the chooser does show leaves the hidden ones as they were.
    changed = Config.from_form(%{"show" => ["status", "tags"]}, config)
    assert "percent_complete" in changed.show
    refute "priority" in changed.show
  end

  test "subcards made on a simple board are simple too", %{board: board, card: card} do
    simple!(board)
    template = Slipdock.Repo.one!(from t in Slipdock.Boards.Template, limit: 1)
    {:ok, sub} = Boards.create_sub_board(Boards.get_card!(card.id), template)
    assert sub.simple
  end

  test "the API reads and sets it, and says what is hidden", %{conn: conn, board: board} do
    conn = put_req_header(conn, "accept", "application/json")

    body = conn |> patch(~p"/api/boards/#{board.code}", %{"simple" => true}) |> json_response(200)
    assert body["board"]["simple"]

    body = conn |> get(~p"/api/boards/#{board.code}") |> json_response(200)
    assert body["board"]["simple"]
    assert body["board"]["hidden_facets"] == Board.technical_facets()
  end

  test "export and import carry it", %{board: board, user: user} do
    simple!(board)
    doc = user |> Slipdock.Portable.export() |> Jason.encode!()
    {:ok, _} = Slipdock.Portable.import(user, doc)

    copies =
      Slipdock.Repo.all(from b in Board, where: b.name == "Groceries" and b.id != ^board.id)

    assert [%{simple: true}] = copies
  end
end
