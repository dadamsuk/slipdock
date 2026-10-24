defmodule SlipdockWeb.HandbookAPITest do
  @moduledoc """
  The handbook in front of agents (#1265): `get_card` over MCP and the REST
  card carry a `handbook` key when the card's root board keeps one, and
  `GET /api/boards/:board/handbook` answers with its index.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Handbook}

  defp token_conn(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp get_card(conn, id) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "get_card", arguments: %{"card" => id}}
      })
    )
    |> json_response(200)
    |> get_in(["result", "structuredContent"])
  end

  setup %{user: user} do
    board = board_fixture(%{}, owner: user)
    [col | _] = board.columns
    card = card_fixture(col, %{"title" => "UI: a dropdown menu on the card form"})
    %{board: board, card: card}
  end

  test "without a handbook, neither payload has the key", %{user: user, card: card} do
    refute Map.has_key?(get_card(token_conn(user), card.id), "handbook")

    rest = user |> token_conn() |> get("/api/cards/#{card.id}") |> json_response(200)
    refute Map.has_key?(rest["card"], "handbook")
  end

  test "with one, MCP and REST give the same index and suggestions",
       %{user: user, board: board, card: card} do
    {:ok, _} = Handbook.install(user, board)

    mcp = get_card(token_conn(user), card.id)["handbook"]
    rest = (user |> token_conn() |> get("/api/cards/#{card.id}") |> json_response(200))["card"]

    assert mcp == rest["handbook"]
    assert mcp["board"] == board.code
    assert "UX & UI" in Enum.map(mcp["suggested"], & &1["title"])
    assert Enum.all?(mcp["index"], &Map.has_key?(&1, "read_when"))
  end

  test "a token scoped to another board doesn't get the handbook",
       %{user: user, board: board, card: card} do
    {:ok, _} = Handbook.install(user, board)
    other = board_fixture(%{}, owner: user)
    conn = token_conn(user, scope_boards: [other.id])

    assert Handbook.for_card(card, user) != nil
    assert conn |> get("/api/boards/#{board.code}/handbook") |> json_response(403)
  end

  test "GET /api/boards/:board/handbook: the index, or null", %{user: user, board: board} do
    none = user |> token_conn() |> get("/api/boards/#{board.code}/handbook") |> json_response(200)
    assert none["handbook"] == nil

    {:ok, _} = Handbook.install(user, board)
    got = user |> token_conn() |> get("/api/boards/#{board.code}/handbook") |> json_response(200)

    assert got["handbook"]["index_page"] == Handbook.find(board).index.code
    assert length(got["handbook"]["index"]) == 8
    assert got["handbook"]["decisions"] == []
  end
end
