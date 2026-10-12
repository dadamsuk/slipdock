defmodule SlipdockWeb.API.PageFrontMatterTest do
  @moduledoc """
  A page's front matter over the API, MCP and in the page view: read as the
  YAML between the `---` lines, written back keeping the header it came in.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki
  alias Slipdock.Wiki.Archive

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Notes", "code" => "fmapi"}, owner: user)
    file = "---\r\n# mine\r\nrating: 5\r\n---\r\n\r\nBody"
    %{created: [page]} = Archive.import_files(board, [{"Note.md", file}], user: user)
    %{conn: put_req_header(conn, "accept", "application/json"), board: board, page: page}
  end

  test "GET shows the YAML; a page without any shows null", %{
    conn: conn,
    board: board,
    user: user,
    page: page
  } do
    assert conn
           |> get("/api/pages/#{page.code}")
           |> json_response(200)
           |> get_in(["page", "front_matter"]) ==
             "# mine\r\nrating: 5"

    {:ok, plain} = Wiki.create_page(board, %{"title" => "Plain"}, user: user)

    assert conn
           |> get("/api/pages/#{plain.code}")
           |> json_response(200)
           |> get_in(["page", "front_matter"]) == nil
  end

  test "PATCH replaces the YAML inside the header it came in", %{conn: conn, page: page} do
    body =
      conn
      |> patch("/api/pages/#{page.code}", %{"front_matter" => "rating: 4\n"})
      |> json_response(200)

    assert body["page"]["front_matter"] == "rating: 4"
    assert Wiki.get_page!(page.id).front_matter == "---\r\nrating: 4\r\n---\r\n\r\n"
    # The body was not touched.
    assert Wiki.get_page!(page.id).body == "Body"
  end

  test "PATCH with \"\" clears it; with a --- line, refuses", %{conn: conn, page: page} do
    assert %{"error" => error} =
             conn
             |> patch("/api/pages/#{page.code}", %{"front_matter" => "a: 1\n---\nb: 2"})
             |> json_response(422)

    assert error =~ "---"
    assert conn |> patch("/api/pages/#{page.code}", %{"front_matter" => 5}) |> json_response(422)

    conn |> patch("/api/pages/#{page.code}", %{"front_matter" => ""}) |> json_response(200)
    assert Wiki.get_page!(page.id).front_matter == nil
  end

  test "POST can start a page with front matter", %{conn: conn} do
    page =
      conn
      |> post("/api/boards/fmapi/pages", %{"title" => "New", "front_matter" => "source: web"})
      |> json_response(201)
      |> Map.fetch!("page")

    assert page["front_matter"] == "source: web"
    assert Wiki.get_page!(page["id"]).front_matter == "---\nsource: web\n---\n\n"
  end

  test "the page's Markdown download keeps it", %{user: user, board: board, page: page} do
    md = conn_as(user) |> get("/boards/#{board.id}/wiki/#{page.slug}/page.md") |> response(200)
    assert md =~ "# mine\r\nrating: 5\r\n"
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
      |> get_in(["result", "structuredContent"])
    end

    test "read_page gives it and update_page sets it", %{conn: conn, page: page} do
      assert call(conn, "read_page", %{page: page.code})["front_matter"] == "# mine\r\nrating: 5"
      call(conn, "update_page", %{page: page.code, front_matter: "rating: 1"})
      assert Wiki.get_page!(page.id).front_matter == "---\r\nrating: 1\r\n---\r\n\r\n"
    end
  end

  test "the page view folds it into a Properties block", %{
    board: board,
    user: user,
    page: page
  } do
    conn = conn_as(user)
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert html =~ ~s(id="page-properties")
    assert html =~ "rating: 5"

    {:ok, plain} = Wiki.create_page(board, %{"title" => "Plain", "body" => "x"}, user: user)
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki/#{plain.slug}")
    refute html =~ ~s(id="page-properties")
  end
end
