defmodule SlipdockWeb.SprintsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo, Sprints}
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.Column

  setup do
    {:ok, template} = Boards.Templates.find_template(nil, "Sprint planning")
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

    sub = Boards.Cards.get_card!(sprint.id).sub_board
    assert Boards.Cards.get_card!(a.id).board_id == sub.id
    assert Boards.Cards.get_card!(b.id).board_id == sub.id
    assert Boards.Cards.get_card!(stays.id).board_id == work.id
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
    {:ok, simple} = Boards.Templates.find_template(nil, "Simple")
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

    assert Boards.Cards.get_card!(task.id).board_id == sprint.sub_board.id
    assert Boards.Cards.get_card!(task2.id).board_id == sprint.sub_board.id
    # The epic stays where it was; only its tasks went.
    assert Boards.Cards.get_card!(epic.id).board_id == work.id
  end

  test "the open sprint card offers Add cards…", %{conn: conn, sprints: sprints} do
    {:ok, sprint} = Sprints.create_sprint(sprints)
    {:ok, view, _} = live(conn, ~p"/boards/#{sprints}/cards/#{sprint.id}")
    assert has_element?(view, "#card-modal")
    view |> element("#card-sprint-add-cards") |> render_click()
    assert has_element?(view, "#sprint-picker")

    # The board is told the picker opened, and the card stands aside for it;
    # told it closed, and the card comes back (#2893).
    refute has_element?(view, "#card-modal")
    view |> with_target("#board-sprints") |> render_hook("close_sprint_picker", %{})
    refute has_element?(view, "#sprint-picker")
    assert has_element?(view, "#card-modal")
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
      {:ok, simple} = Boards.Templates.find_template(nil, "Simple")
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
      sub = Boards.Cards.get_card!(sprint.id).sub_board
      assert Boards.Cards.get_card!(a.id).board_id == sub.id
      assert Boards.Cards.get_card!(b.id).board_id == sub.id
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

    test "a writer on the sprint card alone can't change the board's sources from the plan", %{
      conn: conn,
      sprints: sprints,
      work: work,
      todo: todo
    } do
      owner = user_fixture()
      {:ok, sprints} = Sprints.put_sources(sprints, owner, [{work, ["To Do"]}])
      {:ok, sprint} = Sprints.create_sprint(sprints)
      before = Boards.get_board!(sprints.id).sprint_sources

      card_writer = user_fixture("card-writer@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: card_writer)
      {:ok, _} = Slipdock.Access.grant(sprint, card_writer, "write", owner)

      {:ok, view, _} =
        live(log_in_user(conn, card_writer), ~p"/boards/#{sprints}/cards/#{sprint.id}")

      view |> element("#card-sprint-add-cards") |> render_click()
      assert has_element?(view, "#sprint-picker")
      view |> element("#plan-sources-button") |> render_click()

      view
      |> form("#plan-sources-form", %{"sources" => %{to_string(theirs.id) => %{"on" => "true"}}})
      |> render_submit()

      assert render(view) =~ "You can only change where Sprints plans from"
      assert Boards.get_board!(sprints.id).sprint_sources == before
      assert [%{"column_ids" => [col]}] = before
      assert col == todo.id
    end

    test "a new sprint board takes its sources from the new-board form", %{
      conn: conn,
      work: work
    } do
      {:ok, template} = Boards.Templates.find_template(nil, "Sprint planning")
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

  # The panel's events no test reached (#3119): a sprint the context refuses,
  # the plan's sort, Clear and the picker's Back.
  describe "a refused new sprint" do
    test "keeps the form open with the error and what was typed, and makes no sprint", %{
      conn: conn,
      sprints: sprints
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{sprints}")
      view |> element("#new-sprint") |> render_click()

      refusals = [
        # A good start that isn't the form's own, sent with a refused days.
        {%{"days" => "0", "start" => "2026-10-05"}, "days must be a whole number from 1 to 365"},
        {%{"days" => "7", "start" => "2026-13-45"}, "start must be a date, like 2026-10-05"}
      ]

      for {refused, message} <- refusals do
        typed = Map.merge(%{"name" => "Crunch week", "goal" => "Ship the importer"}, refused)
        html = view |> form("#new-sprint-form", sprint: typed) |> render_submit()

        # The error shows in the form, which is still open on what was typed.
        assert view |> element("#new-sprint-form p.text-error") |> render() =~ message

        assert has_element?(
                 view,
                 "#new-sprint-form input[name='sprint[name]'][value='Crunch week']"
               )

        assert has_element?(
                 view,
                 "#new-sprint-form input[name='sprint[days]'][value='#{typed["days"]}']"
               )

        assert has_element?(
                 view,
                 "#new-sprint-form textarea[name='sprint[goal]']",
                 "Ship the importer"
               )

        # A real start comes back as typed; a bad one can't be drawn by a
        # date field, so only the good one is looked for.
        if refused["days"] == "0" do
          assert has_element?(
                   view,
                   "#new-sprint-form input[name='sprint[start]'][value='2026-10-05']"
                 )
        end

        # Nothing was made, and the panel didn't go on to picking cards.
        refute has_element?(view, "#sprint-picker")
        refute html =~ "is ready. Pick the cards"
        assert Enum.flat_map(Boards.get_board!(sprints.id).columns, & &1.cards) == []
      end

      # The same form, put right, still makes the sprint.
      view
      |> form("#new-sprint-form", sprint: %{"days" => "7", "start" => "2026-10-05"})
      |> render_submit()

      assert [sprint] = Enum.flat_map(Boards.get_board!(sprints.id).columns, & &1.cards)
      assert sprint.title == "Crunch week"
      assert sprint.start_date == ~D[2026-10-05]
      assert sprint.due_date == ~D[2026-10-11]
      refute has_element?(view, "#new-sprint-form")
      assert has_element?(view, "#sprint-picker")
    end
  end

  describe "the plan's sort" do
    setup %{sprints: sprints, work: work, todo: todo} do
      # Board order: slow, quick, epic, bare. By estimate: quick (1), the epic
      # (5, from its subcards), slow (8), and bare, which has none, last.
      slow = card_fixture(todo, %{"title" => "Slow", "time_estimate" => 8})
      quick = card_fixture(todo, %{"title" => "Quick", "time_estimate" => 1})
      epic = card_fixture(todo, %{"title" => "Epic"})
      bare = card_fixture(todo, %{"title" => "Bare epic"})
      {:ok, simple} = Boards.Templates.find_template(nil, "Simple")
      {:ok, epic_board} = Boards.create_sub_board(epic, simple)
      {:ok, _} = Boards.create_sub_board(bare, simple)
      inside = hd(Boards.get_board!(epic_board.id).columns)
      long = card_fixture(inside, %{"title" => "Long task", "time_estimate" => 3})
      short = card_fixture(inside, %{"title" => "Short task", "time_estimate" => 2})

      # A second board to take cards from, so the picker doesn't also open
      # Work's own lists behind the plan: with those read, opening a card's
      # subcards in the plan raises (#3119 found it; filed as its own card).
      board_fixture(%{"name" => "Home"})

      {:ok, sprints} = Sprints.put_sources(sprints, user_fixture(), [{work, ["To Do"]}])
      {:ok, sprint} = Sprints.create_sprint(sprints)

      %{
        sprints: sprints,
        sprint: sprint,
        slow: slow,
        quick: quick,
        epic: epic,
        bare: bare,
        long: long,
        short: short
      }
    end

    # The plan's rows as they are drawn, top to bottom.
    defp plan_order(view) do
      ~r/id="plan-card-(\d+)"/
      |> Regex.scan(render(view), capture: :all_but_first)
      |> Enum.map(fn [id] -> String.to_integer(id) end)
    end

    defp open_plan(conn, sprints, sprint) do
      {:ok, view, _} = live(conn, ~p"/boards/#{sprints}/cards/#{sprint.id}")
      view |> element("#card-sprint-add-cards") |> render_click()
      view
    end

    defp expand(view, card) do
      view |> element("#plan-card-#{card.id} button[phx-click=plan_expand]") |> render_click()
    end

    test "reorders the lists and the open subcards, keeping them open and the ticks", %{
      conn: conn,
      sprints: sprints,
      sprint: sprint,
      slow: slow,
      quick: quick,
      epic: epic,
      bare: bare,
      long: long,
      short: short
    } do
      view = open_plan(conn, sprints, sprint)
      expand(view, epic)
      # A card with a board of subcards and nothing on it opens too.
      expand(view, bare)
      view |> element("#sprint-pick-#{slow.id}") |> render_click()
      view |> element("#sprint-pick-#{long.id}") |> render_click()

      assert plan_order(view) == [slow.id, quick.id, epic.id, long.id, short.id, bare.id]
      assert has_element?(view, "#plan-sort-form option[value=position][selected]")

      view |> form("#plan-sort-form", %{"sort" => "estimate"}) |> render_change()

      # The list is in the new order, and so are the subcards under the epic.
      assert plan_order(view) == [quick.id, epic.id, short.id, long.id, slow.id, bare.id]
      assert has_element?(view, "#plan-sort-form option[value=estimate][selected]")
      refute has_element?(view, "#plan-sort-form option[value=position][selected]")

      # Both stay open, and both ticks are still there: 8h and 3h.
      assert has_element?(view, "#plan-card-#{epic.id} button[title='Hide subcards']")
      assert has_element?(view, "#plan-card-#{bare.id} button[title='Hide subcards']")
      assert has_element?(view, "#sprint-pick-#{slow.id}[checked]")
      assert has_element?(view, "#sprint-pick-#{long.id}[checked]")
      refute has_element?(view, "#sprint-pick-#{quick.id}[checked]")
      totals = view |> element("#sprint-plan-totals") |> render()
      assert totals =~ "2 cards ticked"
      assert totals =~ "11h"

      # What is ticked is still what is added.
      view |> element("#sprint-add") |> render_click()
      sub = Boards.Cards.get_card!(sprint.id).sub_board
      assert Boards.Cards.get_card!(slow.id).board_id == sub.id
      assert Boards.Cards.get_card!(long.id).board_id == sub.id
      refute Boards.Cards.get_card!(quick.id).board_id == sub.id
    end

    test "subcards re-read by a sort keep their epic, and the sprint's contents are read again",
         %{
           conn: conn,
           sprints: sprints,
           sprint: sprint,
           slow: slow,
           epic: epic,
           short: short
         } do
      view = open_plan(conn, sprints, sprint)
      expand(view, epic)
      view |> form("#plan-sort-form", %{"sort" => "estimate"}) |> render_change()

      # Ticked after the sort: the epic (5h, from its subcards) and one of the
      # subcards the sort re-read. The subcard is inside the epic's hours, so
      # it is counted as a card but not counted again in the hours.
      view |> element("#sprint-pick-#{epic.id}") |> render_click()
      view |> element("#sprint-pick-#{short.id}") |> render_click()
      totals = view |> element("#sprint-plan-totals") |> render()
      assert totals =~ "2 cards ticked"
      assert totals =~ ~r/·\s*5h/
      refute totals =~ "7h"

      # Somebody else puts a card in the sprint; the next sort shows it there.
      assert view |> element("#sprint-plan-totals") |> render() =~ "in the sprint already: 0 open"
      {:ok, _} = Sprints.add_cards(sprint, [Boards.Cards.get_card!(slow.id)])
      view |> form("#plan-sort-form", %{"sort" => "position"}) |> render_change()

      totals = view |> element("#sprint-plan-totals") |> render()
      assert totals =~ "in the sprint already: 1 open"
      assert totals =~ ~r/1 open\s*<span[^>]*>\s*·\s*8h/
      refute has_element?(view, "#plan-card-#{slow.id}")
    end

    test "an unknown sort falls back to board order", %{
      conn: conn,
      sprints: sprints,
      sprint: sprint,
      slow: slow,
      quick: quick,
      epic: epic,
      bare: bare,
      long: long,
      short: short
    } do
      view = open_plan(conn, sprints, sprint)
      expand(view, epic)
      view |> form("#plan-sort-form", %{"sort" => "estimate"}) |> render_change()
      assert hd(plan_order(view)) == quick.id

      # Not one of the select's options, so sent as the event itself.
      view |> element("#plan-sort-form") |> render_change(%{"sort" => "title; drop"})

      assert plan_order(view) == [slow.id, quick.id, epic.id, long.id, short.id, bare.id]
      assert has_element?(view, "#plan-sort-form option[value=position][selected]")
      refute has_element?(view, "#plan-sort-form option[value=estimate][selected]")
    end

    test "a card that left the plan while open takes its subcards off the view, not the ticks",
         %{
           conn: conn,
           sprints: sprints,
           sprint: sprint,
           slow: slow,
           quick: quick,
           epic: epic,
           bare: bare,
           long: long,
           short: short
         } do
      view = open_plan(conn, sprints, sprint)
      expand(view, epic)
      view |> element("#sprint-pick-#{slow.id}") |> render_click()
      view |> element("#sprint-pick-#{long.id}") |> render_click()

      # Somebody else archives the epic while the plan is open.
      {:ok, _} = Boards.Cards.archive_card(Boards.Cards.get_card!(epic.id))
      view |> form("#plan-sort-form", %{"sort" => "estimate"}) |> render_change()

      assert plan_order(view) == [quick.id, slow.id, bare.id]
      refute has_element?(view, "#plan-card-#{long.id}")
      refute has_element?(view, "#plan-card-#{short.id}")
      assert has_element?(view, "#sprint-pick-#{slow.id}[checked]")
      assert view |> element("#sprint-plan-totals") |> render() =~ "2 cards ticked"

      # Its subcards are no longer on the view, so a tick sent for one that
      # wasn't ticked is not taken.
      toggle = fn card ->
        view
        |> with_target("#board-sprints")
        |> render_hook("sprint_toggle", %{"id" => to_string(card.id)})

        view |> element("#sprint-plan-totals") |> render()
      end

      assert toggle.(short) =~ "2 cards ticked"
      # The same event for a card still on the view is taken.
      assert toggle.(quick) =~ "3 cards ticked"
    end
  end

  describe "the picker's Clear and Back" do
    test "Clear unticks everything, in the plan and in a board's lists", %{
      conn: conn,
      sprints: sprints,
      work: work,
      todo: todo
    } do
      a = card_fixture(todo, %{"title" => "One", "time_estimate" => 2})
      b = card_fixture(todo, %{"title" => "Two", "time_estimate" => 3})
      {:ok, sprints} = Sprints.put_sources(sprints, user_fixture(), [{work, ["To Do"]}])
      {:ok, sprint} = Sprints.create_sprint(sprints)

      {:ok, view, _} = live(conn, ~p"/boards/#{sprints}/cards/#{sprint.id}")
      view |> element("#card-sprint-add-cards") |> render_click()

      # Nothing ticked: nothing to clear, and nothing to add.
      refute has_element?(view, "#sprint-picker button[phx-click=sprint_clear]")
      assert has_element?(view, "#sprint-add[disabled]")

      view |> element("#sprint-pick-#{a.id}") |> render_click()
      view |> element("#sprint-pick-#{b.id}") |> render_click()
      assert view |> element("#sprint-plan-totals") |> render() =~ "2 cards ticked"
      refute has_element?(view, "#sprint-add[disabled]")

      view |> element("#sprint-picker button[phx-click=sprint_clear]") |> render_click()

      totals = view |> element("#sprint-plan-totals") |> render()
      assert totals =~ "0 cards ticked"
      refute totals =~ "5h"
      refute totals =~ ~r/total \d/
      refute has_element?(view, "#sprint-pick-#{a.id}[checked]")
      refute has_element?(view, "#sprint-pick-#{b.id}[checked]")
      assert has_element?(view, "#sprint-add[disabled]")
      refute has_element?(view, "#sprint-picker button[phx-click=sprint_clear]")

      # The same from a board's own lists; the picker stays open on them.
      view
      |> element("#sprint-picker button[phx-click=plan_mode][phx-value-mode=browse]")
      |> render_click()

      view |> element("#sprint-pick-#{a.id}") |> render_click()
      assert view |> element("#sprint-plan-totals") |> render() =~ "1 card ticked"
      view |> element("#sprint-picker button[phx-click=sprint_clear]") |> render_click()
      assert view |> element("#sprint-plan-totals") |> render() =~ "0 cards ticked"
      assert has_element?(view, "#sprint-pick-#{a.id}")
      refute has_element?(view, "#sprint-pick-#{a.id}[checked]")

      # Cleared ticks add nothing: both cards are where they were.
      assert Boards.Cards.get_card!(a.id).board_id == work.id
      assert Boards.Cards.get_card!(b.id).board_id == work.id
    end

    test "Back steps out of a card's subcards, then out to the boards, keeping the ticks", %{
      conn: conn,
      sprints: sprints,
      work: work,
      todo: todo
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      home = board_fixture(%{"name" => "Home"})
      epic = card_fixture(todo, %{"title" => "Epic"})
      {:ok, simple} = Boards.Templates.find_template(nil, "Simple")
      {:ok, epic_board} = Boards.create_sub_board(epic, simple)
      task = card_fixture(hd(Boards.get_board!(epic_board.id).columns), %{"title" => "A task"})

      {:ok, view, _} = live(conn, ~p"/boards/#{sprint.sub_board.id}")
      view |> element("#sprint-add-cards") |> render_click()
      back = "#sprint-picker button[phx-click=sprint_up]"
      source = "#sprint-picker button[phx-click=sprint_source]"

      # Several boards, so the picker starts on the list of them: no Back yet.
      assert has_element?(view, "#{source}[phx-value-id='#{home.id}']")
      refute has_element?(view, back)

      view |> element("#{source}[phx-value-id='#{work.id}']") |> render_click()

      view
      |> element("#sprint-picker button[phx-click=sprint_into][phx-value-id='#{epic_board.id}']")
      |> render_click()

      assert has_element?(view, "#sprint-pick-#{task.id}")
      refute has_element?(view, "#sprint-pick-#{epic.id}")
      view |> element("#sprint-pick-#{task.id}") |> render_click()

      # Back once: the board the epic is on, with its lists read again.
      view |> element(back) |> render_click()
      assert has_element?(view, "#sprint-pick-#{epic.id}")
      refute has_element?(view, "#sprint-pick-#{task.id}")
      refute has_element?(view, source)
      assert view |> element("#sprint-plan-totals") |> render() =~ "1 card ticked"

      # Back again: the boards to take cards from, and no list of cards.
      view |> element(back) |> render_click()
      assert has_element?(view, "#{source}[phx-value-id='#{work.id}']")
      assert has_element?(view, "#{source}[phx-value-id='#{home.id}']")
      refute has_element?(view, "#sprint-pick-#{epic.id}")
      refute has_element?(view, back)
      assert view |> element("#sprint-plan-totals") |> render() =~ "1 card ticked"

      # The board just left is no longer read: a tick sent for one of its
      # cards is not taken.
      view
      |> with_target("#board-sprints")
      |> render_hook("sprint_toggle", %{"id" => to_string(epic.id)})

      assert view |> element("#sprint-plan-totals") |> render() =~ "1 card ticked"

      # The tick made two levels down is still what is added.
      view |> element("#sprint-add") |> render_click()
      assert Boards.Cards.get_card!(task.id).board_id == sprint.sub_board.id
      assert Boards.Cards.get_card!(epic.id).board_id == work.id
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
    {:ok, _} = Boards.Cards.update_card(Boards.Cards.get_card!(a.id), %{"completed" => true})

    {:ok, view, _} = live(conn, ~p"/boards/#{sprints}")
    view |> element("#sprint-charts") |> render_click()
    assert has_element?(view, "#velocity-chart")
    assert has_element?(view, "#burndown-#{two.id}")
    assert render(view) =~ "1 of 2 cards done"

    # #2875: a sprint id that isn't one leaves the charts as they are.
    for bad <- ["#{one.id}abc", "x", ""] do
      view |> element("#chart-sprint-form") |> render_change(%{"sprint" => bad})
      assert has_element?(view, "#velocity-chart")
      assert has_element?(view, "#burndown-#{two.id}")
    end

    view |> form("#chart-sprint-form", %{"sprint" => "#{one.id}"}) |> render_change()
    refute has_element?(view, "#burndown-#{two.id}")
    assert render(view) =~ "Nothing in this sprint yet"

    {:ok, view, _} = live(conn, ~p"/boards/#{Boards.Cards.get_card!(two.id).sub_board.id}")
    view |> element("#sprint-charts") |> render_click()
    assert has_element?(view, "#burndown-#{two.id}")
    refute has_element?(view, "#velocity-chart")
  end

  describe "what Add says and skips (#3118)" do
    # Opens the picker from the sprint's card (with one other board, it opens
    # on Work's lists), ticks the cards, lets `meanwhile` change them, and
    # clicks Add.
    defp tick_and_add(conn, sprints, sprint, cards, meanwhile \\ fn -> :ok end) do
      {:ok, view, _} = live(conn, ~p"/boards/#{sprints}/cards/#{sprint.id}")
      view |> element("#card-sprint-add-cards") |> render_click()
      for card <- cards, do: view |> element("#sprint-pick-#{card.id}") |> render_click()
      meanwhile.()
      view |> element("#sprint-add") |> render_click()
      view
    end

    defp board_of(card), do: Boards.Cards.get_card!(card.id).board_id

    test "one card is said in the singular", %{
      conn: conn,
      sprints: sprints,
      todo: todo,
      work: work
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      a = card_fixture(todo, %{"title" => "Write the release notes"})
      stays = card_fixture(todo, %{"title" => "Not this time"})

      view = tick_and_add(conn, sprints, sprint, [a])

      assert has_element?(view, "#flash-info", "Added 1 card to #{sprint.title}.")
      refute has_element?(view, "#flash-info", "1 cards")
      refute has_element?(view, "#flash-error")
      assert board_of(a) == Boards.Cards.get_card!(sprint.id).sub_board.id
      assert board_of(stays) == work.id
    end

    test "a card left out is named in the note", %{
      conn: conn,
      sprints: sprints,
      todo: todo,
      work: work
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      a = card_fixture(todo, %{"title" => "Write the release notes"})
      b = card_fixture(todo, %{"title" => "Fix the login bug"})

      view =
        tick_and_add(conn, sprints, sprint, [a, b], fn ->
          {:ok, _} = Boards.Cards.archive_card(Boards.Cards.get_card!(b.id))
        end)

      assert has_element?(
               view,
               "#flash-info",
               "Added 1 card to #{sprint.title}. “Fix the login bug” was left out: it is archived."
             )

      refute has_element?(view, "#flash-error")
      assert board_of(a) == Boards.Cards.get_card!(sprint.id).sub_board.id
      assert board_of(b) == work.id
    end

    test "every card left out is an error: Nothing added to", %{
      conn: conn,
      sprints: sprints,
      todo: todo,
      work: work
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      a = card_fixture(todo, %{"title" => "Write the release notes"})
      b = card_fixture(todo, %{"title" => "Fix the login bug"})

      # Ticked, then one archived and the other put in the sprint by
      # somebody else before Add is clicked.
      view =
        tick_and_add(conn, sprints, sprint, [a, b], fn ->
          {:ok, _} = Boards.Cards.archive_card(Boards.Cards.get_card!(a.id))
          {:ok, %{added: [_]}} = Sprints.add_cards(sprint, [b])
        end)

      assert has_element?(
               view,
               "#flash-error",
               "Nothing added to #{sprint.title}. " <>
                 "“Write the release notes” was left out: it is archived. " <>
                 "“Fix the login bug” was left out: it is already in the sprint."
             )

      refute has_element?(view, "#flash-info")
      assert board_of(a) == work.id
      assert board_of(b) == Boards.Cards.get_card!(sprint.id).sub_board.id
    end

    test "a card deleted after it was ticked is dropped without a note", %{
      conn: conn,
      sprints: sprints,
      todo: todo
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      a = card_fixture(todo, %{"title" => "Write the release notes"})
      gone = card_fixture(todo, %{"title" => "Deleted meanwhile"})

      view =
        tick_and_add(conn, sprints, sprint, [a, gone], fn ->
          {:ok, _} = Boards.Cards.delete_card(Boards.Cards.get_card!(gone.id))
        end)

      assert has_element?(view, "#flash-info", "Added 1 card to #{sprint.title}.")
      refute render(view) =~ "Deleted meanwhile"
      refute render(view) =~ "left out"
      assert board_of(a) == Boards.Cards.get_card!(sprint.id).sub_board.id
      assert Boards.Cards.get_card(gone.id) == nil
    end

    test "every ticked card deleted says Nothing added, and is not an error", %{
      conn: conn,
      sprints: sprints,
      todo: todo
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      gone = card_fixture(todo, %{"title" => "Deleted meanwhile"})

      view =
        tick_and_add(conn, sprints, sprint, [gone], fn ->
          {:ok, _} = Boards.Cards.delete_card(Boards.Cards.get_card!(gone.id))
        end)

      assert has_element?(view, "#flash-info", "Nothing added to #{sprint.title}.")
      refute has_element?(view, "#flash-error")
      refute render(view) =~ "left out"
      assert Boards.Cards.get_card(gone.id) == nil

      assert Boards.get_board!(Boards.Cards.get_card!(sprint.id).sub_board.id).columns
             |> Enum.flat_map(& &1.cards) == []
    end

    test "a sprint board left with no lists says why, and adds nothing", %{
      conn: conn,
      sprints: sprints,
      todo: todo,
      work: work
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      sub_board_id = Boards.Cards.get_card!(sprint.id).sub_board.id
      a = card_fixture(todo, %{"title" => "Write the release notes"})

      # Ticked, then the sprint's own board loses every list before Add.
      view =
        tick_and_add(conn, sprints, sprint, [a], fn ->
          assert {n, _} = Repo.delete_all(from c in Column, where: c.board_id == ^sub_board_id)
          assert n > 0
        end)

      assert has_element?(view, "#flash-error", "That board has no lists.")
      refute has_element?(view, "#flash-info")
      refute render(view) =~ "Added"
      assert board_of(a) == work.id
      assert Boards.Cards.get_card!(a.id).column_id == todo.id
    end

    test "a card its reader may no longer write is dropped without a note", %{
      sprints: sprints,
      todo: todo,
      work: work,
      user: owner
    } do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      a = card_fixture(todo, %{"title" => "Write the release notes"})

      writer = user_fixture("writer@example.com")
      {:ok, _} = Access.grant(sprints, writer, "write", owner)
      {:ok, _} = Access.grant(work, writer, "write", owner)

      # Ticked as a writer on Work; the grant there is lowered to read before
      # Add, by its row alone, so the open picker is told nothing and still
      # holds the tick.
      view =
        tick_and_add(log_in_user(build_conn(), writer), sprints, sprint, [a], fn ->
          assert {1, _} =
                   Repo.update_all(
                     from(g in Grant, where: g.board_id == ^work.id and g.user_id == ^writer.id),
                     set: [level: "read"]
                   )

          assert Access.board_permission(writer, work) == :read
          assert Access.board_permission(writer, sprints) == :write
        end)

      assert has_element?(view, "#flash-info", "Nothing added to #{sprint.title}.")
      refute has_element?(view, "#flash-error")
      refute render(view) =~ "left out"
      assert board_of(a) == work.id
      assert Boards.Cards.get_card!(a.id).column_id == todo.id
    end
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
      [stand_in] = Boards.Cards.stand_ins_for(moved.id)

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
      {:ok, template} = Boards.Templates.find_template(nil, "Sprint planning")
      other = user_fixture("elsewhere@example.com")
      theirs = board_fixture(%{"name" => "Their sprints"}, template: template, owner: other)
      {:ok, sprint} = Sprints.create_sprint(theirs)

      {:ok, %{added: [moved]}} =
        Sprints.add_cards(sprint, [card_fixture(todo, %{"title" => "Secret-ish"})])

      [stand_in] = Boards.Cards.stand_ins_for(moved.id)

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
      [stand_in] = Boards.Cards.stand_ins_for(moved.id)

      {:ok, view, _} = live(conn, ~p"/boards/#{work}")
      assert view |> element("#column-#{todo.id} .badge") |> render() =~ "0 cards"

      view
      |> element("#card-#{stand_in.id} button[phx-click*='dismiss_stand_in']")
      |> render_click()

      refute has_element?(view, "#card-#{stand_in.id}")
      assert Boards.Cards.stand_ins_for(moved.id) == []
    end
  end
end
