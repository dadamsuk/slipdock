defmodule SlipdockWeb.API.PageNoteTagsTest do
  @moduledoc "Note tags over the API and MCP, and on the page: on a board in a vault only."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Brain", "code" => "brainapi"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})

    {:ok, a} =
      Wiki.create_page(board, %{"title" => "A", "body" => "#area/sub and #solo"}, user: user)

    {:ok, b} = Wiki.create_page(board, %{"title" => "B", "body" => "#area"}, user: user)
    %{conn: put_req_header(conn, "accept", "application/json"), board: board, a: a, b: b}
  end

  test "a page carries note_tags, and ?note_tag= narrows a listing", %{conn: conn, a: a} do
    assert conn
           |> get("/api/pages/#{a.code}")
           |> json_response(200)
           |> get_in(["page", "note_tags"]) ==
             ["area/sub", "solo"]

    titles = fn tag ->
      conn
      |> get("/api/boards/brainapi/pages?note_tag=#{tag}")
      |> json_response(200)
      |> Map.fetch!("pages")
      |> Enum.map(& &1["title"])
      |> Enum.sort()
    end

    assert titles.("area") == ~w(A B)
    assert titles.("solo") == ~w(A)
  end

  test "the board's note tags, with counts", %{conn: conn} do
    assert conn |> get("/api/boards/brainapi/pages/tags") |> json_response(200) == %{
             "tags" => [
               %{"tag" => "area", "count" => 2},
               %{"tag" => "area/sub", "count" => 1},
               %{"tag" => "solo", "count" => 1}
             ]
           }

    assert conn |> get("/api/boards/nope/pages/tags") |> json_response(404)
  end

  test "MCP: list_pages filters by note_tag, read_page shows them", %{conn: conn, a: a} do
    call = fn tool, args ->
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

    pages = call.("list_pages", %{board: "brainapi", note_tag: "solo"})["pages"]
    assert [%{"title" => "A", "note_tags" => ["area/sub", "solo"]}] = pages
    assert call.("read_page", %{page: a.code})["note_tags"] == ["area/sub", "solo"]
  end

  test "the page shows them as chips", %{user: user, board: board, a: a} do
    {:ok, _view, html} = live(conn_as(user), ~p"/boards/#{board}/wiki/#{a.slug}")
    assert html =~ ~s(id="page-note-tags")
    assert html =~ "#area/sub"
  end
end
