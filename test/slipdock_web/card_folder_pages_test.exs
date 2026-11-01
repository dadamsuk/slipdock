defmodule SlipdockWeb.CardFolderPagesTest do
  @moduledoc "Every way in that makes a page for a card files it in the card's folder."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Repo
  alias Slipdock.Wiki.{Folder, Page}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Web folders"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Web card"})
    %{conn: put_req_header(conn, "accept", "application/json"), board: board, card: card}
  end

  defp in_card_folder?(id, card) do
    page = Repo.get!(Page, id)
    page.folder_id && Repo.get!(Folder, page.folder_id).card_id == card.id
  end

  test "the write-up endpoint", %{conn: conn, card: card} do
    %{"page" => page} =
      conn |> post(~p"/api/cards/#{card.id}/pages", %{title: "Up"}) |> json_response(201)

    assert in_card_folder?(page["id"], card)
  end

  test "card on a new page, over the API", %{conn: conn, board: board, card: card} do
    %{"page" => page} =
      conn
      |> post(~p"/api/boards/#{board.id}/pages", %{title: "New", body: "b", card: card.id})
      |> json_response(201)

    assert page["title"] == "New"
    assert in_card_folder?(page["id"], card)
  end

  test "a card nobody can reach is refused", %{conn: conn, board: board} do
    theirs = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("theirs.cf@example.com"))
    card = card_fixture(hd(theirs.columns))

    conn
    |> post(~p"/api/boards/#{board.id}/pages", %{title: "New", body: "b", card: card.id})
    |> json_response(403)
  end

  test "a card that isn't there is not found", %{conn: conn, board: board} do
    conn
    |> post(~p"/api/boards/#{board.id}/pages", %{title: "New", body: "b", card: 0})
    |> json_response(404)
  end

  test "MCP write_page with a card", %{conn: conn, card: card} do
    %{"id" => id} =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "write_page",
            arguments: %{mode: "create", card: card.id, title: "By MCP", body: "b"}
          }
        })
      )
      |> json_response(200)
      |> get_in(["result", "content"])
      |> hd()
      |> Map.fetch!("text")
      |> Jason.decode!()

    assert in_card_folder?(id, card)
  end
end
