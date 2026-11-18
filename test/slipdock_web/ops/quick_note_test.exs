defmodule SlipdockWeb.Ops.QuickNoteTest do
  @moduledoc """
  `quick_note` defined once (#3188): REST's `POST /api/notes` and the MCP
  tool save a note alike, answer `{note}`, and refuse a blank one in the
  same words (REST once said 422 to it, MCP "text is required").
  """
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.Wiki
  alias Slipdock.Wiki.KnowledgeBase

  defp notes(user) do
    case KnowledgeBase.get(user) do
      nil -> []
      kb -> kb |> Wiki.list_pages() |> Enum.map(& &1.body)
    end
  end

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.QuickNote
    assert tool.__op__() == SlipdockWeb.Ops.QuickNote
    assert tool.input_schema().required == ["text"]
    refute tool.read_only?()
  end

  test "REST (201) and MCP save a note alike and say where it went", ctx do
    Slipdock.AIStub.reply_with(%{"title" => "Printers"})
    rest = ctx.conn |> post("/api/notes", %{text: "ring them"}) |> json_response(201)
    {false, via_mcp} = call_mcp_tool(ctx.conn, "quick_note", %{text: "ring them too"})

    for answer <- [rest, via_mcp] do
      assert %{"note" => %{"location" => "/Knowledge Base", "placed_by" => _, "code" => _}} =
               answer
    end

    assert Enum.sort(notes(ctx.user)) == ["ring them", "ring them too"]
  end

  test "the way it came in is recorded from the caller: api, mcp", ctx do
    Slipdock.AIStub.reply_with(%{"title" => "Printers"})
    ctx.conn |> post("/api/notes", %{text: "by rest"}) |> json_response(201)
    {false, _} = call_mcp_tool(ctx.conn, "quick_note", %{text: "by mcp"})

    vias =
      for page <- ctx.user |> KnowledgeBase.get() |> Wiki.list_pages(),
          into: %{},
          do: {page.body, hd(Wiki.list_revisions(page, 1)).via}

    assert vias == %{"by rest" => "api", "by mcp" => "mcp"}
  end

  test "a blank or missing note is refused alike, and nothing saved", ctx do
    for args <- [%{text: "  "}, %{}] do
      %{"error" => rest} = ctx.conn |> post("/api/notes", args) |> json_response(400)
      assert rest == "text is required"
      assert {true, ^rest} = call_mcp_tool(ctx.conn, "quick_note", args)
    end

    assert notes(ctx.user) == []
  end
end
