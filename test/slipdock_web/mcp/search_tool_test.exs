defmodule SlipdockWeb.MCP.SearchToolTest do
  @moduledoc "The MCP `search` tool: semantic search, scoped as the API scopes it and then by the token."
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Search}

  setup %{user: user} do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()

    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)
    other = board_fixture(%{"name" => "Elsewhere", "code" => "elsewhere"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Invoice rounding is wrong on refunds"})
    twin = card_fixture(hd(other.columns), %{"title" => "Invoice rounding again, on refunds"})

    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs"}, owner: stranger)
    secret = card_fixture(hd(theirs.columns), %{"title" => "Invoice rounding secret refunds"})

    {:ok, _} = Search.index_cards(Search.load_cards(Search.all_card_ids()))
    %{board: board, other: other, card: card, twin: twin, secret: secret}
  end

  defp search(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "search", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ids(result), do: Enum.map(result["structuredContent"]["results"], & &1["id"])

  test "finds the caller's cards and never a stranger's", ctx do
    result = search(ctx.conn, %{q: "invoice rounding refunds"})

    assert result["isError"] == false
    assert ctx.card.id in ids(result)
    assert ctx.twin.id in ids(result)
    refute ctx.secret.id in ids(result)

    hit = Enum.find(result["structuredContent"]["results"], &(&1["id"] == ctx.card.id))
    assert hit["board"] == "delivery"
    assert hit["url"] =~ "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
  end

  test "board narrows to one board", ctx do
    assert ids(search(ctx.conn, %{q: "invoice rounding refunds", board: "elsewhere"})) == [
             ctx.twin.id
           ]
  end

  test "a token scoped to one board finds nothing on the others", ctx do
    {token, _} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [ctx.board.id])
    conn = put_req_header(ctx.conn, "authorization", "Bearer " <> token)

    assert ids(search(conn, %{q: "invoice rounding refunds"})) == [ctx.card.id]
  end

  test "q is required, and kind is checked", ctx do
    assert search(ctx.conn, %{})["isError"] == true
    assert search(ctx.conn, %{q: "x", kind: "people"})["isError"] == true
  end

  test "a stranger's board is not a filter you can use", ctx do
    result = search(ctx.conn, %{q: "invoice", board: "theirs"})
    assert result["isError"] == true
  end
end
