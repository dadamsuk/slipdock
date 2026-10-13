defmodule SlipdockWeb.API.TreeTest do
  @moduledoc """
  `GET /api/boards/:board/tree`: one level of the wiki tree, as the browser's
  tree loads it (W-103 R11.1) — rows, never bodies; drafts for writers only.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Tree API", "code" => "treeapi"}, owner: user)
    {:ok, design} = Wiki.create_folder(board, %{"name" => "Design/Decisions"})
    {:ok, top} = Wiki.find_folder(board, "Design")

    {:ok, why} =
      Wiki.create_page(board, %{"title" => "Why Postgres", "body" => "secret body"}, user: user)

    {:ok, _} = Wiki.file_page(why, design)
    {:ok, _} = Wiki.create_page(board, %{"title" => "Loose", "status" => "draft"}, user: user)
    {:ok, part} = Wiki.create_page(board, %{"title" => "Part", "parent_id" => why.id}, user: user)
    {:ok, _} = Wiki.file_page(part, design)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      design: design,
      top: top,
      why: why
    }
  end

  defp rows(conn, query) do
    conn |> get("/api/boards/treeapi/tree?" <> query) |> json_response(200) |> Map.fetch!("rows")
  end

  test "the root: folders with counts, then pages, and no body anywhere", %{conn: conn} do
    body = conn |> get("/api/boards/treeapi/tree") |> json_response(200)
    assert body["node"] == "root"

    assert [
             %{"kind" => "folder", "title" => "Design", "pages" => 2, "count" => 1},
             %{"kind" => "page", "title" => "Loose", "draft" => true}
           ] = body["rows"]

    refute Jason.encode!(body) =~ "secret body"
  end

  test "a folder by path, by node, and a page by code", %{conn: conn, top: top, why: why} do
    assert [%{"title" => "Why Postgres", "count" => 1, "code" => code}] =
             rows(conn, "folder=Design/Decisions")

    assert code == why.code
    assert [%{"title" => "Decisions"}] = rows(conn, "node=folder:#{top.id}")
    assert [%{"title" => "Part"}] = rows(conn, "page=#{why.code}")
  end

  test "an unknown folder or page is a 404, a garbled node a 400", %{conn: conn, user: user} do
    assert conn |> get("/api/boards/treeapi/tree?folder=Nope") |> json_response(404)
    assert conn |> get("/api/boards/treeapi/tree?page=W-99999") |> json_response(404)
    assert conn |> get("/api/boards/treeapi/tree?node=card:1") |> json_response(400)

    other = board_fixture(%{"name" => "Other", "code" => "othertree"}, owner: user)
    {:ok, theirs} = Wiki.create_folder(other, %{"name" => "Theirs"})
    assert conn |> get("/api/boards/treeapi/tree?node=folder:#{theirs.id}") |> json_response(404)
  end

  test "a reader sees no drafts, and archived pages only when asked", %{board: board, user: user} do
    reader = user_fixture("reader@example.com")
    share_fixture(board, reader, "read")
    {token, _} = Accounts.create_api_token(reader, "agent", [])

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

    assert [%{"kind" => "folder"}] = rows(conn, "")

    {:ok, gone} = Wiki.create_page(board, %{"title" => "Gone"}, user: user)
    {:ok, _} = Wiki.archive_page(gone)

    refute Enum.any?(rows(conn, ""), &(&1["title"] == "Gone"))
    assert %{"archived" => true} = Enum.find(rows(conn, "archived=all"), &(&1["title"] == "Gone"))
  end

  test "a board you cannot open is refused", %{conn: conn} do
    stranger = user_fixture("stranger@example.com")
    board_fixture(%{"name" => "Private", "code" => "privtree"}, owner: stranger)
    assert conn |> get("/api/boards/privtree/tree") |> json_response(404)
  end
end
