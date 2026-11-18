defmodule SlipdockWeb.Ops.RevertPageTest do
  @moduledoc """
  `revert_page` defined once (#3188): REST's `POST /api/pages/:id/revert`
  and the MCP tool put a page back alike, take `revision` and a required
  `base_hash`, answer `{page, reverted_to, revision}`, record the way it
  came in, and refuse the same calls in the same words.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{user: user} do
    board = board_fixture(%{"name" => "Revert", "code" => "rp3188"}, owner: user)
    other = user_fixture("rp3188.editor@example.com")
    page = page_fixture(board, %{"title" => "Runbook", "body" => "one"}, user: user)
    {:ok, page} = Wiki.update_page(page, %{"body" => "two"}, user: other)
    [_second, first] = Wiki.list_revisions(page)
    %{board: board, page: page, first: first, other: other}
  end

  defp hash(page), do: Wiki.get_page!(page.id).content_hash

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.RevertPage
    assert tool.__op__() == SlipdockWeb.Ops.RevertPage
    assert tool.input_schema().required == ["page", "revision", "base_hash"]
    assert tool.destructive?()
  end

  test "REST and MCP revert alike, answer {page, reverted_to, revision}, and say how", ctx do
    rest =
      ctx.conn
      |> post("/api/pages/#{ctx.page.code}/revert", %{
        revision: ctx.first.id,
        base_hash: hash(ctx.page)
      })
      |> json_response(200)

    assert rest["page"]["body"] == "one"
    assert rest["reverted_to"] == ctx.first.id
    [newest | _] = Wiki.list_revisions(ctx.page)
    assert {rest["revision"], newest.via} == {newest.id, "api"}

    {:ok, _} = Wiki.update_page(ctx.page, %{"body" => "three"}, user: ctx.other)

    {false, via_mcp} =
      call_mcp_tool(ctx.conn, "revert_page", %{
        page: "Runbook",
        board: "rp3188",
        revision: ctx.first.id,
        base_hash: hash(ctx.page)
      })

    assert Map.keys(via_mcp) == Map.keys(rest)
    assert Map.keys(via_mcp["page"]) == Map.keys(rest["page"])
    assert via_mcp["page"]["body"] == "one"
    [newest | _] = Wiki.list_revisions(ctx.page)
    assert {via_mcp["revision"], newest.via} == {newest.id, "mcp"}
  end

  test "the same refusals in the same words, and nothing changes", ctx do
    for {args, status} <- [
          {%{revision: ctx.first.id}, 400},
          {%{base_hash: hash(ctx.page)}, 400},
          {%{revision: "first", base_hash: hash(ctx.page)}, 400}
        ] do
      %{"error" => rest} =
        ctx.conn |> post("/api/pages/#{ctx.page.code}/revert", args) |> json_response(status)

      assert {true, ^rest} =
               call_mcp_tool(ctx.conn, "revert_page", Map.put(args, :page, ctx.page.code))
    end

    # REST's old revision_id: the revision is missing, said by its name.
    assert %{"error" => "revision is required"} =
             ctx.conn
             |> post("/api/pages/#{ctx.page.code}/revert", %{
               revision_id: ctx.first.id,
               base_hash: hash(ctx.page)
             })
             |> json_response(400)

    # MCP's old rev is refused, naming revision.
    assert {true, text} =
             call_mcp_tool(ctx.conn, "revert_page", %{
               page: ctx.page.code,
               rev: ctx.first.id,
               base_hash: hash(ctx.page)
             })

    assert text =~ ~s(no argument "rev") and text =~ "revision"
    assert Wiki.get_page!(ctx.page.id).body == "two"
  end

  test "a stale base_hash is a conflict on both, and the newer edit stays", ctx do
    stale = hash(ctx.page)
    {:ok, _} = Wiki.update_page(ctx.page, %{"body" => "someone's fix"}, user: ctx.other)
    args = %{revision: ctx.first.id, base_hash: stale}

    assert %{"current" => %{"content_hash" => now}} =
             ctx.conn |> post("/api/pages/#{ctx.page.code}/revert", args) |> json_response(409)

    assert {true, text} =
             call_mcp_tool(ctx.conn, "revert_page", Map.put(args, :page, ctx.page.code))

    assert text =~ "conflict" and text =~ now
    assert Wiki.get_page!(ctx.page.id).body == "someone's fix"
  end

  test "a reader of the board is refused on both", ctx do
    reader = user_fixture("rp3188.reader@example.com")
    share_fixture(ctx.board, reader, "read")
    args = %{revision: ctx.first.id, base_hash: hash(ctx.page)}

    %{"error" => rest} =
      reader
      |> conn_as()
      |> post("/api/pages/#{ctx.page.code}/revert", args)
      |> json_response(403)

    assert {true, ^rest} =
             call_mcp_tool(conn_as(reader), "revert_page", Map.put(args, :page, ctx.page.code))

    assert Wiki.get_page!(ctx.page.id).body == "two"
  end
end
