defmodule SlipdockWeb.MCP.UpdatePageToolTest do
  @moduledoc """
  `update_page`: a page's housekeeping over MCP — title, summary, where it
  sits in the tree and in folders, archiving and restoring, and pinning it to
  a card — with the same token and visibility checks as the API's.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo, Wiki}
  alias Slipdock.Wiki.Link

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)
    guide = page_fixture(board, %{"title" => "Guide", "body" => "the guide"}, user: user)
    runbook = page_fixture(board, %{"title" => "Runbook", "body" => "steps"}, user: user)
    card = card_fixture(hd(board.columns), %{"title" => "Ship it"})

    %{conn: conn, user: user, board: board, guide: guide, runbook: runbook, card: card}
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
        params: %{name: "update_page", arguments: args}
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

  defp pinned?(page, card) do
    Repo.exists?(
      from(l in Link,
        where: l.page_id == ^page.id and l.target_card_id == ^card.id and l.pinned
      )
    )
  end

  test "tools/list: a write, and not a destructive one", %{conn: conn} do
    tool =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Enum.find(&(&1["name"] == "update_page"))

    assert tool["annotations"]["readOnlyHint"] == false
    assert tool["annotations"]["destructiveHint"] == false
    assert tool["inputSchema"]["required"] == ["page"]
  end

  describe "title and summary" do
    test "renames a page and sets its summary, leaving the body alone", ctx do
      out =
        ctx.conn
        |> call(%{
          page: ctx.runbook.code,
          title: "Deploy runbook",
          summary: "How to ship",
          message: "clearer name"
        })
        |> ok!()

      page = Wiki.get_page!(ctx.runbook.id)
      assert page.title == "Deploy runbook"
      assert page.summary == "How to ship"
      assert page.body == "steps"
      assert out["title"] == "Deploy runbook"
      assert out["summary"] == "How to ship"
      assert out["code"] == ctx.runbook.code
      assert out["url"] =~ "/"

      [newest | _] = Wiki.list_revisions(page)
      assert newest.via == "mcp"
    end

    test "only what is passed changes", ctx do
      {:ok, _} = Wiki.update_page(ctx.runbook, %{"summary" => "kept"}, user: ctx.user)

      ctx.conn |> call(%{page: ctx.runbook.code, title: "Renamed"}) |> ok!()

      page = Wiki.get_page!(ctx.runbook.id)
      assert page.title == "Renamed"
      assert page.summary == "kept"
    end

    test "an empty summary clears it", ctx do
      {:ok, _} = Wiki.update_page(ctx.runbook, %{"summary" => "old"}, user: ctx.user)

      ctx.conn |> call(%{page: ctx.runbook.code, summary: ""}) |> ok!()

      assert Wiki.get_page!(ctx.runbook.id).summary in [nil, ""]
    end

    test "a blank title is refused and nothing changes", ctx do
      assert ctx.conn
             |> call(%{page: ctx.runbook.code, title: "  ", summary: "x"})
             |> error!() == "title can't be blank"

      page = Wiki.get_page!(ctx.runbook.id)
      assert page.title == "Runbook"
      assert page.summary != "x"
    end

    test "finds the page by title with board", ctx do
      ctx.conn |> call(%{page: "Runbook", board: "delivery", title: "Found"}) |> ok!()
      assert Wiki.get_page!(ctx.runbook.id).title == "Found"
    end
  end

  describe "moving" do
    test "under a parent, then back to the top", ctx do
      out = ctx.conn |> call(%{page: ctx.runbook.code, parent: ctx.guide.code}) |> ok!()

      assert out["parent_id"] == ctx.guide.id
      assert Wiki.get_page!(ctx.runbook.id).parent_id == ctx.guide.id

      out = ctx.conn |> call(%{page: ctx.runbook.code, parent: ""}) |> ok!()

      assert out["parent_id"] == nil
      assert Wiki.get_page!(ctx.runbook.id).parent_id == nil
    end

    test "a parent named by title works too", ctx do
      ctx.conn |> call(%{page: ctx.runbook.code, parent: "Guide"}) |> ok!()
      assert Wiki.get_page!(ctx.runbook.id).parent_id == ctx.guide.id
    end

    test "position alone reorders among the siblings it has", ctx do
      ctx.conn |> call(%{page: ctx.runbook.code, position: "top"}) |> ok!()

      assert Wiki.get_page!(ctx.runbook.id).position == 0
      assert Wiki.get_page!(ctx.guide.id).position == 1

      ctx.conn |> call(%{page: ctx.runbook.code, position: 1}) |> ok!()

      assert Wiki.get_page!(ctx.guide.id).position == 0
      assert Wiki.get_page!(ctx.runbook.id).position == 1
    end

    test "an unknown parent is refused and the page stays put", ctx do
      assert ctx.conn
             |> call(%{page: ctx.runbook.code, parent: "Nowhere", title: "Moved?"})
             |> error!() =~ "parent"

      page = Wiki.get_page!(ctx.runbook.id)
      assert page.parent_id == nil
      assert page.title == "Runbook"
    end

    test "a page can't sit under itself", ctx do
      assert ctx.conn
             |> call(%{page: ctx.runbook.code, parent: ctx.runbook.code})
             |> error!() =~ "under itself"
    end

    test "a bad position is refused", ctx do
      assert ctx.conn
             |> call(%{page: ctx.runbook.code, position: "middle"})
             |> error!() =~ "position must be"

      assert ctx.conn
             |> call(%{page: ctx.runbook.code, position: -1})
             |> error!() =~ "position must be"
    end
  end

  describe "folders" do
    test "files a page in a folder made on the way, then unfiles it", ctx do
      out = ctx.conn |> call(%{page: ctx.runbook.code, folder: "Ops"}) |> ok!()

      {:ok, folder} = Wiki.find_folder(ctx.board, "Ops")
      assert out["folder_id"] == folder.id
      assert Wiki.get_page!(ctx.runbook.id).folder_id == folder.id

      # The same name again finds the folder rather than making a second.
      ctx.conn |> call(%{page: ctx.guide.code, folder: "Ops"}) |> ok!()
      assert Wiki.get_page!(ctx.guide.id).folder_id == folder.id

      ctx.conn |> call(%{page: ctx.runbook.code, folder: ""}) |> ok!()
      assert Wiki.get_page!(ctx.runbook.id).folder_id == nil
    end
  end

  describe "archiving" do
    test "archives a page with its children, then restores them", ctx do
      {:ok, _} = Wiki.move_page(ctx.runbook, ctx.guide)

      out = ctx.conn |> call(%{page: ctx.guide.code, archived: true}) |> ok!()

      assert out["archived_at"]
      assert Wiki.get_page!(ctx.guide.id).archived_at
      assert Wiki.get_page!(ctx.runbook.id).archived_at

      out = ctx.conn |> call(%{page: ctx.guide.code, archived: false}) |> ok!()

      assert out["archived_at"] == nil
      assert Wiki.get_page!(ctx.guide.id).archived_at == nil
      assert Wiki.get_page!(ctx.runbook.id).archived_at == nil
    end

    test "restoring and renaming in one call", ctx do
      {:ok, _} = Wiki.archive_page(ctx.runbook)

      ctx.conn |> call(%{page: ctx.runbook.code, archived: false, title: "Back"}) |> ok!()

      page = Wiki.get_page!(ctx.runbook.id)
      assert page.archived_at == nil
      assert page.title == "Back"
    end

    test "archived must be a boolean", ctx do
      assert ctx.conn
             |> call(%{page: ctx.runbook.code, archived: "yes"})
             |> error!() == "archived must be true or false"

      assert Wiki.get_page!(ctx.runbook.id).archived_at == nil
    end
  end

  describe "pinning" do
    test "pins a page to a card, then unpins it", ctx do
      out = ctx.conn |> call(%{page: ctx.runbook.code, pin_card: ctx.card.id}) |> ok!()

      assert out["pinned_to"] == %{"pinned" => ctx.card.id, "unpinned" => nil}
      assert pinned?(ctx.runbook, ctx.card)

      out = ctx.conn |> call(%{page: ctx.runbook.code, unpin_card: ctx.card.id}) |> ok!()

      assert out["pinned_to"] == %{"pinned" => nil, "unpinned" => ctx.card.id}
      refute pinned?(ctx.runbook, ctx.card)
    end

    test "a card the caller cannot see cannot be pinned to", ctx do
      stranger = user_fixture("stranger-#{System.unique_integer([:positive])}@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
      hidden = card_fixture(hd(theirs.columns), %{"title" => "Hidden"})

      text =
        ctx.conn
        |> call(%{page: ctx.runbook.code, pin_card: hidden.id, title: "Should not land"})
        |> error!()

      assert text =~ "card"
      refute pinned?(ctx.runbook, hidden)
      assert Wiki.get_page!(ctx.runbook.id).title == "Runbook"
    end

    test "an unknown card is refused", ctx do
      assert ctx.conn
             |> call(%{page: ctx.runbook.code, pin_card: 999_999_999})
             |> error!() =~ "card"
    end
  end

  describe "refusals" do
    test "page is required", ctx do
      assert ctx.conn |> call(%{title: "x"}) |> error!() == "page is required"
    end

    test "an unknown page", ctx do
      assert ctx.conn |> call(%{page: "W-999999", title: "x"}) |> error!() =~ "no page"
    end

    test "a read-only token is refused and nothing changes", ctx do
      {token, _} = Accounts.create_api_token(ctx.user, "reader", scope: "read")

      text =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> call(%{page: ctx.runbook.code, title: "Nope", archived: true})
        |> error!()

      assert text =~ "read-only"
      page = Wiki.get_page!(ctx.runbook.id)
      assert page.title == "Runbook"
      assert page.archived_at == nil
    end

    test "a reader on the board cannot change it", ctx do
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, reader, "read")

      reader |> conn_as() |> call(%{page: ctx.runbook.code, title: "Nope"}) |> error!()

      assert Wiki.get_page!(ctx.runbook.id).title == "Runbook"
    end

    test "a page on somebody else's board is not found", ctx do
      stranger = user_fixture("owner-#{System.unique_integer([:positive])}@example.com")
      theirs = board_fixture(%{"name" => "Private"}, owner: stranger)
      page = page_fixture(theirs, %{"title" => "Secret"}, user: stranger)

      ctx.conn |> call(%{page: page.code, title: "Mine now"}) |> error!()

      assert Wiki.get_page!(page.id).title == "Secret"
    end
  end
end
