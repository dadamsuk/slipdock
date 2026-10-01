defmodule SlipdockWeb.API.PageCardsTest do
  @moduledoc "The wiki and the board reaching each other over HTTP."
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "API Wiki 3", "code" => "apiwiki3"}, owner: user)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      column: hd(board.columns)
    }
  end

  test "a card lists the pages that talk about it, pinned first", %{conn: conn, column: column} do
    card = card_fixture(column, %{"title" => "Ship it"})

    %{"page" => spec} =
      conn
      |> post("/api/boards/apiwiki3/pages", %{title: "Ship spec", body: "About ##{card.id}."})
      |> json_response(201)

    conn |> post("/api/pages/#{spec["id"]}/links", %{card: card.id}) |> json_response(200)

    assert %{"pages" => [%{"pinned" => true, "page" => page}]} =
             conn |> get("/api/cards/#{card.id}/pages") |> json_response(200)

    assert page["code"] == spec["code"]

    # …and the card itself carries them, for a client that has the card open.
    assert %{"card" => %{"docs" => [%{"pinned" => true}]}} =
             conn |> get("/api/cards/#{card.id}") |> json_response(200)
  end

  test "write it up: a page for a card, pinned, with somewhere to log", %{
    conn: conn,
    column: column
  } do
    card = card_fixture(column, %{"title" => "Fix retries"})

    assert %{"page" => page} =
             conn |> post("/api/cards/#{card.id}/pages", %{}) |> json_response(201)

    assert page["title"] == "Fix retries"
    assert page["body"] =~ "## Log"

    assert %{"pages" => [%{"pinned" => true}]} =
             conn |> get("/api/cards/#{card.id}/pages") |> json_response(200)
  end

  test "from a template, with the placeholders filled", %{conn: conn, column: column} do
    conn
    |> post("/api/boards/apiwiki3/pages", %{
      title: "Decision template",
      template: true,
      body: "# {{card.title}}\n\nDecided {{today}} on {{board.name}}. Owner: {{owner}}."
    })
    |> json_response(201)

    card = card_fixture(column, %{"title" => "Drop the queue"})

    assert %{"page" => page} =
             conn
             |> post("/api/boards/apiwiki3/pages/from-template", %{
               template: "Decision template",
               title: "Dropping the queue",
               card: card.id,
               values: %{"owner" => "ops"}
             })
             |> json_response(201)

    assert page["title"] == "Dropping the queue"
    assert page["body"] =~ "# Drop the queue"
    assert page["body"] =~ "on API Wiki 3"
    assert page["body"] =~ "Owner: ops."

    assert %{"pages" => [%{"pinned" => true}]} =
             conn |> get("/api/cards/#{card.id}/pages") |> json_response(200)
  end

  test "a page that is not a template is refused as one", %{conn: conn} do
    conn |> post("/api/boards/apiwiki3/pages", %{title: "Ordinary"}) |> json_response(201)

    assert %{"error" => error} =
             conn
             |> post("/api/boards/apiwiki3/pages/from-template", %{template: "Ordinary"})
             |> json_response(400)

    assert error =~ "is a page, not a template"
  end

  test "a passage of a page becomes a card, linked at both ends", %{conn: conn, board: board} do
    %{"page" => page} =
      conn
      |> post("/api/boards/apiwiki3/pages", %{
        title: "Findings",
        body: "Intro.\n\nRetries are wrong\nThey never stop.\n"
      })
      |> json_response(201)

    assert %{"card" => card} =
             conn
             |> post("/api/pages/#{page["id"]}/cards", %{
               text: "Retries are wrong\nThey never stop."
             })
             |> json_response(201)

    assert card["title"] == "Retries are wrong"
    assert card["description"] =~ "/boards/#{board.id}/wiki/findings"

    {:ok, reread} = Wiki.find_page(page["id"])
    assert reread.body =~ "(##{card["id"]})"
  end
end
