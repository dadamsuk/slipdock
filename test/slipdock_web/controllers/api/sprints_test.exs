defmodule SlipdockWeb.API.SprintsTest do
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup %{conn: conn} do
    sprints = board_fixture(%{"name" => "Sprints", "kind" => "sprints"})
    work = board_fixture(%{"name" => "Work"})
    [_backlog, todo | _] = work.columns

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      sprints: sprints,
      work: work,
      todo: todo
    }
  end

  test "a board says what kind it is, and can be made a sprint board", %{
    conn: conn,
    sprints: sprints,
    work: work
  } do
    assert conn
           |> get(~p"/api/boards/#{sprints.code}")
           |> json_response(200)
           |> get_in(["board", "kind"]) ==
             "sprints"

    body =
      conn |> patch(~p"/api/boards/#{work.code}", %{"kind" => "sprints"}) |> json_response(200)

    assert body["board"]["kind"] == "sprints"

    body = conn |> patch(~p"/api/boards/#{work.code}", %{"kind" => "nope"}) |> json_response(422)
    assert body["details"]["kind"]
  end

  test "the Sprint planning template is listed with its kind", %{conn: conn} do
    templates = conn |> get(~p"/api/templates") |> json_response(200) |> Map.get("templates")
    assert %{"kind" => "sprints"} = Enum.find(templates, &(&1["name"] == "Sprint planning"))
  end

  test "POST /api/boards/:board/sprints makes the next sprint", %{conn: conn, sprints: sprints} do
    next = conn |> get(~p"/api/boards/#{sprints.code}/sprints/next") |> json_response(200)
    assert next["next"]["name"] == "Sprint 1"

    body =
      conn
      |> post(~p"/api/boards/#{sprints.code}/sprints", %{"start" => "2027-01-04", "days" => 7})
      |> json_response(201)

    assert body["card"]["title"] == "Sprint 1"
    assert body["card"]["start_date"] == "2027-01-04"
    assert body["card"]["due_date"] == "2027-01-10"
    assert body["card"]["sub_board"]["id"] == Boards.get_card!(body["card"]["id"]).sub_board.id
  end

  test "a board that is not a sprint board says so", %{conn: conn, work: work} do
    body = conn |> post(~p"/api/boards/#{work.code}/sprints", %{}) |> json_response(422)
    assert body["error"] =~ "not a sprint board"
  end

  test "POST /api/cards/:id/sprint moves the cards in, and says what it skipped", %{
    conn: conn,
    sprints: sprints,
    todo: todo
  } do
    {:ok, sprint} = Slipdock.Sprints.create_sprint(sprints)
    a = card_fixture(todo, %{"title" => "A"})

    body =
      conn
      |> post(~p"/api/cards/#{sprint.id}/sprint", %{"cards" => [a.id, sprint.id]})
      |> json_response(200)

    assert body["added"] == [%{"id" => a.id, "title" => "A"}]
    assert [%{"id" => id, "reason" => "it is the sprint"}] = body["skipped"]
    assert id == sprint.id
    assert Boards.get_card!(a.id).board_id == sprint.sub_board.id

    assert conn |> post(~p"/api/cards/#{sprint.id}/sprint", %{}) |> json_response(400)
  end

  test "cards on a board the caller cannot change are refused", %{conn: conn, sprints: sprints} do
    {:ok, sprint} = Slipdock.Sprints.create_sprint(sprints)
    theirs = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("other@example.com"))
    card = card_fixture(hd(theirs.columns))

    conn
    |> post(~p"/api/cards/#{sprint.id}/sprint", %{"cards" => [card.id]})
    |> json_response(403)

    assert Boards.get_card!(card.id).board_id == theirs.id
  end

  test "a sprint's burndown and a sprint board's velocity", %{
    conn: conn,
    sprints: sprints,
    work: work,
    todo: todo
  } do
    {:ok, sprint} = Slipdock.Sprints.create_sprint(sprints, %{"days" => "3"})
    a = card_fixture(todo)
    b = card_fixture(todo)
    {:ok, _} = Slipdock.Sprints.add_cards(sprint, [a, b])
    {:ok, _} = Boards.update_card(Boards.get_card!(a.id), %{"completed" => true})

    body = conn |> get(~p"/api/cards/#{sprint.id}/burndown") |> json_response(200)
    assert %{"total" => 2, "done" => 1, "days" => [today | _]} = body["burndown"]
    assert today["remaining"] == 1
    assert today["ideal"] == 2.0

    body = conn |> get(~p"/api/boards/#{sprints.code}/sprints/velocity") |> json_response(200)

    assert [%{"title" => "Sprint 1", "committed" => 2, "completed" => 1, "finished" => false}] =
             body["velocity"]["sprints"]

    assert body["velocity"]["average"] == nil

    assert conn |> get(~p"/api/cards/#{a.id}/burndown") |> json_response(422)
    assert conn |> get(~p"/api/boards/#{work.code}/sprints/velocity") |> json_response(422)
  end
end
