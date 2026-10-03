defmodule SlipdockWeb.API.SubBoardsTest do
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  setup %{conn: conn} do
    board = board_fixture()
    card = card_fixture(hd(board.columns), %{"title" => "Epic"})
    %{conn: put_req_header(conn, "accept", "application/json"), board: board, card: card}
  end

  test "templates CRUD", %{conn: conn} do
    assert %{"templates" => ts} = conn |> get(~p"/api/templates") |> json_response(200)
    assert Enum.any?(ts, &(&1["name"] == "Slipdock"))

    body =
      conn
      |> post(~p"/api/templates", %{
        "name" => "Tiny",
        "columns" => ["A", %{"name" => "B", "wip_limit" => 1}]
      })
      |> json_response(201)

    id = body["template"]["id"]
    assert [%{"name" => "A"}, %{"name" => "B", "wip_limit" => 1}] = body["template"]["columns"]

    assert %{"template" => %{"name" => "Tiny"}} =
             conn |> get(~p"/api/templates/tiny") |> json_response(200)

    assert %{"template" => %{"name" => "Tinier"}} =
             conn |> patch(~p"/api/templates/#{id}", %{"name" => "Tinier"}) |> json_response(200)

    assert %{"error" => "validation failed"} =
             conn
             |> post(~p"/api/templates", %{"name" => "Bad", "columns" => []})
             |> json_response(422)

    assert %{"ok" => true} = conn |> delete(~p"/api/templates/#{id}") |> json_response(200)

    assert %{"error" => "template not found"} =
             conn |> get(~p"/api/templates/#{id}") |> json_response(404)
  end

  test "boards from templates and sub-boards on cards", %{conn: conn, card: card, board: board} do
    body =
      conn
      |> post(~p"/api/boards", %{"name" => "Triage", "template" => "Bug triage"})
      |> json_response(201)

    assert Enum.map(body["board"]["columns"], & &1["name"]) == [
             "New",
             "Confirmed",
             "Fixing",
             "Verify",
             "Closed"
           ]

    assert %{"error" => "template not found"} =
             conn
             |> post(~p"/api/boards", %{"name" => "X", "template" => "nope"})
             |> json_response(404)

    assert %{"error" => _} =
             conn |> post(~p"/api/cards/#{card.id}/subboard", %{}) |> json_response(400)

    body =
      conn
      |> post(~p"/api/cards/#{card.id}/subboard", %{"template" => "Simple"})
      |> json_response(201)

    sub_id = body["board"]["id"]

    assert body["board"]["parent_card"] == %{
             "id" => card.id,
             "title" => "Epic",
             "board_id" => board.id
           }

    assert body["board"]["root_id"] == board.id
    assert %{"id" => ^sub_id, "total" => 0, "completed" => 0} = body["card"]["sub_board"]
    assert length(body["card"]["sub_board"]["columns"]) == 3

    assert %{"error" => "This card already has subcards."} =
             conn
             |> post(~p"/api/cards/#{card.id}/subboard", %{"template" => "Simple"})
             |> json_response(400)

    # Cards added on the sub-board show up in the parent card's summary; roots only in the index.
    conn
    |> post(~p"/api/boards/#{sub_id}/cards", %{"title" => "Part", "completed" => true})
    |> json_response(201)

    assert %{"sub_board" => %{"total" => 1, "completed" => 1}} =
             conn |> get(~p"/api/cards/#{card.id}") |> json_response(200) |> Map.get("card")

    ids =
      conn
      |> get(~p"/api/boards")
      |> json_response(200)
      |> Map.get("boards")
      |> Enum.map(& &1["id"])

    refute sub_id in ids

    assert %{"card" => %{"sub_board" => nil}} =
             conn |> delete(~p"/api/cards/#{card.id}/subboard") |> json_response(200)

    assert %{"error" => "board not found"} =
             conn |> get(~p"/api/boards/#{sub_id}") |> json_response(404)
  end
end
