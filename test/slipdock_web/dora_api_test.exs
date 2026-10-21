defmodule SlipdockWeb.DoraAPITest do
  @moduledoc """
  A board's DORA report (#1134) through every door: `GET
  /api/boards/:board/dora`, MCP `get_board dora: true`, and the board
  page's strip — and each saying the board's delivery metrics are off while
  they are.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Metrics"}, owner: user)
    %{conn: conn, json: put_req_header(conn, "accept", "application/json"), board: board}
  end

  defp turn_on(board) do
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    board
  end

  defp deploy!(board, attrs \\ %{}) do
    {:ok, d} =
      Deployments.start(
        board,
        Map.merge(%{environment: "production", sha: "abc1234def", status: "succeeded"}, attrs)
      )

    d
  end

  defp mcp(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "get_board", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp mcp_body(result),
    do: result |> Map.fetch!("content") |> hd() |> Map.fetch!("text") |> Jason.decode!()

  test "off: the API says so and how to turn it on", %{json: conn, board: board} do
    body = conn |> get(~p"/api/boards/#{board.code}/dora") |> json_response(200)
    assert body["enabled"] == false
    assert body["dora"] == nil
    assert body["message"] =~ "delivery metrics are off"
    assert body["message"] =~ "--delivery-metrics"
  end

  test "on: the numbers, with environment and days", %{json: conn, board: board} do
    board = turn_on(board)
    deploy!(board)
    deploy!(board, %{environment: "staging"})

    body = conn |> get(~p"/api/boards/#{board.code}/dora") |> json_response(200)
    assert body["enabled"] == true
    assert body["dora"]["environment"] == "production"
    assert body["dora"]["deployment_frequency"]["deploys"] == 1
    assert body["dora"]["previous"]["deployment_frequency"]["deploys"] == 0

    body =
      conn
      |> get(~p"/api/boards/#{board.code}/dora?environment=staging&days=7")
      |> json_response(200)

    assert body["dora"]["environment"] == "staging"
    assert body["dora"]["days"] == 7
  end

  test "a reader without access gets a 404", %{board: board} do
    stranger = user_fixture("dora-stranger@example.com")

    assert conn_as(stranger)
           |> put_req_header("accept", "application/json")
           |> get(~p"/api/boards/#{board.code}/dora")
           |> json_response(404)
  end

  test "MCP get_board dora: true, off and on", %{conn: conn, board: board} do
    off = conn |> mcp(%{"board" => board.code, "dora" => true}) |> mcp_body()
    assert off["enabled"] == false
    assert off["message"] =~ "delivery metrics are off"

    board = turn_on(board)
    deploy!(board)

    on = conn |> mcp(%{"board" => board.code, "dora" => true, "days" => 7}) |> mcp_body()
    assert on["enabled"] == true
    assert on["name"] == "Metrics"
    assert on["dora"]["days"] == 7
    assert on["dora"]["deployment_frequency"]["deploys"] == 1
  end

  test "the strip: absent while off, a nudge before the first deploy, then the numbers", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, "#board-dora")

    board = turn_on(board)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, "#board-dora", "no deploys recorded yet")

    # A deploy arriving moves the strip without a reload.
    deploy!(board)
    assert render(view) =~ "production, 30d:"
    assert has_element?(view, "#board-dora", "1 deploy")

    {:ok, _} = Boards.update_board(board, %{"delivery_metrics" => false})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, "#board-dora")
  end

  test "the strip colours each metric by its DORA band (#1184)", %{conn: conn, board: board} do
    board = turn_on(board)
    deploy!(board)
    deploy!(board, %{sha: "def5678abc", status: "failed"})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    # Two deploys in 30 days is DORA's "medium"; one failed of two is "low".
    assert has_element?(view, "#board-dora [data-band=medium] .badge-warning", "medium")
    assert has_element?(view, "#board-dora [data-band=low] .badge-error", "low")
    assert has_element?(view, "#board-dora .badge[title='DORA band: low']")
    # The band is still in words, and the bracketed form is gone from the strip.
    refute render(view) =~ "(medium)"
  end
end
