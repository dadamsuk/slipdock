defmodule SlipdockWeb.DeliveryMetricsSwitchTest do
  @moduledoc """
  The board's "Delivery metrics" switch (#1134): off by default, read and
  set through the API like the board's other switches, and on the board
  settings form.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Delivery"}, owner: user)
    %{json: put_req_header(conn, "accept", "application/json"), board: board}
  end

  test "off by default, then set and unset through PATCH", %{json: conn, board: board} do
    body = conn |> get(~p"/api/boards/#{board.code}") |> json_response(200)
    assert body["board"]["delivery_metrics"] == false

    body =
      conn
      |> patch(~p"/api/boards/#{board.code}", %{"delivery_metrics" => true})
      |> json_response(200)

    assert body["board"]["delivery_metrics"] == true
    assert Boards.get_board!(board.id).delivery_metrics

    conn |> patch(~p"/api/boards/#{board.code}", %{"delivery_metrics" => false})
    refute Boards.get_board!(board.id).delivery_metrics

    assert conn
           |> patch(~p"/api/boards/#{board.code}", %{"delivery_metrics" => "sometimes"})
           |> json_response(422)
  end

  test "the settings form has the switch and saves it", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}/settings")
    assert has_element?(view, "#board-delivery-metrics")
    refute has_element?(view, "#board-delivery-metrics[checked]")

    view
    |> form("#board-form", board: %{delivery_metrics: "true"})
    |> render_submit()

    assert Boards.get_board!(board.id).delivery_metrics
  end
end
