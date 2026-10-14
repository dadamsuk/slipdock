defmodule SlipdockWeb.API.FolderMoveBoardTest do
  @moduledoc "`PATCH /api/boards/:board/folders/:folder` with `to_board`: a folder to another board (#745)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Wiki}
  alias Slipdock.Wiki.{Folder, Page}

  setup %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbapi"}, owner: user)
    hunt = board_fixture(%{"name" => "Journal Desk", "code" => "huntapi"}, owner: user)
    {:ok, jobs} = Wiki.create_folder(kb, %{"name" => "Journal"})
    {:ok, page} = Wiki.create_page(kb, %{"title" => "Acme", "folder_id" => jobs.id})

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      kb: kb,
      hunt: hunt,
      jobs: jobs,
      page: page
    }
  end

  test "dry_run reports and moves nothing; then it moves", ctx do
    %{conn: conn, kb: kb, hunt: hunt, jobs: jobs, page: page} = ctx

    dry =
      conn
      |> patch("/api/boards/kbapi/folders/Journal", %{"to_board" => "huntapi", "dry_run" => true})
      |> json_response(200)

    assert dry["dry_run"] and dry["board"] == "huntapi"

    assert %{"pages" => 1, "folders" => 1, "per_folder" => [%{"path" => "Journal", "pages" => 1}]} =
             dry["report"]

    assert Repo.get!(Folder, jobs.id).board_id == kb.id

    moved =
      conn
      |> patch("/api/boards/kbapi/folders/Journal", %{"to_board" => "huntapi"})
      |> json_response(200)

    assert moved["folder"]["board_id"] == hunt.id
    assert Repo.get!(Page, page.id).board_id == hunt.id
  end

  test "contents: true answers with no folder, the emptied one being gone", ctx do
    %{conn: conn, jobs: jobs} = ctx

    moved =
      conn
      |> patch("/api/folders/#{jobs.id}", %{"to_board" => "huntapi", "contents" => true})
      |> json_response(200)

    assert moved["folder"] == nil
    assert moved["report"]["pages"] == 1
    refute Repo.get(Folder, jobs.id)
  end

  test "a target you can't write is a 403, a clash a 422", ctx do
    %{conn: conn, user: user, hunt: hunt} = ctx
    owner = user_fixture("api-owner@example.com")
    ro = board_fixture(%{"name" => "Borrowed", "code" => "borapi"}, owner: owner)
    share_fixture(ro, user, "read")

    conn
    |> patch("/api/boards/kbapi/folders/Journal", %{"to_board" => "borapi"})
    |> json_response(403)

    {:ok, _} = Wiki.create_folder(hunt, %{"name" => "Journal"})

    body =
      conn
      |> patch("/api/boards/kbapi/folders/Journal", %{"to_board" => "huntapi"})
      |> json_response(422)

    assert inspect(body) =~ "already has a folder named Journal"
  end
end
