defmodule SlipdockWeb.FlowAPITest do
  @moduledoc """
  A board's flow history (#1186) through the doors agents use: `GET
  /api/boards/:board/flow?days=` and MCP `get_board` with `history: true`
  give the same series, and a board the caller can't read is refused.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Stream"}, owner: user)
    [_backlog, todo, doing, done] = board.columns

    card = card_fixture(todo, %{"title" => "Shipped"})
    :ok = Boards.move_card(card.id, doing.id, nil, actor: Actor.web(user))
    :ok = Boards.move_card(card.id, done.id, nil, actor: Actor.web(user))
    card_fixture(todo, %{"title" => "Waiting"})

    conn = put_req_header(conn, "accept", "application/json")
    %{conn: conn, board: board}
  end

  defp rest(conn, board, query \\ ""),
    do: conn |> get("/api/boards/#{board.code}/flow#{query}") |> json_response(200)

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

  test "REST gives a day per entry in the window, today last", %{conn: conn, board: board} do
    body = rest(conn, board, "?days=7")
    assert body["board"] == %{"id" => board.id, "code" => board.code}

    flow = body["flow"]
    assert flow["days"] == 7
    assert length(flow["series"]) == 7

    today = List.last(flow["series"])

    assert %{"ready" => 1, "doing" => 0, "done" => 1, "completed" => 1, "added" => 2, "open" => 1} =
             today

    assert [%{"title" => "Shipped", "cycle_seconds" => secs}] = flow["finished"]
    assert is_integer(secs)
    assert Map.keys(flow["cycle"]) |> Enum.sort() == ["cards", "p50", "p85"]
  end

  test "days defaults to 30 and is held to 7, 30 or 90", %{conn: conn, board: board} do
    assert rest(conn, board)["flow"]["days"] == 30
    assert rest(conn, board, "?days=60")["flow"]["days"] == 90
    assert rest(conn, board, "?days=soon")["flow"]["days"] == 30
  end

  test "MCP get_board history:true gives the same series", %{conn: conn, board: board} do
    series = rest(conn, board, "?days=7")["flow"]["series"]

    result = mcp(conn, %{board: board.code, history: true, days: 7})
    assert result["isError"] == false, inspect(result["content"])
    content = result["structuredContent"]
    assert content["code"] == board.code
    refute Map.has_key?(content, "lists")
    assert content["flow"]["series"] == series
  end

  test "a board the caller can't read is refused, on both doors", %{conn: conn} do
    theirs = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("other@example.com"))

    assert conn |> get("/api/boards/#{theirs.code}/flow") |> json_response(404)
    assert mcp(conn, %{board: theirs.code, history: true})["isError"] == true
  end
end
