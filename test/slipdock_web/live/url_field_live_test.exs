defmodule SlipdockWeb.UrlFieldLiveTest do
  @moduledoc """
  URL fields in the page and through the API (#3613): a reader sees the
  host as a link opening in a new tab, a writer types a link, and a
  non-http(s) value is refused at every door.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Fields}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Reading list"}, owner: user)
    [_backlog, todo | _] = board.columns
    {:ok, link} = Fields.create_field(board, %{"name" => "Link", "kind" => "url"})
    card = card_fixture(todo, %{"title" => "An article"})
    {:ok, _} = Fields.set_value(card, link, "https://www.example.com/read?id=7")
    %{board: board, link: link, card: card}
  end

  test "a reader's table shows the host, linked, opening in a new tab",
       %{board: board, link: link, card: card, user: user} do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)

    {:ok, view, _} =
      live(
        log_in_user(build_conn(), reader),
        ~p"/boards/#{board}/table?fields=title,f:#{link.id}"
      )

    a =
      ~s|#row-all-#{card.id} a[data-role="field-link"][href="https://www.example.com/read?id=7"]|

    assert has_element?(view, a, "example.com")
    assert has_element?(view, ~s|#{a}[target="_blank"][rel="noopener noreferrer"]|)
  end

  test "a writer's table cell is a URL box, with the link beside it",
       %{conn: conn, board: board, link: link, card: card} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,f:#{link.id}")
    cell = "#row-all-#{card.id} [data-field-cell=link]"

    assert has_element?(
             view,
             ~s|#{cell} input[type="url"][value="https://www.example.com/read?id=7"]|
           )

    assert has_element?(view, ~s|#{cell} a[target="_blank"]|, "example.com")

    view |> form("#{cell} form", %{"value" => "javascript:alert(1)"}) |> render_change()
    assert render(view) =~ "Link needs an http or https link"

    assert Fields.value(Boards.Cards.get_card!(card.id), link) ==
             "https://www.example.com/read?id=7"
  end

  test "REST and MCP refuse a link that isn't http(s)", %{user: user, card: card, link: link} do
    {token, _} = Accounts.create_api_token(user, "url", scope: "write")

    api =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

    assert %{"error" => error} =
             api
             |> patch("/api/cards/#{card.id}", %{fields: %{"link" => "javascript:alert(1)"}})
             |> json_response(422)

    assert error =~ "http or https"

    result =
      api
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "update_card",
            arguments: %{card: card.id, fields: %{"link" => "ftp://example.com"}}
          }
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert result["isError"] == true

    assert Fields.value(Boards.Cards.get_card!(card.id), link) ==
             "https://www.example.com/read?id=7"
  end
end
