defmodule SlipdockWeb.MCP.ShareToolTest do
  @moduledoc "`share`, and `list_pages shared` / `read_page` on what is shared with you (#820)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}

  setup %{conn: conn, user: owner} do
    board = board_fixture(%{"name" => "Delivery"}, owner: owner)
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})

    page =
      page_fixture(board, %{"title" => "Plan", "body" => "the plan", "folder_id" => folder.id})

    friend = user_fixture("mcp.friend@example.com")
    %{conn: conn, owner: owner, board: board, folder: folder, page: page, friend: friend}
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

  test "shares a page, changes the level, lists and takes it back", c do
    assert %{"shared_with" => [%{"person" => email, "level" => "read"}]} =
             c.conn |> call("share", %{page: c.page.code, with: c.friend.email}) |> ok!()

    assert email == c.friend.email
    assert Access.page_permission(c.friend, c.page) == :read

    c.conn |> call("share", %{page: c.page.code, with: c.friend.email, level: "write"}) |> ok!()

    assert %{"shared_with" => [%{"level" => "write"}]} =
             c.conn |> call("share", %{page: c.page.code}) |> ok!()

    assert %{"shared_with" => []} =
             c.conn
             |> call("share", %{page: c.page.code, with: c.friend.email, off: true})
             |> ok!()

    assert Access.page_permission(c.friend, c.page) == :none
  end

  test "shares a folder by name with its board, and so everything in it", c do
    c.conn
    |> call("share", %{folder: "Specs", board: c.board.code, with: c.friend.email, level: "write"})
    |> ok!()

    assert Access.page_permission(c.friend, c.page) == :write
  end

  test "somebody it was shared with can't pass it on", c do
    {:ok, _} = Access.grant(c.page, c.friend, "write", c.owner)

    assert c.friend
           |> conn_as()
           |> call("share", %{page: c.page.code, with: "someone@example.com"})
           |> error!() =~ "shared_no_reshare"
  end

  test "says what is wrong with a call that names nothing", c do
    assert c.conn |> call("share", %{with: c.friend.email}) |> error!() =~ "say which"
  end

  test "list_pages shared: true and read_page reach what is shared with you", c do
    {:ok, _} = Access.grant(c.folder, c.friend, "read", c.owner)
    friend = conn_as(c.friend)

    assert %{"shared" => [%{"items" => [%{"name" => "Specs", "pages" => [%{"code" => code}]}]}]} =
             friend |> call("list_pages", %{shared: true}) |> ok!()

    assert code == c.page.code
    assert %{"body" => "the plan"} = friend |> call("read_page", %{page: code}) |> ok!()
  end

  test "list_pages still needs a board when it isn't asked for what is shared", c do
    assert c.conn |> call("list_pages", %{}) |> error!() =~ "board"
  end
end
