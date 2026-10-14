defmodule SlipdockWeb.API.OrganiseFolderTest do
  @moduledoc "A folder's Organise… over HTTP (#791): a dry run, filing, `only`, and refusals."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.Wiki

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Organised"}, owner: user)
    {:ok, inbox} = Wiki.create_folder(board, %{"name" => "Inbox"})

    tagged = fn title, tag ->
      page = page_fixture(board, %{"title" => title})
      {:ok, page} = Wiki.file_page(page, inbox)

      Slipdock.Repo.update_all(from(p in Wiki.Page, where: p.id == ^page.id),
        set: [note_tags: [tag]]
      )

      Wiki.get_page!(page.id)
    end

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      inbox: inbox,
      a: tagged.("A", "alpha"),
      b: tagged.("B", "beta")
    }
  end

  defp organise(conn, board, params),
    do: post(conn, "/api/boards/#{board.code}/organise", params)

  test "a dry run plans and changes nothing; without it the pages are filed", %{
    conn: conn,
    board: board,
    inbox: inbox,
    a: a,
    b: b
  } do
    assert %{"dry_run" => true, "plan" => plan} =
             conn
             |> organise(board, %{folder: "Inbox", mode: "tag", dry_run: true})
             |> json_response(200)

    assert Enum.map(plan, &{&1["title"], &1["to"]}) |> Enum.sort() ==
             [{"A", "Inbox/alpha"}, {"B", "Inbox/beta"}]

    assert Wiki.get_page!(a.id).folder_id == inbox.id

    assert %{"moved" => 1, "folders_made" => 1, "skipped" => []} =
             conn
             |> organise(board, %{folder: inbox.id, mode: "tag", only: ["page:#{a.id}"]})
             |> json_response(200)

    {:ok, alpha} = Wiki.find_folder(board, "Inbox/alpha")
    assert Wiki.get_page!(a.id).folder_id == alpha.id
    assert Wiki.get_page!(b.id).folder_id == inbox.id
  end

  test "a bad mode or option is a 422, a missing folder a 404, a missing mode a 400", %{
    conn: conn,
    board: board
  } do
    assert %{"error" => _} =
             conn |> organise(board, %{folder: "Inbox", mode: "shuffle"}) |> json_response(422)

    assert %{"error" => _} =
             conn
             |> organise(board, %{folder: "Inbox", mode: "date", granularity: "week"})
             |> json_response(422)

    assert conn |> organise(board, %{folder: "Nope", mode: "tag"}) |> json_response(404)
    assert conn |> organise(board, %{folder: "Inbox"}) |> json_response(400)
  end

  test "someone who can't write to the board can't organise it", %{board: board, inbox: inbox} do
    other = user_fixture("organise-outsider@example.com")
    conn = conn_as(other) |> put_req_header("accept", "application/json")
    resp = organise(conn, board, %{folder: inbox.id, mode: "tag"})
    assert resp.status in [403, 404]
    assert Wiki.get_page!(hd(Wiki.list_pages(board)).id).folder_id == inbox.id
  end
end
