defmodule SlipdockWeb.API.FoldersTest do
  @moduledoc """
  Folders over HTTP: making them, filing pages in them, and the whole wiki in
  one call.

  The premise these hold to is the one the context holds to — filing never
  destroys writing — plus the convenience an agent needs: a folder named by a
  path it can say out loud, made on the way past if it is new.
  """
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "API Wiki", "code" => "apiwiki"}, owner: user)
    %{conn: put_req_header(conn, "accept", "application/json"), board: board}
  end

  test "makes a folder, and a path makes the whole chain", %{conn: conn} do
    assert %{"folder" => folder} =
             conn
             |> post("/api/boards/apiwiki/folders", %{name: "Design/Decisions"})
             |> json_response(201)

    assert folder["path"] == "Design/Decisions"
    assert folder["slug"] == "decisions"
  end

  test "a page can be written straight into a folder that does not exist yet", %{conn: conn} do
    assert %{"page" => page} =
             conn
             |> post("/api/boards/apiwiki/pages", %{title: "Why SQLite", folder: "Design"})
             |> json_response(201)

    assert page["folder_id"]

    assert %{"folders" => [%{"name" => "Design", "pages" => [%{"title" => "Why SQLite"}]}]} =
             conn |> get("/api/boards/apiwiki/folders") |> json_response(200)
  end

  test "a page is filed and unfiled", %{conn: conn, board: board} do
    page = page_fixture(board, %{"title" => "Runbook"})
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Ops"})

    assert %{"page" => filed} =
             conn
             |> post("/api/pages/#{page.code}/folder", %{folder: "Ops"})
             |> json_response(200)

    assert filed["folder_id"] == folder.id

    assert %{"page" => loose} =
             conn |> post("/api/pages/#{page.code}/folder", %{}) |> json_response(200)

    assert loose["folder_id"] == nil
  end

  test "a folder is renamed and moved by any handle it answers to", %{conn: conn, board: board} do
    {:ok, _} = Wiki.create_folder(board, %{"name" => "Design/Decisions"})

    assert %{"folder" => moved} =
             conn
             |> patch("/api/boards/apiwiki/folders/Design/Decisions", %{parent: "root"})
             |> json_response(200)

    assert moved["path"] == "Decisions"

    assert %{"folder" => renamed} =
             conn
             |> patch("/api/boards/apiwiki/folders/decisions", %{name: "Choices"})
             |> json_response(200)

    assert renamed["name"] == "Choices"
  end

  test "a folder cannot be moved inside itself", %{conn: conn, board: board} do
    {:ok, _} = Wiki.create_folder(board, %{"name" => "Outer/Inner"})

    assert conn
           |> patch("/api/boards/apiwiki/folders/Outer", %{parent: "Inner"})
           |> json_response(422)
  end

  test "deleting a folder keeps its pages, at the root", %{conn: conn, board: board} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Ops"})
    page = page_fixture(board, %{"title" => "Runbook"})
    {:ok, _} = Wiki.file_page(page, folder)

    assert %{"deleted" => %{"name" => "Ops"}} =
             conn |> delete("/api/boards/apiwiki/folders/Ops") |> json_response(200)

    assert Wiki.get_page!(page.id).folder_id == nil
  end

  test "?purge=true deletes the folder and everything in it", %{conn: conn, board: board} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Ops"})
    {:ok, _sub} = Wiki.create_folder(board, %{"name" => "Ops/Old"})
    page = page_fixture(board, %{"title" => "Runbook"})
    {:ok, _} = Wiki.file_page(page, folder)

    assert %{"deleted" => %{"name" => "Ops"}, "purged" => %{"pages" => 1, "folders" => 1}} =
             conn
             |> delete("/api/boards/apiwiki/folders/Ops", %{purge: "true"})
             |> json_response(200)

    assert Wiki.get_page(page.id) == nil
    assert Wiki.get_folder(folder.id) == nil
  end

  test "purging a folder is the owner's only", %{conn: conn, user: user} do
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirswiki"}, owner: stranger)
    {:ok, _} = Slipdock.Access.grant(theirs, user, "write", stranger)
    {:ok, folder} = Wiki.create_folder(theirs, %{"name" => "Ops"})
    page = page_fixture(theirs, %{"title" => "Runbook"})
    {:ok, _} = Wiki.file_page(page, folder)

    assert conn
           |> delete("/api/boards/theirswiki/folders/Ops", %{purge: "true"})
           |> json_response(403)

    # And the cautious delete is still a writer's to make.
    assert conn |> delete("/api/boards/theirswiki/folders/Ops") |> json_response(200)
    assert Wiki.get_page!(page.id).folder_id == nil
  end

  test "GET /api/wiki is every board the reader can open", %{conn: conn, board: board} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Ops"})
    page = page_fixture(board, %{"title" => "Runbook"})
    {:ok, _} = Wiki.file_page(page, folder)

    assert %{"boards" => boards} = conn |> get("/api/wiki") |> json_response(200)

    entry = Enum.find(boards, &(&1["code"] == "apiwiki"))
    assert [%{"name" => "Ops", "pages" => [%{"title" => "Runbook"}]}] = entry["folders"]
  end

  test "a reader cannot make a folder on a board they can only read", %{conn: conn, user: user} do
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs"}, owner: stranger)
    {:ok, _} = Slipdock.Access.grant(theirs, user, "read", stranger)

    assert conn |> post("/api/boards/theirs/folders", %{name: "Mine"}) |> json_response(403)
  end
end
