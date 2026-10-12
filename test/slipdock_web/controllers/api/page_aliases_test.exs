defmodule SlipdockWeb.API.PageAliasesTest do
  @moduledoc "Aliases over the API and MCP: shown on a page, set through its front matter, found by resolve."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Brain", "code" => "aliasapi"}, owner: user)
    {:ok, page} = Wiki.create_page(board, %{"title" => "Retry policy", "body" => "x"}, user: user)
    %{conn: put_req_header(conn, "accept", "application/json"), page: page}
  end

  test "setting front matter aliases makes the page answer to them", %{conn: conn, page: page} do
    body =
      conn
      |> patch("/api/pages/#{page.code}", %{"front_matter" => "aliases: [Retries]"})
      |> json_response(200)

    assert body["page"]["aliases"] == ["Retries"]

    resolved =
      conn |> get("/api/pages/resolve?board=aliasapi&title=retries") |> json_response(200)

    assert resolved["found"] == true
    assert resolved["page"]["code"] == page.code

    mcp =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "read_page", arguments: %{page: page.code}}
        })
      )
      |> json_response(200)

    assert get_in(mcp, ["result", "structuredContent", "aliases"]) == ["Retries"]
  end

  test "a page with none has an empty list, and an unknown name is not found", %{
    conn: conn,
    page: page
  } do
    assert conn
           |> get("/api/pages/#{page.code}")
           |> json_response(200)
           |> get_in(["page", "aliases"]) == []

    assert conn
           |> get("/api/pages/resolve?board=aliasapi&title=Retries")
           |> json_response(200)
           |> Map.get("found") == false
  end
end
