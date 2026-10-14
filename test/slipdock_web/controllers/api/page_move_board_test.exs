defmodule SlipdockWeb.API.PageMoveBoardTest do
  @moduledoc """
  `POST /api/pages/:id/move` with `board`: to another board of the page's
  vault (W-103 R11.8), with a dry run; and `PATCH .../folders` with `sort`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}

  setup %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "KB", "code" => "kbapimv"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobsapimv"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: jobs})
    {:ok, _} = Wiki.create_folder(jobs, %{"name" => "Acme"})
    page = page_fixture(kb, %{"title" => "Call notes"})
    {:ok, _} = Wiki.set_tags(page, [tag_fixture(kb, "KB only")])
    %{conn: put_req_header(conn, "accept", "application/json"), page: page, jobs: jobs}
  end

  test "a dry run says what would stay behind, and moves nothing", %{conn: conn, page: page} do
    body =
      conn
      |> post("/api/pages/#{page.code}/move", %{board: "jobsapimv", dry_run: true})
      |> json_response(200)

    assert %{"dry_run" => true, "report" => %{"tags" => %{"dropped" => ["KB only"]}}} = body
    assert Wiki.get_page!(page.id).board_id == page.board_id
  end

  test "moves it, keeping its code, into a folder named on the target", %{
    conn: conn,
    page: page,
    jobs: jobs
  } do
    assert %{"page" => moved} =
             conn
             |> post("/api/pages/#{page.code}/move", %{board: "jobsapimv", folder: "Acme"})
             |> json_response(200)

    assert moved["code"] == page.code
    assert moved["board_id"] == jobs.id
  end

  test "outside the vault, or to a folder that is not there, it is refused", %{
    conn: conn,
    page: page,
    user: user
  } do
    board_fixture(%{"name" => "Lone", "code" => "loneapimv"}, owner: user)

    assert conn
           |> post("/api/pages/#{page.code}/move", %{board: "loneapimv"})
           |> json_response(422)

    assert conn
           |> post("/api/pages/#{page.code}/move", %{board: "jobsapimv", folder: "Nope"})
           |> json_response(404)
  end

  test "a folder's sort is set like its name", %{conn: conn, jobs: jobs} do
    assert %{"folder" => _} =
             conn
             |> patch("/api/boards/jobsapimv/folders/Acme", %{sort: "name"})
             |> json_response(200)

    {:ok, acme} = Wiki.find_folder(jobs, "Acme")
    assert acme.sort == "name"

    assert conn
           |> patch("/api/boards/jobsapimv/folders/Acme", %{sort: "dice"})
           |> json_response(422)
  end
end
