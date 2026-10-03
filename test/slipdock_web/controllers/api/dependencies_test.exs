defmodule SlipdockWeb.API.DependenciesTest do
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  setup %{conn: conn} do
    board = board_fixture()
    [backlog | _] = board.columns
    a = card_fixture(backlog, %{"title" => "A"})
    b = card_fixture(backlog, %{"title" => "B"})
    %{conn: put_req_header(conn, "accept", "application/json"), a: a, b: b}
  end

  test "add, read, reject, remove", %{conn: conn, a: a, b: b} do
    body =
      conn
      |> post(~p"/api/cards/#{a.id}/dependencies", %{"blocked_by" => b.id})
      |> json_response(200)

    assert body["card"]["blocked"] == true

    assert [%{"id" => bid, "title" => "B", "completed" => false, "archived" => false}] =
             body["card"]["blocked_by"]

    assert bid == b.id

    body = conn |> get(~p"/api/cards/#{b.id}") |> json_response(200)
    assert [%{"title" => "A"}] = body["card"]["blocks"]
    assert body["card"]["blocked"] == false

    assert %{"error" => msg} =
             conn
             |> post(~p"/api/cards/#{b.id}/dependencies", %{"blocked_by" => a.id})
             |> json_response(400)

    assert msg =~ "circular"

    assert %{"error" => _} =
             conn |> post(~p"/api/cards/#{a.id}/dependencies", %{}) |> json_response(400)

    assert %{"error" => "card not found"} =
             conn
             |> post(~p"/api/cards/#{a.id}/dependencies", %{"blocks" => 999_999})
             |> json_response(404)

    body = conn |> delete(~p"/api/cards/#{b.id}/dependencies/#{a.id}") |> json_response(200)
    assert body["card"]["blocks"] == []
  end
end
