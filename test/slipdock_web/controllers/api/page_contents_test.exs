defmodule SlipdockWeb.API.PageContentsTest do
  @moduledoc """
  The card contents a page carries, over HTTP: comments, status updates, a
  checklist, web links and votes.

  These mirror `CardController`'s endpoints one for one, because they write
  the same rows in the same tables (see `Slipdock.Boards.Owned`). The tests
  worth having are the ones that could go wrong *because* the tables are
  shared: a row landing on the wrong owner, and a delete route reaching
  something it should not.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "API Contents", "code" => "apicont"}, owner: user)
    conn = put_req_header(conn, "accept", "application/json")

    %{"page" => page} =
      conn
      |> post("/api/boards/apicont/pages", %{title: "Retry policy"})
      |> json_response(201)

    %{conn: conn, board: board, column: hd(board.columns), page: page}
  end

  test "a page takes a comment, and gives it back with the page", %{conn: conn, page: page} do
    assert %{"comment" => %{"id" => id, "body" => "reads well"}} =
             conn
             |> post("/api/pages/#{page["id"]}/comments", %{body: "reads well"})
             |> json_response(201)

    assert %{"page" => %{"comments" => [%{"id" => ^id}]}} =
             conn |> get("/api/pages/#{page["id"]}") |> json_response(200)

    # The shared delete route reaches a page's comment as well as a card's.
    assert conn |> delete("/api/comments/#{id}") |> json_response(200)

    assert %{"page" => %{"comments" => []}} =
             conn |> get("/api/pages/#{page["id"]}") |> json_response(200)
  end

  test "a page reports its health", %{conn: conn, page: page} do
    assert %{"page" => %{"stated_health" => "at_risk", "status_updates" => [update]}} =
             conn
             |> post("/api/pages/#{page["id"]}/status", %{health: "at_risk", body: "stalled"})
             |> json_response(201)

    assert update["body"] == "stalled"
  end

  test "a page takes checklist items, and the shared routes tick and remove them", %{
    conn: conn,
    page: page
  } do
    assert %{"item" => %{"id" => id, "text" => "outline"}} =
             conn
             |> post("/api/pages/#{page["id"]}/checklist", %{text: "outline"})
             |> json_response(201)

    assert %{"item" => %{"done" => true}} =
             conn |> post("/api/checklist/#{id}/toggle") |> json_response(200)

    assert %{"page" => %{"checklist" => %{"done" => 1, "total" => 1}}} =
             conn |> get("/api/pages/#{page["id"]}") |> json_response(200)

    assert conn |> delete("/api/checklist/#{id}") |> json_response(200)
  end

  test "a page links out, and only its own link can be removed", %{
    conn: conn,
    page: page,
    column: column
  } do
    card = card_fixture(column, %{"title" => "The work"})

    assert %{"url" => %{"id" => mine, "url" => "https://example.com/spec"}} =
             conn
             |> post("/api/pages/#{page["id"]}/urls", %{url: "example.com/spec"})
             |> json_response(201)

    %{"url" => %{"id" => theirs}} =
      conn |> post("/api/cards/#{card.id}/urls", %{url: "example.com/work"}) |> json_response(201)

    # The card's link is not the page's to remove.
    assert conn |> delete("/api/pages/#{page["id"]}/urls/#{theirs}") |> json_response(404)
    assert conn |> delete("/api/pages/#{page["id"]}/urls/#{mine}") |> json_response(200)

    assert %{"page" => %{"urls" => []}} =
             conn |> get("/api/pages/#{page["id"]}") |> json_response(200)
  end

  test "a page takes votes out of the board's budget", %{conn: conn, page: page} do
    assert %{"my_votes" => 2, "page" => %{"votes" => 2}} =
             conn |> post("/api/pages/#{page["id"]}/vote", %{count: 2}) |> json_response(200)

    assert %{"my_votes" => 0, "page" => %{"votes" => 0}} =
             conn |> post("/api/pages/#{page["id"]}/vote", %{count: 0}) |> json_response(200)
  end

  test "custom fields are set on a page the way they are on a card", %{
    conn: conn,
    board: board,
    page: page
  } do
    {:ok, _} = Slipdock.Fields.create_field(board, %{"name" => "Effort", "kind" => "number"})

    assert %{"page" => %{"fields" => %{"effort" => 3.0}}} =
             conn
             |> patch("/api/pages/#{page["id"]}", %{fields: %{"effort" => 3}})
             |> json_response(200)
  end

  test "someone with no access to the board cannot comment on its pages", %{page: page} do
    outsider = user_fixture("contents.outsider@example.com")

    conn = conn_as(outsider) |> put_req_header("accept", "application/json")

    assert %{"error" => error} =
             conn
             |> post("/api/pages/#{page["id"]}/comments", %{body: "hello"})
             |> json_response(403)

    assert error =~ "forbidden"
  end
end
