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

    view |> element("#sprint-add") |> render_click()
    assert render(view) =~ "Added 2 cards to Sprint 1."

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

  describe "planning from sources" do
    test "Add cards… opens the plan over every source list, with running totals", %{
      conn: conn,
      sprints: sprints,
      work: work,
      todo: todo
    } do
      home = board_fixture(%{"name" => "Home"})
      [_, home_todo | _] = home.columns
      a = card_fixture(todo, %{"title" => "Work task", "time_estimate" => 2})
      b = card_fixture(home_todo, %{"title" => "Home task", "time_estimate" => 3})
      epic = card_fixture(todo, %{"title" => "Epic"})
      {:ok, simple} = Boards.find_template("Simple")
      {:ok, epic_board} = Boards.create_sub_board(epic, simple)
      task = card_fixture(hd(Boards.get_board!(epic_board.id).columns), %{"title" => "Inside"})

      user = user_fixture()

      {:ok, sprints} =
        Sprints.put_sources(sprints, user, [{work, ["To Do"]}, {home, ["To Do"]}])

      {:ok, sprint} = Sprints.create_sprint(sprints)

      {:ok, view, _} = live(conn, ~p"/boards/#{sprints}/cards/#{sprint.id}")
      view |> element("#card-sprint-add-cards") |> render_click()

      # Both boards on one view, without choosing one first.
      assert has_element?(view, "#plan-board-#{work.id}")
      assert has_element?(view, "#plan-board-#{home.id}")
      assert render(view) =~ "Plan #{sprint.title}"

      view |> element("#sprint-pick-#{a.id}") |> render_click()
      view |> element("#sprint-pick-#{b.id}") |> render_click()
      html = render(view)
      assert html =~ "2 cards ticked"
      assert html =~ "5h"

      # Subcards open in place, outline-style.
      view
      |> element("#plan-card-#{epic.id} button[phx-click=plan_expand]")
      |> render_click()

      assert has_element?(view, "#plan-card-#{task.id}")

      view |> element("#sprint-add") |> render_click()
      sub = Boards.get_card!(sprint.id).sub_board
      assert Boards.get_card!(a.id).board_id == sub.id
      assert Boards.get_card!(b.id).board_id == sub.id
    end

    test "the plan leaves out columns no card on the board has anything in", %{
      conn: conn,
      sprints: sprints,
      work: work,
      todo: todo
    } do
      card_fixture(todo, %{"title" => "Estimated", "time_estimate" => 2})
      card_fixture(todo, %{"title" => "Not estimated"})

      {:ok, sprints} = Sprints.put_sources(sprints, user_fixture(), [{work, ["To Do"]}])
      {:ok, sprint} = Sprints.create_sprint(sprints)

      {:ok, view, _} = live(conn, ~p"/boards/#{sprints}/cards/#{sprint.id}")
      view |> element("#card-sprint-add-cards") |> render_click()

      assert has_element?(view, "#plan-list-#{todo.id} th", "Estimate")
      refute has_element?(view, "#plan-list-#{todo.id} th", "Votes")
      refute has_element?(view, "#plan-list-#{todo.id} th", "Priority")
      refute has_element?(view, "#plan-list-#{todo.id} th", "Due")
    end

    test "the sources are chosen from the plan, and in settings", %{
      conn: conn,
      sprints: sprints,
      work: work,
      todo: todo
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      {:ok, view, _} = live(conn, ~p"/boards/#{sprints}/cards/#{sprint.id}")
      view |> element("#card-sprint-add-cards") |> render_click()
      view |> element("#plan-sources-button") |> render_click()

      view
      |> form("#plan-sources-form", %{"sources" => %{to_string(work.id) => %{"on" => "true"}}})
      |> render_change()

      view
      |> form("#plan-sources-form", %{
        "sources" => %{
          to_string(work.id) => %{"on" => "true", "lists" => [to_string(todo.id)]}
        }
      })
      |> render_submit()

      assert [%{"board_id" => id, "column_ids" => [col]}] =
               Boards.get_board!(sprints.id).sprint_sources

      assert id == work.id and col == todo.id
      assert has_element?(view, "#plan-list-#{todo.id}")

      # Settings saves as it is ticked.
      home = board_fixture(%{"name" => "Home"})
      {:ok, settings, _} = live(conn, ~p"/boards/#{sprints}/settings")
      assert has_element?(settings, "#sprint-sources-form")

      settings
      |> form("#sprint-sources-form", %{"sources" => %{to_string(home.id) => %{"on" => "true"}}})
      |> render_change()

      assert [%{"column_ids" => [^col]}, %{"board_id" => home_id, "column_ids" => []}] =
               Boards.get_board!(sprints.id).sprint_sources

      assert home_id == home.id
    end

    test "a new sprint board takes its sources from the new-board form", %{
      conn: conn,
      work: work
    } do
      {:ok, template} = Boards.find_template("Sprint planning")
      {:ok, view, _} = live(conn, ~p"/")
      render_click(view, "start_create", %{})

      view
      |> form("#new-board", %{"board" => %{"name" => "Q4 sprints"}, "template" => template.id})
      |> render_change()

      assert has_element?(view, "#new-board-sources #sprint-source-#{work.id}")

      view
      |> form("#new-board", %{
        "board" => %{"name" => "Q4 sprints"},
        "template" => template.id,
        "sources" => %{to_string(work.id) => %{"on" => "true"}}
      })
      |> render_submit()

      {:ok, board} = Boards.find_board("Q4 sprints")
      assert [%{"board_id" => id}] = board.sprint_sources
      assert id == work.id
    end
  end

  test "Charts shows velocity and a burndown, on the sprint board and the sprint's own", %{
    conn: conn,
    sprints: sprints,
    work: work,
    todo: todo
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{work}")
    refute has_element?(view, "#sprint-charts")

    {:ok, one} = Sprints.create_sprint(sprints, %{"start" => Date.add(Date.utc_today(), -20)})
    {:ok, two} = Sprints.create_sprint(sprints)
    a = card_fixture(todo, %{"title" => "A"})
    b = card_fixture(todo, %{"title" => "B"})
    {:ok, _} = Sprints.add_cards(two, [a, b])
    {:ok, _} = Boards.update_card(Boards.get_card!(a.id), %{"completed" => true})

    {:ok, view, _} = live(conn, ~p"/boards/#{sprints}")
    view |> element("#sprint-charts") |> render_click()
    assert has_element?(view, "#velocity-chart")
    assert has_element?(view, "#burndown-#{two.id}")
    assert render(view) =~ "1 of 2 cards done"

    view |> form("#chart-sprint-form", %{"sprint" => "#{one.id}"}) |> render_change()
    refute has_element?(view, "#burndown-#{two.id}")
    assert render(view) =~ "Nothing in this sprint yet"

    {:ok, view, _} = live(conn, ~p"/boards/#{Boards.get_card!(two.id).sub_board.id}")
    view |> element("#sprint-charts") |> render_click()
    assert has_element?(view, "#burndown-#{two.id}")
    refute has_element?(view, "#velocity-chart")
  end

  describe "stand-ins" do
    test "the board a card left shows a stand-in that opens the real card", %{
      conn: conn,
      sprints: sprints,
      work: work,
      todo: todo
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      card = card_fixture(todo, %{"title" => "Fix the login bug"})
      {:ok, %{added: [moved]}} = Sprints.add_cards(sprint, [card])
      [stand_in] = Boards.stand_ins_for(moved.id)

      {:ok, view, html} = live(conn, ~p"/boards/#{work}")
      assert has_element?(view, "#card-#{stand_in.id}[data-stand-in='#{moved.id}']")
      assert html =~ "Fix the login bug"
      assert html =~ sprint.title

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#card-#{stand_in.id}") |> render_click()

      assert to == "/boards/#{moved.board_id}/cards/#{moved.id}"
    end

    test "somebody who can't see the sprint sees the stand-in but can't open it", %{
      conn: conn,
      todo: todo,
      work: work
    } do
      {:ok, template} = Boards.find_template("Sprint planning")
      other = user_fixture("elsewhere@example.com")
      theirs = board_fixture(%{"name" => "Their sprints"}, template: template, owner: other)
      {:ok, sprint} = Sprints.create_sprint(theirs)

      {:ok, %{added: [moved]}} =
        Sprints.add_cards(sprint, [card_fixture(todo, %{"title" => "Secret-ish"})])

      [stand_in] = Boards.stand_ins_for(moved.id)

      {:ok, view, html} = live(conn, ~p"/boards/#{work}")
      assert html =~ "Secret-ish"

      assert view |> element("#card-#{stand_in.id}") |> render_click() =~
               "That card is on a board you can&#39;t open."
    end

    test "a stand-in can be dismissed, and is not counted in its list", %{
      conn: conn,
      sprints: sprints,
      work: work,
      todo: todo
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      {:ok, %{added: [moved]}} = Sprints.add_cards(sprint, [card_fixture(todo)])
      [stand_in] = Boards.stand_ins_for(moved.id)

      {:ok, view, _} = live(conn, ~p"/boards/#{work}")
      assert view |> element("#column-#{todo.id} .badge") |> render() =~ "0 cards"

      view
      |> element("#card-#{stand_in.id} button[phx-click*='dismiss_stand_in']")
      |> render_click()

      refute has_element?(view, "#card-#{stand_in.id}")
      assert Boards.stand_ins_for(moved.id) == []
    end
  end
end
