defmodule SlipdockWeb.Ops.PageHistoryTest do
  @moduledoc """
  `page_history` defined once (#3188): REST's `GET /api/pages/:id/revisions`
  (and `…/revisions/:rev`, the same definition with `rev` from the path)
  and the MCP tool answer the same call alike: `{page, revisions}`, or one
  revision `{page, revision, diff}` with `diff` REST's (`previous` or an
  id), and refuse the same calls in the same words.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{user: user} do
    board = board_fixture(%{"name" => "History", "code" => "ph3188"}, owner: user)
    other = user_fixture("ph3188.editor@example.com")
    page = page_fixture(board, %{"title" => "Runbook", "body" => "one"}, user: user)
    {:ok, page} = Wiki.update_page(page, %{"body" => "one\ntwo"}, user: other, message: "add")
    [second, first] = Wiki.list_revisions(page)
    %{board: board, page: page, first: first, second: second, other: other}
  end

  defp rest(conn, path, query \\ %{}), do: get(conn, "/api/pages/" <> path, query)

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.PageHistory
    assert tool.__op__() == SlipdockWeb.Ops.PageHistory
    assert tool.input_schema().required == ["page"]
    assert tool.read_only?()
    refute Map.has_key?(tool.input_schema().properties, :against)
  end

  test "the list is the same on both: the page (with its hash) and the revisions", ctx do
    list = ctx.conn |> rest("#{ctx.page.code}/revisions") |> json_response(200)
    assert {false, ^list} = call_mcp_tool(ctx.conn, "page_history", %{page: ctx.page.code})

    assert list["page"]["content_hash"] == Wiki.get_page!(ctx.page.id).content_hash
    assert Enum.map(list["revisions"], & &1["id"]) == [ctx.second.id, ctx.first.id]
    assert hd(list["revisions"])["author"]["email"] == ctx.other.email

    # By title with its board, and limited, alike too.
    args = %{page: "Runbook", board: "ph3188", limit: 1}
    one = ctx.conn |> rest("Runbook/revisions", args) |> json_response(200)
    assert {false, ^one} = call_mcp_tool(ctx.conn, "page_history", args)
    assert [%{"id" => id}] = one["revisions"]
    assert id == ctx.second.id
  end

  test "one revision on REST's path route is MCP's rev, diff and all", ctx do
    path = "#{ctx.page.code}/revisions/#{ctx.second.id}"
    args = %{page: ctx.page.code, rev: ctx.second.id}

    bare = ctx.conn |> rest(path) |> json_response(200)
    assert {false, ^bare} = call_mcp_tool(ctx.conn, "page_history", args)
    assert bare["revision"]["body"] == "one\ntwo"
    refute Map.has_key?(bare, "diff")

    for diff <- ["previous", ctx.first.id] do
      changed = ctx.conn |> rest(path, %{diff: diff}) |> json_response(200)

      assert {false, ^changed} =
               call_mcp_tool(ctx.conn, "page_history", Map.put(args, :diff, diff))

      assert changed["diff"] == [
               %{"op" => "eq", "lines" => ["one"]},
               %{"op" => "ins", "lines" => ["two"]}
             ]
    end

    # diff without rev: the latest save's change.
    latest =
      ctx.conn |> rest("#{ctx.page.code}/revisions", %{diff: "previous"}) |> json_response(200)

    assert latest == ctx.conn |> rest(path, %{diff: "previous"}) |> json_response(200)
  end

  test "the same refusals in the same words", ctx do
    elsewhere = page_fixture(ctx.board, %{"title" => "Elsewhere"}, user: ctx.user)
    [foreign] = Wiki.list_revisions(elsewhere)

    for {query, status} <- [
          {%{limit: 0}, 400},
          {%{rev: "latest"}, 400},
          {%{rev: ctx.second.id, diff: "junk"}, 400}
        ] do
      %{"error" => rest} =
        ctx.conn |> rest("#{ctx.page.code}/revisions", query) |> json_response(status)

      assert {true, ^rest} =
               call_mcp_tool(ctx.conn, "page_history", Map.put(query, :page, ctx.page.code))
    end

    # Another page's revision, on either side of the diff, isn't this page's.
    for query <- [%{rev: foreign.id}, %{rev: ctx.second.id, diff: foreign.id}] do
      assert ctx.conn |> rest("#{ctx.page.code}/revisions", query) |> json_response(404)

      assert {true, text} =
               call_mcp_tool(ctx.conn, "page_history", Map.put(query, :page, ctx.page.code))

      assert text =~ "no revision"
    end
  end

  test "a stranger's page isn't there on either", ctx do
    stranger = conn_as(user_fixture("ph3188.stranger@example.com"))
    assert stranger |> rest("#{ctx.page.code}/revisions") |> json_response(404)
    assert {true, text} = call_mcp_tool(stranger, "page_history", %{page: ctx.page.code})
    assert text =~ "no page"
  end
end
