defmodule SlipdockWeb.CloseOnCompleteLiveTest do
  @moduledoc """
  The board setting `close_on_complete` (#3473): with it on, completing an
  open card from its panel's Complete icon closes the card and returns to
  the board. Off, marking a card incomplete, or a tile's icon: the page
  stays as it is.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}

  @panel_toggle "#card-title-form [data-role=complete-toggle]"

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Ship it"})
    %{board: board, card: card}
  end

  defp close_on_complete(board, on) do
    {:ok, board} = Boards.update_board(board, %{"close_on_complete" => on})
    board
  end

  defp open(conn, board, card), do: live(conn, ~p"/boards/#{board}/cards/#{card.id}")

  test "is off for a new board", %{board: board} do
    refute Boards.get_board!(board.id).close_on_complete
  end

  test "on: completing the open card closes it and returns to the board", ctx do
    board = close_on_complete(ctx.board, true)
    {:ok, view, _} = open(ctx.conn, board, ctx.card)
    assert has_element?(view, "#card-modal")

    view |> element(@panel_toggle) |> render_click()

    assert Boards.Cards.get_card!(ctx.card.id).completed
    assert_patch(view, ~p"/boards/#{board}")
    refute has_element?(view, "#card-modal")
  end

  test "on: a card-only user completing the open card is sent off the board", ctx do
    board = close_on_complete(ctx.board, true)
    guest = user_fixture("guest@example.com")
    {:ok, _} = Access.grant(ctx.card, guest, "write", ctx.user)
    assert Access.board_permission(guest, board) == :none

    {:ok, view, _} = open(log_in_user(build_conn(), guest), board, ctx.card)
    assert has_element?(view, "#card-modal")

    view |> element(@panel_toggle) |> render_click()

    assert Boards.Cards.get_card!(ctx.card.id).completed
    assert_redirect(view, ~p"/")
  end

  test "off: completing the open card leaves it open", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.card)

    view |> element(@panel_toggle) |> render_click()

    assert Boards.Cards.get_card!(ctx.card.id).completed
    assert has_element?(view, "#card-modal")
    assert has_element?(view, ~s(#{@panel_toggle}[aria-label="Mark incomplete"]))
  end

  test "on: marking a done card incomplete again leaves it open", ctx do
    board = close_on_complete(ctx.board, true)
    {:ok, _} = Boards.Cards.update_card(ctx.card, %{"completed" => true})
    {:ok, view, _} = open(ctx.conn, board, ctx.card)

    view |> element(@panel_toggle) |> render_click()

    refute Boards.Cards.get_card!(ctx.card.id).completed
    assert has_element?(view, "#card-modal")
  end

  test "on: the open card's own tile icon completes it without closing it", ctx do
    board = close_on_complete(ctx.board, true)
    {:ok, view, _} = open(ctx.conn, board, ctx.card)

    view |> element("#card-#{ctx.card.id} [data-role=complete-toggle]") |> render_click()

    assert Boards.Cards.get_card!(ctx.card.id).completed
    assert has_element?(view, "#card-modal")
  end

  test "the Features tab turns it on", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=features")
    assert has_element?(view, "#settings-panel-features #board-close-on-complete")

    view
    |> form("#board-form", board: %{close_on_complete: "true"})
    |> render_submit()

    assert Boards.get_board!(board.id).close_on_complete
  end

  test "the API reads and sets it", %{conn: conn, board: board} do
    conn = put_req_header(conn, "accept", "application/json")

    body = conn |> get(~p"/api/boards/#{board.code}") |> json_response(200)
    assert body["board"]["close_on_complete"] == false

    body =
      conn
      |> patch(~p"/api/boards/#{board.code}", %{"close_on_complete" => true})
      |> json_response(200)

    assert body["board"]["close_on_complete"] == true
    assert Boards.get_board!(board.id).close_on_complete
  end
end
