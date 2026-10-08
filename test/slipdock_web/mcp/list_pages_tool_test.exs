defmodule SlipdockWeb.MCP.ListPagesToolTest do
  @moduledoc """
  `list_pages`: a board's wiki over MCP, flat or as a tree, filtered as the
  API's page index filters it, with drafts kept from readers who cannot edit
  them and nothing listed from a board the caller cannot read.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)

    guide = page_fixture(board, %{"title" => "Guide", "summary" => "start here"}, user: user)

    {:ok, child} =
      Wiki.create_page(board, %{"title" => "Install", "parent_id" => guide.id}, user: user)

    {:ok, folder} = Wiki.create_folder(board, %{"name" => "ops"})
    runbook = page_fixture(board, %{"title" => "Runbook", "body" => "restart the queue"})
    {:ok, runbook} = Wiki.file_page(runbook, folder)

    card = card_fixture(hd(board.columns), %{"title" => "Queue work"})
    {:ok, _} = Wiki.pin(runbook, {:card, card})

    old = page_fixture(board, %{"title" => "Old notes"})
    {:ok, _} = Wiki.archive_page(old)

    template = page_fixture(board, %{"title" => "Retro template", "template" => true})
    draft = page_fixture(board, %{"title" => "Half written", "status" => "draft"})

    %{
      conn: conn,
      board: board,
      guide: guide,
      child: child,
      runbook: runbook,
      card: card,
      old: old,
      template: template,
      draft: draft
    }
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
        params: %{name: "list_pages", arguments: args}
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

  defp titles(%{"pages" => pages}), do: Enum.map(pages, & &1["title"]) |> Enum.sort()

  test "tools/list offers it as a read-only tool", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    tool = Enum.find(tools, &(&1["name"] == "list_pages"))
    assert tool["annotations"]["readOnlyHint"] == true
    assert String.length(tool["description"]) < 250
  end

  describe "a flat list" do
    test "every live page, with what each line says about it", ctx do
      result = ctx.conn |> call(%{board: "delivery"}) |> ok!()

      assert result["board"] == %{
               "id" => ctx.board.id,
               "code" => "delivery",
               "name" => "Delivery"
             }

      assert result["truncated"] == false

      # The owner can edit, so their draft is listed; templates are pages too.
      assert titles(result) ==
               ["Guide", "Half written", "Install", "Retro template", "Runbook"]

      lines = Map.new(result["pages"], &{&1["title"], &1})

      assert lines["Guide"]["code"] == ctx.guide.code
      assert lines["Guide"]["summary"] == "start here"
      assert lines["Guide"]["parent"] == nil
      assert lines["Guide"]["url"] =~ "/boards/#{ctx.board.id}/wiki/"
      assert lines["Guide"]["updated_at"]
      assert lines["Install"]["parent"] == ctx.guide.code
      assert lines["Runbook"]["folder"] == "ops"
      assert lines["Runbook"]["pinned_cards"] == [ctx.card.id]
      assert lines["Guide"]["pinned_cards"] == []
      assert lines["Half written"]["draft"] == true
      assert lines["Retro template"]["template"] == true
      assert lines["Guide"]["archived"] == false
      refute Map.has_key?(lines["Guide"], "body")
    end

    test "the board by id or name as well as code", ctx do
      assert ctx.conn |> call(%{board: ctx.board.id}) |> ok!() |> titles() |> length() == 5
      assert ctx.conn |> call(%{board: "Delivery"}) |> ok!() |> titles() |> length() == 5
    end
  end

  test "tree nests children under their parent", ctx do
    %{"pages" => roots} = ctx.conn |> call(%{board: "delivery", tree: true}) |> ok!()

    guide = Enum.find(roots, &(&1["title"] == "Guide"))
    assert [%{"title" => "Install", "children" => []}] = guide["children"]
    refute Enum.any?(roots, &(&1["title"] == "Install"))
  end

  test "q matches titles and text", ctx do
    assert ctx.conn |> call(%{board: "delivery", q: "guide"}) |> ok!() |> titles() == ["Guide"]

    assert ctx.conn |> call(%{board: "delivery", q: "restart the"}) |> ok!() |> titles() ==
             ["Runbook"]

    assert ctx.conn |> call(%{board: "delivery", q: "nothing like it"}) |> ok!() |> titles() ==
             []
  end

  describe "filters" do
    test "archived: exclude by default, include, only", ctx do
      refute "Old notes" in (ctx.conn |> call(%{board: "delivery"}) |> ok!() |> titles())

      assert "Old notes" in (ctx.conn
                             |> call(%{board: "delivery", archived: "include"})
                             |> ok!()
                             |> titles())

      only = ctx.conn |> call(%{board: "delivery", archived: "only"}) |> ok!()
      assert [%{"title" => "Old notes", "archived" => true}] = only["pages"]
    end

    test "archived must be one of the three", ctx do
      assert ctx.conn |> call(%{board: "delivery", archived: "yes"}) |> error!() =~
               "exclude, include or only"
    end

    test "template: only templates, or none", ctx do
      assert ctx.conn |> call(%{board: "delivery", template: true}) |> ok!() |> titles() ==
               ["Retro template"]

      refute "Retro template" in (ctx.conn
                                  |> call(%{board: "delivery", template: false})
                                  |> ok!()
                                  |> titles())
    end

    test "draft: only drafts, or only published", ctx do
      assert ctx.conn |> call(%{board: "delivery", draft: true}) |> ok!() |> titles() ==
               ["Half written"]

      refute "Half written" in (ctx.conn
                                |> call(%{board: "delivery", draft: false})
                                |> ok!()
                                |> titles())
    end

    test "a non-boolean flag is a tool error, not a crash", ctx do
      assert ctx.conn |> call(%{board: "delivery", tree: "yes"}) |> error!() =~ "true or false"
    end
  end

  describe "drafts and a reader who cannot edit" do
    setup ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")
      %{reader: conn_as(reader)}
    end

    test "never sees a draft listed", ctx do
      refute "Half written" in (ctx.reader |> call(%{board: "delivery"}) |> ok!() |> titles())
      assert ctx.reader |> call(%{board: "delivery", draft: true}) |> ok!() |> titles() == []
    end
  end

  describe "limit" do
    test "cuts the list short and says so", ctx do
      result = ctx.conn |> call(%{board: "delivery", limit: 2}) |> ok!()
      assert length(result["pages"]) == 2
      assert result["truncated"] == true
    end

    test "a limit that covers everything is not truncated", ctx do
      result = ctx.conn |> call(%{board: "delivery", limit: 5}) |> ok!()
      assert length(result["pages"]) == 5
      assert result["truncated"] == false
    end

    test "must be a positive whole number", ctx do
      assert ctx.conn |> call(%{board: "delivery", limit: 0}) |> error!() =~ "positive"
    end
  end

  describe "boards that cannot be listed" do
    test "board is required", ctx do
      assert ctx.conn |> call(%{}) |> error!() =~ "board is required"
    end

    test "an unknown board", ctx do
      assert ctx.conn |> call(%{board: "nowhere"}) |> error!() =~ "no board"
    end

    test "another tenant's board reads as not there, and lists nothing", ctx do
      other = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Private", "code" => "private"}, owner: other)
      page_fixture(theirs, %{"title" => "Their secret"}, user: other)

      text = ctx.conn |> call(%{board: theirs.id}) |> error!()
      assert text =~ "no board"
      refute text =~ "Their secret"
    end

    test "a token scoped to another board cannot list this one", ctx do
      other = board_fixture(%{"name" => "Other", "code" => "other"}, owner: ctx.user)
      {token, _} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [other.id])
      conn = put_req_header(ctx.conn, "authorization", "Bearer " <> token)

      assert conn |> call(%{board: "delivery"}) |> error!()
      assert conn |> call(%{board: "other"}) |> ok!() |> titles() == []
    end
  end
end
