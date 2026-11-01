defmodule SlipdockWeb.ShortNamesApiTest do
  @moduledoc "A card's short name over the JSON API and MCP."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards

  @long "Agent supervision 5/9: Parked jobs must be released on timeout"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Api names"}, owner: user)
    %{board: board, column: hd(board.columns)}
  end

  test "the API sets, reads and clears it", %{conn: conn, column: column} do
    {:ok, card} = Boards.create_card(column, %{"title" => @long})

    made = conn |> get(~p"/api/cards/#{card.id}") |> json_response(200)
    assert made["card"]["short_name"] == "Agent supervision 5-9- Parked…"
    assert made["card"]["short_name_edited"] == false

    set = conn |> patch(~p"/api/cards/#{card.id}", %{short_name: "Parked"}) |> json_response(200)
    assert set["card"]["short_name"] == "Parked"
    assert set["card"]["short_name_edited"] == true

    gone = conn |> patch(~p"/api/cards/#{card.id}", %{short_name: ""}) |> json_response(200)
    assert gone["card"]["short_name"] == "Agent supervision 5-9- Parked…"
    assert gone["card"]["short_name_edited"] == false
  end

  test "the API refuses one too long", %{conn: conn, column: column} do
    {:ok, card} = Boards.create_card(column, %{"title" => @long})

    conn
    |> patch(~p"/api/cards/#{card.id}", %{short_name: String.duplicate("x", 41)})
    |> json_response(422)
  end

  test "creating with one over the API", %{conn: conn, board: board} do
    body =
      conn
      |> post(~p"/api/boards/#{board.id}/cards", %{title: @long, short_name: "Mine"})
      |> json_response(201)

    assert body["card"]["short_name"] == "Mine"
    assert body["card"]["short_name_edited"] == true
  end

  test "MCP creates and updates with one", %{conn: conn, board: board} do
    created = mcp(conn, "create_card", %{board: board.id, title: @long, short_name: "Mine"})
    assert created =~ "Mine"

    id = created |> Jason.decode!() |> Map.fetch!("id")
    updated = mcp(conn, "update_card", %{card: id, short_name: "Yours"})
    assert updated =~ "Yours"
  end

  defp mcp(conn, tool, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
      })
    )
    |> json_response(200)
    |> get_in(["result", "content"])
    |> hd()
    |> Map.get("text")
  end
end
