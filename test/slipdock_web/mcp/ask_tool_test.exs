defmodule SlipdockWeb.MCP.AskToolTest do
  @moduledoc "The MCP `ask` tool: `POST /api/ask` as a tool, scoped as it is."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Search}

  setup %{user: user} do
    Slipdock.AIStub.stub_embeddings()

    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Invoice rounding is wrong on refunds"})
    {:ok, _} = Search.index_cards(Search.load_cards(Search.all_card_ids()))

    %{board: board, card: card}
  end

  defp ask(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "ask", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp error_text(result) do
    assert result["isError"] == true
    hd(result["content"])["text"]
  end

  defp system_prompt do
    assert_receive {:ai_request,
                    %{"messages" => [%{"role" => "system", "content" => system} | _]}}

    system
  end

  test "is listed, read-only, and says it costs a model call", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    tool = Enum.find(tools, &(&1["name"] == "ask"))
    assert tool["annotations"]["readOnlyHint"] == true
    assert tool["inputSchema"]["required"] == ["question"]
    assert tool["description"] =~ "model call"
    assert tool["description"] =~ "take a while"
  end

  test "answers in prose, with the cards it read", ctx do
    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"search_cards", %{"query" => "invoice rounding"}}]},
      "Finance are waiting on the refund rounding card."
    ])

    result = ask(ctx.conn, %{question: "What's happening with refunds?"})

    assert result["isError"] == false
    data = result["structuredContent"]
    assert data["question"] == "What's happening with refunds?"
    assert data["answer"] =~ "Finance are waiting"
    assert [source] = data["sources"]
    assert source["kind"] == "card"
    assert source["id"] == ctx.card.id
    assert source["title"] == ctx.card.title
    assert source["url"] =~ "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
  end

  test "a page it read comes back as a page", ctx do
    page =
      page_fixture(
        ctx.board,
        %{"title" => "Refunds runbook", "body" => "How refunds are rounded."}, user: ctx.user)

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"read_page", %{"page" => page.code}}]},
      "The runbook says how."
    ])

    data = ask(ctx.conn, %{question: "How are refunds rounded?"})["structuredContent"]

    assert [%{"kind" => "page", "id" => id, "code" => code, "title" => "Refunds runbook"}] =
             data["sources"]

    assert id == page.id
    assert code == page.code
  end

  test "board keeps the model to that board", ctx do
    Slipdock.AIStub.reply_with("Nothing much.")

    assert ask(ctx.conn, %{question: "What's going on?", board: "delivery"})["isError"] == false
    assert system_prompt() =~ ~s[about the board "Delivery" (code `delivery`)]
  end

  test "without a board the model is not told about one", ctx do
    Slipdock.AIStub.reply_with("Nothing much.")

    assert ask(ctx.conn, %{question: "What's going on?"})["isError"] == false
    refute system_prompt() =~ "This question is about the board"
  end

  test "a board the caller cannot see is refused before any model call", ctx do
    stranger = user_fixture("stranger@example.com")
    board_fixture(%{"name" => "Theirs", "code" => "theirs"}, owner: stranger)
    Slipdock.AIStub.reply_with("should not be asked")

    assert error_text(ask(ctx.conn, %{question: "anything", board: "theirs"})) =~
             "no board you can see"

    refute_receive {:ai_request, _}
  end

  test "question is required", ctx do
    assert error_text(ask(ctx.conn, %{})) =~ "question"
    assert error_text(ask(ctx.conn, %{question: "  "})) =~ "question"
  end

  test "a token confined to some boards is refused, as /api/ask refuses it", ctx do
    {token, _} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [ctx.board.id])
    Slipdock.AIStub.reply_with("should not be asked")

    scoped = put_req_header(build_conn(), "authorization", "Bearer " <> token)

    assert error_text(ask(scoped, %{question: "anything", board: "delivery"})) =~
             "confined to some"

    refute_receive {:ai_request, _}
  end

  test "a read-only token may ask", ctx do
    {token, _} = Accounts.create_api_token(ctx.user, "reader", scope: "read")
    Slipdock.AIStub.reply_with("Read-only is fine.")

    reader = put_req_header(build_conn(), "authorization", "Bearer " <> token)
    assert ask(reader, %{question: "anything"})["structuredContent"]["answer"] =~ "fine"
  end

  test "a model failure comes back as a tool error", ctx do
    Slipdock.AIStub.fail_with(429, "slow down")

    assert error_text(ask(ctx.conn, %{question: "anything"})) =~ "rate-limited"
  end
end
