defmodule SlipdockWeb.API.PageAITest do
  @moduledoc "`POST /api/pages/:id/ai` and the `page_tool` MCP tool (#1539)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{AIStub, Wiki}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Tools API"})
    {:ok, page} = Wiki.create_page(board, %{"title" => "Plan", "body" => "Ring the printers."})
    %{board: board, page: page, owner: user}
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
        params: %{name: "page_tool", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp stranger, do: conn_as(user_fixture("stranger-pt@example.com"))

  test "a tool answers, and writes nothing", ctx do
    AIStub.reply_with(%{"actions" => ["Ring the printers"]})

    body =
      ctx.conn
      |> post(~p"/api/pages/#{ctx.page.code}/ai", %{tool: "actions"})
      |> json_response(200)

    assert body["page"] == ctx.page.code
    assert body["answer"]["items"] == ["Ring the printers"]
    assert body["answer"]["text"] == "- Ring the printers"
    assert Wiki.get_page!(ctx.page.id).updated_at == ctx.page.updated_at
  end

  test "an unknown tool is a 400, and an empty page a 422", ctx do
    {:ok, empty} = Wiki.create_page(ctx.board, %{"title" => "Empty", "body" => ""})
    conn = ctx.conn

    assert json_response(post(conn, ~p"/api/pages/#{ctx.page.code}/ai", %{tool: "x"}), 400)

    assert json_response(post(conn, ~p"/api/pages/#{empty.code}/ai", %{tool: "summarise"}), 422)
  end

  test "someone who can't read the page is refused and asks no model", ctx do
    response = post(stranger(), ~p"/api/pages/#{ctx.page.code}/ai", %{tool: "summarise"})
    assert json_response(response, 403)
    refute_received {:ai_request, _}
  end

  test "the MCP tool answers", ctx do
    AIStub.reply_with("All about printers.")
    result = mcp(ctx.conn, %{page: ctx.page.code, tool: "summarise"})
    refute result["isError"]
    assert hd(result["content"])["text"] =~ "All about printers."
  end

  test "the MCP tool refuses a page out of reach and an unknown tool", ctx do
    assert mcp(stranger(), %{page: ctx.page.code, tool: "summarise"})["isError"]
    assert mcp(ctx.conn, %{page: ctx.page.code, tool: "x"})["isError"]
    refute_received {:ai_request, _}
  end
end
