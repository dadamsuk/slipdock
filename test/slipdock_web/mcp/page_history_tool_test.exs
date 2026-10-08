defmodule SlipdockWeb.MCP.PageHistoryToolTest do
  @moduledoc """
  `page_history` and `revert_page`: seeing what was done to a page over MCP
  and putting it back — newest first, the change one save made, a revert that
  is a save of its own, and the hash, token and visibility checks a rewrite
  has.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)
    other = user_fixture("editor-#{System.unique_integer([:positive])}@example.com")

    # Alternate hands, so no save folds into the one before it.
    page = page_fixture(board, %{"title" => "Runbook", "body" => "one"}, user: user)
    {:ok, page} = Wiki.update_page(page, %{"body" => "one\ntwo"}, user: other, message: "add two")
    {:ok, page} = Wiki.update_page(page, %{"body" => "one\nTWO"}, user: user, message: "shout")

    [third, second, first] = Wiki.list_revisions(page)

    %{
      conn: conn,
      user: user,
      other: other,
      board: board,
      page: page,
      revs: %{first: first, second: second, third: third}
    }
  end

  defp call(conn, tool, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
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

  defp read_only(user) do
    {token, _} = Accounts.create_api_token(user, "reader", scope: "read")
    put_req_header(build_conn(), "authorization", "Bearer " <> token)
  end

  test "tools/list: page_history reads, revert_page writes and can overwrite", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1["annotations"]})

    assert tools["page_history"]["readOnlyHint"] == true
    assert tools["revert_page"]["readOnlyHint"] == false
    assert tools["revert_page"]["destructiveHint"] == true
  end

  describe "page_history" do
    test "lists revisions newest first, with who, how and why", ctx do
      out = ctx.conn |> call("page_history", %{page: ctx.page.code}) |> ok!()

      assert out["page"]["code"] == ctx.page.code
      assert out["page"]["content_hash"] == Wiki.get_page!(ctx.page.id).content_hash

      assert Enum.map(out["revisions"], & &1["id"]) ==
               [ctx.revs.third.id, ctx.revs.second.id, ctx.revs.first.id]

      [newest, middle | _] = out["revisions"]
      assert newest["summary"] == "shout"
      assert newest["author"] == ctx.user.email
      assert middle["author"] == ctx.other.email
      assert middle["via"] == "web"
      refute Map.has_key?(newest, "body")
    end

    test "limit keeps the newest", ctx do
      out = ctx.conn |> call("page_history", %{page: ctx.page.code, limit: 2}) |> ok!()
      assert Enum.map(out["revisions"], & &1["id"]) == [ctx.revs.third.id, ctx.revs.second.id]

      assert ctx.conn |> call("page_history", %{page: ctx.page.code, limit: 0}) |> error!() =~
               "limit must be a positive whole number"
    end

    test "finds the page by title with its board", ctx do
      out = ctx.conn |> call("page_history", %{page: "Runbook", board: "delivery"}) |> ok!()
      assert length(out["revisions"]) == 3
    end

    test "diff=true is the latest save's change, without the body", ctx do
      out = ctx.conn |> call("page_history", %{page: ctx.page.code, diff: true}) |> ok!()

      assert out["revision"]["id"] == ctx.revs.third.id
      assert out["previous"] == ctx.revs.second.id

      assert out["diff"] == [
               %{"op" => "eq", "lines" => ["one"]},
               %{"op" => "del", "lines" => ["two"]},
               %{"op" => "ins", "lines" => ["TWO"]}
             ]

      refute Map.has_key?(out, "body")
    end

    test "rev gives that revision's body and the change it made", ctx do
      out =
        ctx.conn |> call("page_history", %{page: ctx.page.code, rev: ctx.revs.second.id}) |> ok!()

      assert out["body"] == "one\ntwo"
      assert out["previous"] == ctx.revs.first.id

      assert out["diff"] == [
               %{"op" => "eq", "lines" => ["one"]},
               %{"op" => "ins", "lines" => ["two"]}
             ]

      # The first save is all insertion, with nothing before it.
      first =
        ctx.conn |> call("page_history", %{page: ctx.page.code, rev: ctx.revs.first.id}) |> ok!()

      assert first["previous"] == nil
      assert first["diff"] == [%{"op" => "ins", "lines" => ["one"]}]
    end

    test "long unchanged runs are cut to the lines next to the change", ctx do
      lines = Enum.map(1..20, &"line #{&1}")
      before = Enum.join(lines, "\n")
      after_ = lines |> List.replace_at(9, "CHANGED") |> Enum.join("\n")

      page = page_fixture(ctx.board, %{"title" => "Long", "body" => before}, user: ctx.user)
      {:ok, _} = Wiki.update_page(page, %{"body" => after_}, user: ctx.other)

      out = ctx.conn |> call("page_history", %{page: page.code, diff: true}) |> ok!()

      assert out["diff"] == [
               %{"op" => "skip", "count" => 6},
               %{"op" => "eq", "lines" => ["line 7", "line 8", "line 9"]},
               %{"op" => "del", "lines" => ["line 10"]},
               %{"op" => "ins", "lines" => ["CHANGED"]},
               %{"op" => "eq", "lines" => ["line 11", "line 12", "line 13"]},
               %{"op" => "skip", "count" => 7}
             ]
    end

    test "an unknown or malformed rev is refused", ctx do
      assert ctx.conn |> call("page_history", %{page: ctx.page.code, rev: 999_999}) |> error!() =~
               "no revision you can see"

      assert ctx.conn |> call("page_history", %{page: ctx.page.code, rev: "latest"}) |> error!() =~
               "rev must be a revision id"
    end

    test "another page's revision is not this page's", ctx do
      elsewhere = page_fixture(ctx.board, %{"title" => "Elsewhere"}, user: ctx.user)

      assert ctx.conn
             |> call("page_history", %{page: elsewhere.code, rev: ctx.revs.first.id})
             |> error!() =~ "no revision you can see"
    end

    test "a read-only token can read history", ctx do
      out = ctx.user |> read_only() |> call("page_history", %{page: ctx.page.code}) |> ok!()
      assert length(out["revisions"]) == 3
    end

    test "a stranger's page, and a draft to a reader, are not there", ctx do
      stranger = user_fixture("stranger-#{System.unique_integer([:positive])}@example.com")

      assert stranger |> conn_as() |> call("page_history", %{page: ctx.page.code}) |> error!() =~
               "don't read this page"

      draft =
        page_fixture(ctx.board, %{"title" => "Secret plan", "status" => "draft"}, user: ctx.user)

      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, reader, "read")

      assert reader |> conn_as() |> call("page_history", %{page: draft.code}) |> error!() =~
               "no page you can see"
    end
  end

  describe "revert_page" do
    test "puts a revision back as a new revision, recorded as over MCP", ctx do
      hash = Wiki.get_page!(ctx.page.id).content_hash

      out =
        ctx.conn
        |> call("revert_page", %{
          page: ctx.page.code,
          rev: ctx.revs.first.id,
          base_hash: hash,
          message: "undo the shouting"
        })
        |> ok!()

      page = Wiki.get_page!(ctx.page.id)
      assert page.body == "one"
      assert out["content_hash"] == page.content_hash
      assert out["reverted_to"] == ctx.revs.first.id

      [newest | rest] = Wiki.list_revisions(page)
      assert out["revision"] == newest.id
      assert newest.body == "one"
      assert newest.via == "mcp"
      assert newest.summary == "undo the shouting"
      # Nothing went: the three saves before it are all still there.
      assert Enum.map(rest, & &1.id) == [ctx.revs.third.id, ctx.revs.second.id, ctx.revs.first.id]
    end

    test "with no message, says what it went back to", ctx do
      hash = Wiki.get_page!(ctx.page.id).content_hash

      ctx.conn
      |> call("revert_page", %{page: ctx.page.code, rev: ctx.revs.second.id, base_hash: hash})
      |> ok!()

      [newest | _] = Wiki.list_revisions(ctx.page)
      assert newest.summary =~ "reverted to the version of"
    end

    test "an unknown rev is refused and nothing changes", ctx do
      hash = Wiki.get_page!(ctx.page.id).content_hash

      assert ctx.conn
             |> call("revert_page", %{page: ctx.page.code, rev: 999_999, base_hash: hash})
             |> error!() =~ "no revision you can see"

      assert Wiki.get_page!(ctx.page.id).body == "one\nTWO"
      assert length(Wiki.list_revisions(ctx.page)) == 3
    end

    test "base_hash is required", ctx do
      assert ctx.conn
             |> call("revert_page", %{page: ctx.page.code, rev: ctx.revs.first.id})
             |> error!() == "base_hash is required"

      assert Wiki.get_page!(ctx.page.id).body == "one\nTWO"
    end

    test "a stale base_hash is a conflict, and the newer edit stays", ctx do
      stale = Wiki.get_page!(ctx.page.id).content_hash
      {:ok, _} = Wiki.update_page(ctx.page, %{"body" => "someone's fix"}, user: ctx.other)

      text =
        ctx.conn
        |> call("revert_page", %{page: ctx.page.code, rev: ctx.revs.first.id, base_hash: stale})
        |> error!()

      assert text =~ "conflict"
      assert text =~ Wiki.get_page!(ctx.page.id).content_hash
      assert Wiki.get_page!(ctx.page.id).body == "someone's fix"
    end

    test "a read-only token is refused and nothing changes", ctx do
      hash = Wiki.get_page!(ctx.page.id).content_hash

      text =
        ctx.user
        |> read_only()
        |> call("revert_page", %{page: ctx.page.code, rev: ctx.revs.first.id, base_hash: hash})
        |> error!()

      assert text =~ "read-only"
      assert Wiki.get_page!(ctx.page.id).body == "one\nTWO"
    end

    test "a reader on the board cannot revert", ctx do
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, reader, "read")
      hash = Wiki.get_page!(ctx.page.id).content_hash

      reader
      |> conn_as()
      |> call("revert_page", %{page: ctx.page.code, rev: ctx.revs.first.id, base_hash: hash})
      |> error!()

      assert Wiki.get_page!(ctx.page.id).body == "one\nTWO"
    end
  end
end
