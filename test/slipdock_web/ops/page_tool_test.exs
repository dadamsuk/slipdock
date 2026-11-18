defmodule SlipdockWeb.Ops.PageToolTest do
  @moduledoc """
  `page_tool` defined once (#3188): REST's `POST /api/pages/:id/ai` and the
  MCP tool run a tool over a page alike, answer `{page, answer}`, take a
  slug with `board`, and refuse the same calls in the same words.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{AIStub, Wiki}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Tools", "code" => "pt3188"}, owner: user)
    {:ok, page} = Wiki.create_page(board, %{"title" => "Plan", "body" => "Ring the printers."})
    %{board: board, page: page}
  end

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.PageTool
    assert tool.__op__() == SlipdockWeb.Ops.PageTool
    assert tool.input_schema().required == ["page", "tool"]
    assert tool.input_schema().properties.tool.enum == Slipdock.Wiki.PageTools.names()
    assert tool.read_only?()
  end

  test "REST and MCP answer the same call with the same JSON, by code or by slug and board",
       ctx do
    AIStub.reply_with(%{"actions" => ["Ring the printers"]})

    rest =
      ctx.conn
      |> post("/api/pages/#{ctx.page.slug}/ai", %{tool: "actions", board: ctx.board.code})
      |> json_response(200)

    AIStub.reply_with(%{"actions" => ["Ring the printers"]})

    assert {false, ^rest} =
             call_mcp_tool(ctx.conn, "page_tool", %{page: ctx.page.code, tool: "actions"})

    assert rest["page"] == ctx.page.code
    assert rest["answer"]["items"] == ["Ring the printers"]
    assert Wiki.get_page!(ctx.page.id).updated_at == ctx.page.updated_at
  end

  test "an unknown tool and an empty page are refused in the same words", ctx do
    {:ok, empty} = Wiki.create_page(ctx.board, %{"title" => "Empty", "body" => ""})

    for {ref, tool, status} <- [{ctx.page.code, "x", 400}, {empty.code, "summarise", 422}] do
      %{"error" => rest} =
        ctx.conn |> post("/api/pages/#{ref}/ai", %{tool: tool}) |> json_response(status)

      assert {true, ^rest} = call_mcp_tool(ctx.conn, "page_tool", %{page: ref, tool: tool})
    end

    refute_received {:ai_request, _}
  end

  test "a page the caller can't read isn't there on either, and no model is asked", ctx do
    stranger = conn_as(user_fixture("pt3188.stranger@example.com"))

    assert stranger
           |> post("/api/pages/#{ctx.page.code}/ai", %{tool: "summarise"})
           |> json_response(404)

    assert {true, text} =
             call_mcp_tool(stranger, "page_tool", %{page: ctx.page.code, tool: "summarise"})

    assert text =~ "no page"
    refute_received {:ai_request, _}
  end
end
