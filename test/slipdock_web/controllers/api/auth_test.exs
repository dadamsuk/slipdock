defmodule SlipdockWeb.API.AuthTest do
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.Access

  @tag :anonymous
  test "the API requires a bearer token", %{conn: conn} do
    assert %{"error" => "unauthorized" <> _} = conn |> get(~p"/api/boards") |> json_response(401)

    assert conn
           |> put_req_header("authorization", "Bearer nope")
           |> get(~p"/api/boards")
           |> json_response(401)
  end

  test "/api/me and permission checks", %{conn: conn, user: user} do
    assert %{"user" => %{"email" => "tester@example.com"}} =
             conn |> get(~p"/api/me") |> json_response(200)

    other = user_fixture("other@example.com")
    other_conn = conn_as(other)
    board = board_fixture(%{"name" => "Mine"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Card"})

    assert other_conn |> get(~p"/api/boards") |> json_response(200) |> Map.get("boards") == []

    assert %{"error" => "forbidden" <> _} =
             other_conn |> get(~p"/api/boards/#{board.id}") |> json_response(403)

    assert %{"error" => "forbidden" <> _} =
             other_conn |> get(~p"/api/cards/#{card.id}") |> json_response(403)

    {:ok, _} = Access.grant(board, other, "read", user)

    assert %{"board" => %{"name" => "Mine"}} =
             other_conn |> get(~p"/api/boards/#{board.id}") |> json_response(200)

    assert %{"error" => "forbidden" <> _} =
             other_conn
             |> patch(~p"/api/cards/#{card.id}", %{"title" => "X"})
             |> json_response(403)

    assert %{"error" => "forbidden" <> _} =
             other_conn
             |> post(~p"/api/boards/#{board.id}/cards", %{"title" => "X"})
             |> json_response(403)

    {:ok, _} = Access.grant(card, other, "write", user)

    assert %{"card" => %{"title" => "X"}} =
             other_conn
             |> patch(~p"/api/cards/#{card.id}", %{"title" => "X"})
             |> json_response(200)

    assert %{"error" => "forbidden" <> _} =
             other_conn
             |> patch(~p"/api/boards/#{board.id}", %{"name" => "Theirs"})
             |> json_response(403)

    assert %{"error" => "forbidden" <> _} =
             other_conn |> delete(~p"/api/boards/#{board.id}") |> json_response(403)

    # Boards created over the API belong to the caller.
    %{"board" => %{"id" => id}} =
      other_conn |> post(~p"/api/boards", %{"name" => "Theirs"}) |> json_response(201)

    assert Slipdock.Boards.get_board!(id).owner_id == other.id
  end
end
