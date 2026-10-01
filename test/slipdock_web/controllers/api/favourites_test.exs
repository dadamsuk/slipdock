defmodule SlipdockWeb.API.FavouritesTest do
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.{Boards, Favourites}

  setup %{conn: conn} do
    board = board_fixture(%{"name" => "API Board"})
    [_backlog, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Alpha"})

    {:ok, view} =
      Boards.create_saved_view(board, %{"name" => "Bugs", "config" => %{"rows" => "tag"}})

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      todo: todo,
      card: card,
      view: view
    }
  end

  test "the list starts empty and every kind can join it", %{
    conn: conn,
    board: board,
    todo: todo,
    card: card,
    view: view
  } do
    assert %{"favourites" => []} = conn |> get(~p"/api/favourites") |> json_response(200)

    for {kind, id} <- [
          {"board", board.id},
          {"column", todo.id},
          {"card", card.id},
          {"view", view.id}
        ] do
      assert %{"favourites" => _} =
               conn
               |> post(~p"/api/favourites", %{"kind" => kind, "id" => id})
               |> json_response(200)
    end

    body = conn |> get(~p"/api/favourites") |> json_response(200)
    assert Enum.map(body["favourites"], & &1["kind"]) == ~w(board column card view)

    assert [
             %{"name" => "API Board", "url" => board_url},
             %{"name" => "To Do", "url" => list_url},
             %{"name" => "Alpha", "url" => card_url},
             %{"name" => "Bugs", "url" => view_url}
           ] = body["favourites"]

    assert board_url == "/boards/#{board.id}"
    assert list_url == "/boards/#{board.id}?list=#{todo.id}"
    assert card_url == "/boards/#{board.id}/cards/#{card.id}"
    assert view_url == "/boards/#{board.id}/swimlanes?view=#{view.id}"

    assert Enum.all?(body["favourites"], &(&1["board"]["code"] == board.code))
  end

  test "both writes are idempotent", %{conn: conn, card: card, user: user} do
    for _ <- 1..2,
        do:
          conn |> post(~p"/api/favourites", %{"kind" => "card", "id" => card.id}) |> response(200)

    assert Favourites.count(user) == 1

    for _ <- 1..2, do: conn |> delete(~p"/api/favourites/card/#{card.id}") |> response(200)
    assert Favourites.count(user) == 0
  end

  test "a bad kind or id is a 400", %{conn: conn, card: card} do
    assert %{"error" => "kind must be" <> _} =
             conn
             |> post(~p"/api/favourites", %{"kind" => "nonsense", "id" => card.id})
             |> json_response(400)

    assert %{"error" => "id must be a number"} =
             conn
             |> post(~p"/api/favourites", %{"kind" => "card", "id" => "many"})
             |> json_response(400)

    assert %{"error" => "kind and id are required"} =
             conn |> post(~p"/api/favourites", %{}) |> json_response(400)
  end

  test "favouriting something you cannot read is a 404", %{conn: conn, user: user} do
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Not yours"}, owner: stranger)
    [column | _] = theirs.columns

    assert %{"error" => "not found"} =
             conn
             |> post(~p"/api/favourites", %{"kind" => "column", "id" => column.id})
             |> json_response(404)

    assert Favourites.count(user) == 0
  end

  test "a view reports the reading user's own mark, not the board's", %{
    conn: conn,
    board: board,
    view: view
  } do
    assert [%{"favourite" => false}] =
             conn
             |> get(~p"/api/boards/#{board.id}/views")
             |> json_response(200)
             |> Map.get("views")

    conn |> post(~p"/api/favourites", %{"kind" => "view", "id" => view.id}) |> response(200)

    assert [%{"favourite" => true}] =
             conn
             |> get(~p"/api/boards/#{board.id}/views")
             |> json_response(200)
             |> Map.get("views")

    assert %{"view" => %{"favourite" => true}} =
             conn |> get(~p"/api/boards/#{board.id}/views/Bugs") |> json_response(200)

    assert %{"view" => %{"favourite" => true}} =
             conn
             |> get(~p"/api/boards/#{board.id}/swimlanes?view=Bugs")
             |> json_response(200)
  end
end
