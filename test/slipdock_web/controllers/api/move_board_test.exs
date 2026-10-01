defmodule SlipdockWeb.API.MoveBoardTest do
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.{Access, Boards}

  setup %{conn: conn} do
    from = board_fixture(%{"name" => "Plan"})
    to = board_fixture(%{"name" => "Errands"})
    [_backlog, todo | _] = from.columns
    card = card_fixture(todo, %{"title" => "Alpha"})

    %{conn: put_req_header(conn, "accept", "application/json"), from: from, to: to, card: card}
  end

  test "POST /api/cards/:id/move with a board moves it there", %{
    conn: conn,
    from: from,
    to: to,
    card: card
  } do
    bug = tag_fixture(from, "bug")
    Boards.set_card_tags(card, [bug])

    body =
      conn
      |> post(~p"/api/cards/#{card.id}/move", %{"board" => to.code, "column" => "Backlog"})
      |> json_response(200)

    assert body["card"]["board_id"] == to.id
    assert body["card"]["column"] == "Backlog"
    assert body["card"]["tags"] == ["bug"]

    assert body["moved"] == %{
             "tags_created" => 1,
             "fields_dropped" => 0,
             "milestones_unpinned" => 0
           }

    assert Enum.map(Boards.list_tags(to.id), & &1.name) == ["bug"]
  end

  test "the board can be named, coded or numbered, and the list defaults to the first", %{
    conn: conn,
    to: to,
    card: card
  } do
    body =
      conn
      |> post(~p"/api/cards/#{card.id}/move", %{"board" => to.name})
      |> json_response(200)

    assert body["card"]["column"] == "Backlog"
    assert body["card"]["board_id"] == to.id
  end

  test "an unknown board or list says which", %{conn: conn, to: to, card: card} do
    assert %{"error" => "board not found"} =
             conn
             |> post(~p"/api/cards/#{card.id}/move", %{"board" => "nowhere"})
             |> json_response(404)

    assert %{"error" => "column \"Nowhere\" not found"} =
             conn
             |> post(~p"/api/cards/#{card.id}/move", %{
               "board" => to.code,
               "column" => "Nowhere"
             })
             |> json_response(404)
  end

  test "moving into the card's own subcards is refused", %{conn: conn, card: card} do
    {:ok, sub} = Boards.create_sub_board(card, hd(Boards.list_templates()))
    sub = Boards.get_board!(sub.id)

    assert %{"error" => message} =
             conn
             |> post(~p"/api/cards/#{card.id}/move", %{
               "board" => sub.id,
               "column" => hd(sub.columns).name
             })
             |> json_response(422)

    assert message =~ "its own subcards"
  end

  test "write access is needed on both sides", %{conn: conn, user: user, card: card} do
    other = user_fixture("elsewhere@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: other)
    {:ok, _} = Access.grant(theirs, user, "read", other)

    assert %{"error" => "forbidden: you don't edit this board"} =
             conn
             |> post(~p"/api/cards/#{card.id}/move", %{"board" => theirs.code})
             |> json_response(403)

    assert Boards.get_card!(card.id).board_id != theirs.id
  end

  test "a move with no board is still the old same-board move", %{
    conn: conn,
    card: card,
    from: from
  } do
    body =
      conn
      |> post(~p"/api/cards/#{card.id}/move", %{"column" => "Backlog", "index" => "top"})
      |> json_response(200)

    assert body["card"]["board_id"] == from.id
    assert body["card"]["column"] == "Backlog"
    refute Map.has_key?(body, "moved")
  end
end
