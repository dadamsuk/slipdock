defmodule SlipdockWeb.API.PagePlacementsTest do
  @moduledoc "Filing a page in several folders over the API and MCP (W-103 R12.6)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Wiki.Placements

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Brain", "code" => "plapi"}, owner: user)
    jobs = board_fixture(%{"name" => "Jobs", "code" => "plajobs"}, owner: user)
    {:ok, home} = Wiki.create_folder(board, %{"name" => "Home"})

    {:ok, page} =
      Wiki.create_page(board, %{"title" => "Note", "folder_id" => home.id}, user: user)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      jobs: jobs,
      page: page
    }
  end

  defp file(conn, page, body),
    do: conn |> post("/api/pages/#{page.code}/folder", body)

  test "also files it, keeps its home, and lists it in both places", %{conn: conn, page: page} do
    body = conn |> file(page, %{"also" => "Ideas"}) |> json_response(200)
    assert [%{"path" => "Ideas", "board" => "plapi"}] = body["page"]["also_in"]
    assert body["page"]["folder_id"] == page.folder_id

    listed =
      conn
      |> get("/api/boards/plapi/pages?folder=Ideas")
      |> json_response(200)
      |> Map.fetch!("pages")

    assert [%{"title" => "Note", "also" => true}] = listed

    home =
      conn
      |> get("/api/boards/plapi/pages?folder=Home")
      |> json_response(200)
      |> Map.fetch!("pages")

    assert [%{"title" => "Note", "also" => false}] = home

    tree =
      conn |> get("/api/boards/plapi/folders") |> json_response(200) |> Map.fetch!("folders")

    ideas = Enum.find(tree, &(&1["name"] == "Ideas"))
    assert [%{"title" => "Note", "also" => true}] = ideas["pages"]
  end

  test "not_in takes it out again; the page stays", %{conn: conn, page: page} do
    file(conn, page, %{"also" => "Ideas"}) |> json_response(200)
    body = conn |> file(page, %{"not_in" => "Ideas"}) |> json_response(200)
    assert body["page"]["also_in"] == []
    assert body["page"]["archived_at"] == nil

    assert conn |> file(page, %{"not_in" => "Ideas"}) |> json_response(404)
    assert conn |> file(page, %{"not_in" => "Never made"}) |> json_response(404)
  end

  test "refusals: its home, a folder on a board outside its vault, nothing named", %{
    conn: conn,
    page: page
  } do
    assert conn |> file(page, %{"also" => "Home"}) |> json_response(422)

    assert conn
           |> file(page, %{"also" => "Notes", "board" => "plajobs"})
           |> json_response(422)

    assert conn |> file(page, %{"also" => ""}) |> json_response(400)
    assert conn |> file(page, %{"also" => "/Jobs/Notes"}) |> json_response(422)
  end

  test "by vault path, onto another board of the vault", %{
    conn: conn,
    user: user,
    board: board,
    jobs: jobs,
    page: page
  } do
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "V"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})

    body = conn |> file(page, %{"also" => "/Jobs/Notes"}) |> json_response(200)
    assert [%{"path" => "Notes", "board" => "plajobs"}] = body["page"]["also_in"]

    body =
      conn |> file(page, %{"also" => "Other", "board" => "plajobs"}) |> json_response(200)

    assert length(body["page"]["also_in"]) == 2

    listed =
      conn
      |> get("/api/boards/plajobs/pages?folder=Notes")
      |> json_response(200)
      |> Map.fetch!("pages")

    assert [%{"title" => "Note", "also" => true, "board_id" => board_id}] = listed
    assert board_id == board.id
  end

  test "folder still files the home, alongside also", %{conn: conn, page: page} do
    body = conn |> file(page, %{"folder" => "Moved", "also" => "Home"}) |> json_response(200)
    assert [%{"path" => "Home"}] = body["page"]["also_in"]
    {:ok, moved} = Wiki.find_folder(Wiki.board_of(page), "Moved")
    assert Wiki.get_page!(page.id).folder_id == moved.id
  end

  describe "over MCP" do
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

    test "update_page also/not_in, and list_pages by folder", %{conn: conn, page: page} do
      result = call(conn, "update_page", %{page: page.code, also: "Ideas"})
      assert result["structuredContent"]["also_in"] == ["Ideas"]

      listed =
        call(conn, "list_pages", %{board: "plapi", folder: "Ideas"})["structuredContent"][
          "pages"
        ]

      assert [%{"title" => "Note", "also" => true}] = listed

      result = call(conn, "update_page", %{page: page.code, not_in: "Ideas"})
      assert result["structuredContent"]["also_in"] == []
      assert Placements.folders(page) == []

      assert call(conn, "update_page", %{page: page.code, also: "Home"})["isError"] == true
    end
  end
end
