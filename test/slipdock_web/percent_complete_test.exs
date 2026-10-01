defmodule SlipdockWeb.PercentCompleteTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Swimlanes.Config

  setup do
    board = board_fixture(%{"name" => "Progress"})
    card = card_fixture(hd(board.columns), %{"title" => "Half done"})
    %{board: board, card: card}
  end

  test "is a whole number from 0 to 100, or nil", %{card: card} do
    assert {:ok, card} = Boards.update_card(card, %{"percent_complete" => "40"})
    assert card.percent_complete == 40
    assert {:error, cs} = Boards.update_card(card, %{"percent_complete" => 101})
    assert cs.errors[:percent_complete]
    assert {:error, _} = Boards.update_card(card, %{"percent_complete" => -1})
    assert {:ok, card} = Boards.update_card(card, %{"percent_complete" => ""})
    assert card.percent_complete == nil
  end

  test "is logged as activity", %{board: board, card: card} do
    {:ok, _} = Boards.update_card(card, %{"percent_complete" => 60})
    assert Enum.any?(Boards.list_activities(board.id), &(&1.message =~ "60% complete"))
  end

  test "the API reads and writes it", %{conn: conn, card: card} do
    conn = put_req_header(conn, "accept", "application/json")

    body =
      conn |> patch(~p"/api/cards/#{card.id}", %{"percent_complete" => 75}) |> json_response(200)

    assert body["card"]["percent_complete"] == 75

    body =
      conn |> patch(~p"/api/cards/#{card.id}", %{"percent_complete" => nil}) |> json_response(200)

    assert body["card"]["percent_complete"] == nil

    assert conn
           |> patch(~p"/api/cards/#{card.id}", %{"percent_complete" => 150})
           |> json_response(422)
  end

  test "the card sidebar sets it and the card face shows it",
       %{conn: conn, board: board, card: card} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    view |> form("#card-meta-form", card: %{percent_complete: "30"}) |> render_change()
    assert Boards.get_card!(card.id).percent_complete == 30
    assert render(view) =~ "30% complete"

    view |> form("#card-meta-form", card: %{percent_complete: ""}) |> render_change()
    assert Boards.get_card!(card.id).percent_complete == nil
  end

  test "the table shows, sorts and edits it", %{board: board, card: card} do
    other = card_fixture(hd(board.columns), %{"title" => "Nearly", "percent_complete" => 90})
    {:ok, _} = Boards.update_card(card, %{"percent_complete" => 10})

    config = %{Config.defaults("table") | sort: "percent_complete", dir: "desc"}
    [%{cards: cards}] = Slipdock.Table.rows(reload(board), config).groups
    assert Enum.map(cards, & &1.id) == [other.id, card.id]
  end
end
