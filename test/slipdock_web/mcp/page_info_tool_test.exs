defmodule SlipdockWeb.MCP.PageInfoToolTest do
  @moduledoc """
  `page_info`: finding the way round a wiki over MCP — a page's links and
  heading paths, a board's wanted pages, and whether a title already has a
  page — with drafts and other people's boards kept out of sight.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)

    install = page_fixture(board, %{"title" => "Install"}, user: user)

    guide =
      page_fixture(
        board,
        %{
          "title" => "Guide",
          "body" => """
          # Guide

          Start with [[Install]], then read [[Rollback plan]].

          ## Deploy

          ### Rollback

          Undo it.

          ## Support
          """
        },
        user: user
      )

    lonely = page_fixture(board, %{"title" => "Lonely", "body" => "No links here."}, user: user)

    %{conn: conn, board: board, guide: guide, install: install, lonely: lonely}
  end

  defp call(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "page_info", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ok!(result) do
    assert result["isError"] == false, inspect(result["content"])
    result["structuredContent"]
  end

  defp error!(result) do
    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    text
  end

  defp reader(board) do
    reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
    share_fixture(board, reader, "read")
    conn_as(reader)
  end

  test "tools/list offers it as a read-only tool", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    tool = Enum.find(tools, &(&1["name"] == "page_info"))
    assert tool["annotations"]["readOnlyHint"] == true
    assert tool["inputSchema"]["properties"]["what"]["enum"] == ~w(links sections wanted resolve)
    assert String.length(tool["description"]) < 250
  end

  describe "what" do
    test "is required", ctx do
      assert ctx.conn |> call(%{page: ctx.guide.code}) |> error!() =~ "what is required"
    end

    test "must be one of the four", ctx do
      assert ctx.conn |> call(%{what: "history", page: ctx.guide.code}) |> error!() =~
               "links, sections, wanted or resolve"
    end
  end

  describe "links" do
    test "outgoing, unresolved and incoming", ctx do
      result = ctx.conn |> call(%{what: "links", page: ctx.guide.code}) |> ok!()

      assert result["page"]["code"] == ctx.guide.code
      assert result["page"]["url"] =~ "/boards/#{ctx.board.id}/wiki/"
      assert [%{"raw" => "[[Install]]", "resolved" => true} = out] = result["outgoing"]
      assert out["target"]["code"] == ctx.install.code
      assert [%{"raw" => "[[Rollback plan]]", "resolved" => false}] = result["unresolved"]
      assert result["incoming"] == []

      install = ctx.conn |> call(%{what: "links", page: ctx.install.code}) |> ok!()
      assert [%{"page" => %{"code" => code}, "count" => 1}] = install["incoming"]
      assert code == ctx.guide.code
    end

    test "a page with no links has three empty lists", ctx do
      result = ctx.conn |> call(%{what: "links", page: ctx.lonely.code}) |> ok!()
      assert result["outgoing"] == []
      assert result["unresolved"] == []
      assert result["incoming"] == []
    end

    test "a page named by title on a board", ctx do
      result = ctx.conn |> call(%{what: "links", page: "Install", board: "delivery"}) |> ok!()
      assert result["page"]["code"] == ctx.install.code
    end

    test "page is required", ctx do
      assert ctx.conn |> call(%{what: "links"}) |> error!() =~ "page is required"
    end

    test "an unknown page", ctx do
      assert ctx.conn |> call(%{what: "links", page: "W-99999"}) |> error!() =~ "no page"

      assert ctx.conn |> call(%{what: "links", page: "Nope", board: "delivery"}) |> error!() =~
               "no page"
    end

    test "a draft linking in is not shown to a reader", ctx do
      page_fixture(ctx.board, %{
        "title" => "Secret draft",
        "status" => "draft",
        "body" => "[[Install]]"
      })

      owner = ctx.conn |> call(%{what: "links", page: ctx.install.code}) |> ok!()
      assert length(owner["incoming"]) == 2

      seen = ctx.board |> reader() |> call(%{what: "links", page: ctx.install.code}) |> ok!()
      assert [%{"page" => %{"title" => "Guide"}}] = seen["incoming"]
    end

    test "a draft itself is not there to a reader", ctx do
      draft = page_fixture(ctx.board, %{"title" => "Draft", "status" => "draft"})

      assert ctx.board |> reader() |> call(%{what: "links", page: draft.code}) |> error!() =~
               "no page"
    end
  end

  describe "sections" do
    test "heading paths, nesting included", ctx do
      result = ctx.conn |> call(%{what: "sections", page: ctx.guide.code}) |> ok!()

      assert result["sections"] == [
               %{"path" => "Guide", "title" => "Guide", "level" => 1},
               %{"path" => "Guide/Deploy", "title" => "Deploy", "level" => 2},
               %{"path" => "Guide/Deploy/Rollback", "title" => "Rollback", "level" => 3},
               %{"path" => "Guide/Support", "title" => "Support", "level" => 2}
             ]
    end

    test "the paths are the ones write_page's section modes accept", ctx do
      %{"sections" => sections} =
        ctx.conn |> call(%{what: "sections", page: ctx.guide.code}) |> ok!()

      path = Enum.find_value(sections, &(&1["title"] == "Rollback" && &1["path"]))
      assert {:ok, text} = Wiki.read_section(ctx.guide, path)
      assert text =~ "Undo it."
    end

    test "a page with no headings has none", ctx do
      assert ctx.conn
             |> call(%{what: "sections", page: ctx.lonely.code})
             |> ok!()
             |> Map.get("sections") ==
               []
    end

    test "an unknown page", ctx do
      assert ctx.conn |> call(%{what: "sections", page: "W-99999"}) |> error!() =~ "no page"
    end
  end

  describe "wanted" do
    test "pages linked to but never written, and who wants them", ctx do
      result = ctx.conn |> call(%{what: "wanted", board: "delivery"}) |> ok!()

      assert result["board"]["code"] == "delivery"
      assert [want] = result["wanted"]
      assert want["title"] == "Rollback plan"
      assert want["count"] == 1
      assert [%{"code" => code}] = want["from"]
      assert code == ctx.guide.code
    end

    test "a board with nothing wanted", %{user: user, conn: conn} do
      board_fixture(%{"name" => "Empty", "code" => "empty"}, owner: user)
      assert conn |> call(%{what: "wanted", board: "empty"}) |> ok!() |> Map.get("wanted") == []
    end

    test "a want only a draft has is not shown to a reader", ctx do
      page_fixture(ctx.board, %{
        "title" => "Draft",
        "status" => "draft",
        "body" => "[[Secret plan]]"
      })

      titles = fn conn ->
        conn
        |> call(%{what: "wanted", board: "delivery"})
        |> ok!()
        |> Map.get("wanted")
        |> Enum.map(& &1["title"])
      end

      assert "Secret plan" in titles.(ctx.conn)
      assert titles.(reader(ctx.board)) == ["Rollback plan"]
    end

    test "board is required", ctx do
      assert ctx.conn |> call(%{what: "wanted"}) |> error!() =~ "board is required"
    end

    test "another tenant's board reads as not there", ctx do
      other = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Private", "code" => "private"}, owner: other)
      page_fixture(theirs, %{"title" => "Theirs", "body" => "[[Their secret]]"}, user: other)

      text = ctx.conn |> call(%{what: "wanted", board: theirs.id}) |> error!()
      assert text =~ "no board"
      refute text =~ "Their secret"
    end
  end

  describe "resolve" do
    test "a title with a page says so, and how to link it", ctx do
      result = ctx.conn |> call(%{what: "resolve", board: "delivery", title: "install"}) |> ok!()

      assert result["found"] == true
      assert result["page"]["code"] == ctx.install.code
      assert result["write_as"] == "[[Install]]"
    end

    test "a title with no page offers what is near", ctx do
      result = ctx.conn |> call(%{what: "resolve", board: "delivery", title: "Guid"}) |> ok!()

      assert result["found"] == false
      assert [%{"title" => "Guide"}] = result["near"]
      assert result["write_as"] == "[[Guid]]"
      assert result["note"] =~ "wanted page"
    end

    test "a draft is neither found nor near for a reader", ctx do
      page_fixture(ctx.board, %{"title" => "Plans", "status" => "draft"})

      assert ctx.conn
             |> call(%{what: "resolve", board: "delivery", title: "Plans"})
             |> ok!()
             |> Map.get("found")

      seen =
        ctx.board
        |> reader()
        |> call(%{what: "resolve", board: "delivery", title: "Plans"})
        |> ok!()

      assert seen["found"] == false
      assert seen["near"] == []
    end

    test "title and board are required", ctx do
      assert ctx.conn |> call(%{what: "resolve", board: "delivery"}) |> error!() =~
               "title is required"

      assert ctx.conn |> call(%{what: "resolve", title: "Guide"}) |> error!() =~
               "board is required"
    end

    test "another tenant's board reads as not there", ctx do
      other = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Private", "code" => "private"}, owner: other)
      page_fixture(theirs, %{"title" => "Their secret"}, user: other)

      text =
        ctx.conn |> call(%{what: "resolve", board: theirs.id, title: "Their secret"}) |> error!()

      assert text =~ "no board"
      refute text =~ "Their secret"
    end
  end
end
