defmodule SlipdockWeb.SprintsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Sprints}

  setup do
    {:ok, template} = Boards.find_template("Sprint planning")
    sprints = board_fixture(%{"name" => "Sprints"}, template: template)
    work = board_fixture(%{"name" => "Work"})
    [_backlog, todo | _] = work.columns
    %{sprints: sprints, work: work, todo: todo}
  end

  test "an ordinary board has no New sprint", %{conn: conn, work: work} do
    {:ok, view, _} = live(conn, ~p"/boards/#{work}")
    refute has_element?(view, "#new-sprint")
  end

  test "New sprint makes the card and goes straight on to picking its cards", %{
    conn: conn,
    sprints: sprints,
    work: work,
    todo: todo
  } do
    a = card_fixture(todo, %{"title" => "Write the release notes"})
    b = card_fixture(todo, %{"title" => "Fix the login bug"})
    stays = card_fixture(todo, %{"title" => "Not this time"})

    {:ok, view, _} = live(conn, ~p"/boards/#{sprints}")
    view |> element("#new-sprint") |> render_click()
    assert has_element?(view, "#new-sprint-form input[value='Sprint 1']")

    view
    |> form("#new-sprint-form", sprint: %{"name" => "Sprint 1", "days" => "10"})
    |> render_submit()

    [sprint] = Boards.get_board!(sprints.id).columns |> hd() |> Map.get(:cards)
    assert sprint.title == "Sprint 1"
    assert sprint.due_date == Date.add(sprint.start_date, 9)

    # With one other board to choose, the picker opens on it.
    assert has_element?(view, "#sprint-picker")
    assert has_element?(view, "#sprint-pick-#{a.id}")

    view |> element("#sprint-pick-#{a.id}") |> render_click()
    view |> element("#sprint-pick-#{b.id}") |> render_click()
    assert render(view) =~ "2 cards ticked"

    html = view |> element("#sprint-add") |> render_click()
    assert html =~ "Added 2 cards to Sprint 1."

    sub = Boards.get_card!(sprint.id).sub_board
    assert Boards.get_card!(a.id).board_id == sub.id
    assert Boards.get_card!(b.id).board_id == sub.id
    assert Boards.get_card!(stays.id).board_id == work.id
  end

  test "tick all takes a whole list, and subcards can be stepped into", %{
    conn: conn,
    sprints: sprints,
    work: work,
    todo: todo
  } do
    {:ok, sprint} = Sprints.create_sprint(sprints)
    _other = board_fixture(%{"name" => "Home"})
    epic = card_fixture(todo, %{"title" => "Epic"})
    {:ok, simple} = Boards.find_template("Simple")
    {:ok, epic_board} = Boards.create_sub_board(epic, simple)
    epic_board = Boards.get_board!(epic_board.id)
    task = card_fixture(hd(epic_board.columns), %{"title" => "A task in the epic"})
    task2 = card_fixture(hd(epic_board.columns), %{"title" => "Another task"})

    # From the sprint's own sub-board, whose toolbar offers Add cards….
    {:ok, view, _} = live(conn, ~p"/boards/#{sprint.sub_board.id}")
    view |> element("#sprint-add-cards") |> render_click()

    # Several boards to choose from: the list comes first.
    view
    |> element("#sprint-picker button[phx-click=sprint_source][phx-value-id='#{work.id}']")
    |> render_click()

    view
    |> element("#sprint-picker button[phx-click=sprint_into][phx-value-id='#{epic_board.id}']")
    |> render_click()

    view
    |> element("#sprint-picker button[phx-click=sprint_toggle_list]")
    |> render_click()

    assert render(view) =~ "2 cards ticked"
    view |> element("#sprint-add") |> render_click()

    assert Boards.get_card!(task.id).board_id == sprint.sub_board.id
    assert Boards.get_card!(task2.id).board_id == sprint.sub_board.id
    # The epic stays where it was; only its tasks went.
    assert Boards.get_card!(epic.id).board_id == work.id
  end

  test "the open sprint card offers Add cards…", %{conn: conn, sprints: sprints} do
    {:ok, sprint} = Sprints.create_sprint(sprints)
    {:ok, view, _} = live(conn, ~p"/boards/#{sprints}/cards/#{sprint.id}")
    view |> element("#card-sprint-add-cards") |> render_click()
    assert has_element?(view, "#sprint-picker")
  end

  test "a board is made a sprint board in its settings", %{conn: conn, work: work} do
    {:ok, view, _} = live(conn, ~p"/boards/#{work}/settings")

    view
    |> form("#board-form", board: %{"kind" => "sprints"})
    |> render_submit()

    assert Boards.get_board!(work.id).kind == "sprints"
  end
end
