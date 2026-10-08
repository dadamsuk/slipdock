defmodule SlipdockWeb.API.ViewsTest do
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup %{conn: conn} do
    board = board_fixture(%{"name" => "API Board"})
    [backlog, todo | _] = board.columns
    bug = tag_fixture(board, "bug")
    a = card_fixture(backlog, %{"title" => "Alpha", "priority" => "high"})
    _b = card_fixture(todo, %{"title" => "Bravo", "priority" => "low"})
    Boards.toggle_card_tag(a, bug)
    %{conn: put_req_header(conn, "accept", "application/json"), board: board, bug: bug}
  end

  test "GET /api/boards/:board/swimlanes returns the grid", %{conn: conn, board: board} do
    body =
      conn
      |> get(~p"/api/boards/#{board.id}/swimlanes?rows=tag&cols=column&empty=show")
      |> json_response(200)

    assert body["config"]["rows"] == "tag"
    assert Enum.map(body["rows"], & &1["label"]) == ["bug", "No tag"]
    assert length(body["cols"]) == 4

    assert [
             [[%{"title" => "Alpha", "column" => "Backlog"}], [], [], []],
             [[], [%{"title" => "Bravo"}], [], []]
           ] = body["cells"]

    assert body["shown"] == 2
  end

  test "a grid holds all three kinds, and kinds= narrows it", %{conn: conn, board: board} do
    # A placed page stands beside the cards in every view, so it comes back
    # from a grid too — as the page it is, not as a card.
    page = page_fixture(board, %{"title" => "Retro notes"})
    {:ok, _} = Slipdock.Wiki.place(page, hd(board.columns))

    body =
      conn
      |> get(~p"/api/boards/#{board.id}/swimlanes?rows=none&cols=none")
      |> json_response(200)

    assert body["shown"] == 3
    [[cells]] = body["cells"]

    assert %{"title" => "Retro notes", "kind" => "page"} =
             Enum.find(cells, &(&1["kind"] == "page"))

    pages =
      conn
      |> get(~p"/api/boards/#{board.id}/swimlanes?rows=none&cols=none&kinds=page")
      |> json_response(200)

    assert pages["shown"] == 1
    assert pages["hidden"] == 2
    assert pages["config"]["kinds"] == ["page"]
  end

  test "tags and lists may be referenced by name; unknown ones are a 400", %{
    conn: conn,
    board: board
  } do
    body =
      conn
      |> get(~p"/api/boards/#{board.name}/swimlanes?rows=none&cols=none&tags=bug&columns=Backlog")
      |> json_response(200)

    assert body["shown"] == 1

    assert %{"error" => "tag not found: nope"} =
             conn |> get(~p"/api/boards/#{board.id}/swimlanes?tags=nope") |> json_response(400)
  end

  test "views CRUD", %{conn: conn, board: board, bug: bug} do
    body =
      conn
      |> post(~p"/api/boards/#{board.id}/views", %{
        "name" => "Bugs",
        "rows" => "tag",
        "tags" => ["bug"],
        "sort" => "title"
      })
      |> json_response(201)

    bug_id = bug.id

    assert %{
             "id" => id,
             "name" => "Bugs",
             "config" => %{"rows" => "tag", "tags" => [^bug_id], "sort" => "title"}
           } = body["view"]

    assert body["view"]["url"] == "/boards/#{board.id}/swimlanes?view=#{id}"

    assert [%{"name" => "Bugs"}] =
             conn
             |> get(~p"/api/boards/#{board.id}/views")
             |> json_response(200)
             |> Map.get("views")

    assert %{"view" => %{"name" => "Bugs"}} =
             conn |> get(~p"/api/boards/#{board.id}/views/bugs") |> json_response(200)

    # The grid honours ?view= and lets params override it.
    grid = conn |> get(~p"/api/boards/#{board.id}/swimlanes?view=Bugs") |> json_response(200)

    assert grid["view"]["name"] == "Bugs" and grid["config"]["sort"] == "title" and
             grid["shown"] == 1

    grid =
      conn |> get(~p"/api/boards/#{board.id}/swimlanes?view=Bugs&tags=") |> json_response(200)

    assert grid["shown"] == 2

    body =
      conn
      |> patch(~p"/api/boards/#{board.id}/views/#{id}", %{"name" => "Bug list", "dir" => "desc"})
      |> json_response(200)

    assert %{
             "name" => "Bug list",
             "config" => %{"dir" => "desc", "rows" => "tag", "sort" => "title"}
           } = body["view"]

    assert %{"error" => "validation failed"} =
             conn
             |> post(~p"/api/boards/#{board.id}/views", %{"name" => "Bug list"})
             |> json_response(422)

    assert %{"ok" => true} =
             conn |> delete(~p"/api/boards/#{board.id}/views/#{id}") |> json_response(200)

    assert %{"error" => "view not found"} =
             conn |> get(~p"/api/boards/#{board.id}/views/#{id}") |> json_response(404)
  end

  test "a view saved through the API keeps a list width, and a bad one is dropped", %{
    conn: conn,
    board: board
  } do
    body =
      conn
      |> post(~p"/api/boards/#{board.id}/views", %{"name" => "Wide", "width" => "wide"})
      |> json_response(201)

    assert body["view"]["config"]["width"] == "wide"

    body =
      conn
      |> post(~p"/api/boards/#{board.id}/views", %{
        "name" => "Odd",
        "config" => %{"width" => "enormous"}
      })
      |> json_response(201)

    assert body["view"]["config"]["width"] == "normal"
  end
end
