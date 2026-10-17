defmodule SlipdockWeb.MCP.SearchToolTest do
  @moduledoc "The MCP `search` tool: semantic search, scoped as the API scopes it and then by the token."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Search}

  setup %{user: user} do
    Slipdock.AIStub.stub_embeddings()

    board = board_fixture(%{"name" => "Delivery", "code" => "delivery8"}, owner: user)
    other = board_fixture(%{"name" => "Elsewhere", "code" => "elsewhere3"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Invoice rounding is wrong on refunds"})
    twin = card_fixture(hd(other.columns), %{"title" => "Invoice rounding again, on refunds"})

    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs5"}, owner: stranger)
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

  test "says what the excerpt is from, and links straight to it", ctx do
    {:ok, comment} =
      Slipdock.Boards.add_comment(ctx.card, "the refunds rounding is off by a penny")

    {:ok, _} = Search.index_card(ctx.card.id)

    result = search(ctx.conn, %{q: "refunds rounding off by a penny"})
    hit = Enum.find(result["structuredContent"]["results"], &(&1["id"] == ctx.card.id))

    assert hit["matched"] in ["comment", "card"]

    case hit["matched"] do
      "comment" -> assert hit["match_url"] =~ "/cards/#{ctx.card.id}?at=comment-#{comment.id}"
      "card" -> assert hit["match_url"] == hit["url"]
    end
  end

  test "finds the caller's cards and never a stranger's", ctx do
    result = search(ctx.conn, %{q: "invoice rounding refunds"})

    assert result["isError"] == false
    assert ctx.card.id in ids(result)
    assert ctx.twin.id in ids(result)
    refute ctx.secret.id in ids(result)

    hit = Enum.find(result["structuredContent"]["results"], &(&1["id"] == ctx.card.id))
    assert hit["board"] == "delivery8"
    assert hit["url"] =~ "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
  end

  test "archived cards come back only with archived: true, and say so", ctx do
    {:ok, _} = Slipdock.Boards.archive_card(ctx.card)
    {:ok, _} = Search.index_card(ctx.card.id)

    refute ctx.card.id in ids(search(ctx.conn, %{q: "invoice rounding refunds"}))

    result = search(ctx.conn, %{q: "invoice rounding refunds", archived: true})
    hit = Enum.find(result["structuredContent"]["results"], &(&1["id"] == ctx.card.id))
    assert hit["archived"] == true

    assert Enum.find(result["structuredContent"]["results"], &(&1["id"] == ctx.twin.id))[
             "archived"
           ] == false
  end

  test "a card's link finds that card, archived or not; a stranger's finds nothing", ctx do
    {:ok, _} = Slipdock.Boards.archive_card(ctx.card)

    assert ids(
             search(ctx.conn, %{
               q: "https://app.slipdock.us/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
             })
           ) ==
             [ctx.card.id]

    assert ids(search(ctx.conn, %{q: "/boards/#{ctx.board.id}/cards/#{ctx.secret.id}"})) == []
  end

  test "board narrows to one board", ctx do
    assert ids(search(ctx.conn, %{q: "invoice rounding refunds", board: "elsewhere3"})) == [
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
    result = search(ctx.conn, %{q: "invoice", board: "theirs5"})
    assert result["isError"] == true
  end
end
