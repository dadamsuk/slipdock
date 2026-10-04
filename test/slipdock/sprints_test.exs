defmodule Slipdock.SprintsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Sprints}
  alias Slipdock.Boards.{Board, Card}

  setup do
    {:ok, template} = Boards.find_template("Sprint planning")
    sprints = board_fixture(%{"name" => "Sprints"}, template: template)
    work = board_fixture(%{"name" => "Work"})
    %{sprints: sprints, work: work, template: template}
  end

  test "the Sprint planning template makes a sprint board, but not sprint sub-boards", %{
    sprints: sprints,
    work: work
  } do
    assert sprints.kind == "sprints"
    assert Board.sprints?(sprints)
    refute Board.sprints?(work)

    {:ok, sprint} = Sprints.create_sprint(sprints)
    assert sprint.sub_board
    refute Board.sprints?(Boards.get_board!(sprint.sub_board.id))
  end

  test "a board becomes a sprint board in its settings, and stops being one", %{work: work} do
    {:ok, board} = Boards.update_board(work, %{"kind" => "sprints"})
    assert Board.sprints?(board)

    {:ok, board} = Boards.update_board(board, %{"kind" => ""})
    refute Board.sprints?(board)

    assert {:error, changeset} = Boards.update_board(board, %{"kind" => "nonsense"})
    assert changeset.errors[:kind]
  end

  test "sprints are numbered and dated on from the last one", %{sprints: sprints} do
    today = Date.utc_today()

    {:ok, one} = Sprints.create_sprint(sprints)
    assert one.title == "Sprint 1"
    assert one.start_date == today
    assert one.due_date == Date.add(today, 13)
    assert [planned | _] = sprints.columns
    assert one.column_id == planned.id

    {:ok, two} = Sprints.create_sprint(sprints, %{"days" => "7", "goal" => "Ship it"})
    assert two.title == "Sprint 2"
    assert two.start_date == Date.add(today, 14)
    assert two.due_date == Date.add(today, 20)
    assert two.description == "Ship it"

    {:ok, named} =
      Sprints.create_sprint(sprints, %{"name" => "Hardening", "start" => "2027-01-04"})

    assert named.title == "Hardening"
    assert named.start_date == ~D[2027-01-04]

    assert %{name: "Sprint 3"} = Sprints.next_sprint(sprints)
  end

  test "sprints only go on sprint boards, and bad input is said plainly", %{
    sprints: sprints,
    work: work
  } do
    assert {:error, "Work is not a sprint board."} = Sprints.create_sprint(work)
    assert {:error, "start must be" <> _} = Sprints.create_sprint(sprints, %{"start" => "soon"})
    assert {:error, "days must be" <> _} = Sprints.create_sprint(sprints, %{"days" => "0"})
  end

  test "cards picked from other boards move into the sprint's to-do list", %{
    sprints: sprints,
    work: work
  } do
    {:ok, sprint} = Sprints.create_sprint(sprints)
    [_backlog, todo | _] = work.columns
    a = card_fixture(todo, %{"title" => "A"})
    b = card_fixture(todo, %{"title" => "B"})
    stays = card_fixture(todo, %{"title" => "Stays"})

    assert {:ok, %{added: added, skipped: []}} = Sprints.add_cards(sprint, [a, b])
    assert Enum.map(added, & &1.title) == ["A", "B"]

    sub = Boards.get_board!(sprint.sub_board.id)
    [to_do | _] = sub.columns
    assert Enum.all?(added, &(&1.board_id == sub.id and &1.column_id == to_do.id))
    assert Boards.get_card!(stays.id).board_id == work.id

    # A second sitting adds to what is there; a card already in is skipped.
    c = card_fixture(todo, %{"title" => "C"})

    assert {:ok, %{added: [%{title: "C"}], skipped: [{_, "it is already in the sprint"}]}} =
             Sprints.add_cards(sprint, [c, Boards.get_card!(a.id)])

    assert Boards.get_board!(sub.id).columns |> hd() |> Map.get(:cards) |> length() == 3
  end

  test "the sprint itself and cards off a non-sprint are refused", %{
    sprints: sprints,
    work: work
  } do
    {:ok, sprint} = Sprints.create_sprint(sprints)
    [_, todo | _] = work.columns
    plain = card_fixture(todo)

    assert {:ok, %{added: [], skipped: [{_, "it is the sprint"}]}} =
             Sprints.add_cards(sprint, [sprint])

    assert {:error, "That card is not a sprint."} = Sprints.add_cards(plain, [sprint])
  end

  test "a sprint card made by hand gets its sub-board when cards are first added", %{
    sprints: sprints,
    work: work
  } do
    [planned | _] = sprints.columns
    sprint = card_fixture(planned, %{"title" => "Made by hand"})
    [_, todo | _] = work.columns
    card = card_fixture(todo)

    assert {:ok, %{added: [moved]}} = Sprints.add_cards(sprint, [card])
    assert Boards.get_card!(sprint.id).sub_board.id == moved.board_id
  end

  test "candidates are a board's open cards, list by list, with a way into subcards", %{
    sprints: sprints,
    work: work
  } do
    {:ok, sprint} = Sprints.create_sprint(sprints)
    [backlog, todo | _] = work.columns
    epic = card_fixture(backlog, %{"title" => "Epic"})
    {:ok, epic_board} = Boards.create_sub_board(epic, elem(Boards.find_template("Simple"), 1))
    _done = card_fixture(todo, %{"title" => "Finished", "completed" => true})
    open = card_fixture(todo, %{"title" => "Open"})

    lists = Sprints.candidates(work, sprint)
    assert [%{name: "Backlog", cards: [e]}, %{name: "To Do", cards: [o]} | _] = lists
    assert e.id == epic.id and e.sub_board_id == epic_board.id
    assert o.id == open.id

    # Its own sub-board is never a source, and the sprint is not its own candidate.
    assert Sprints.candidates(Boards.get_board!(sprint.sub_board.id), sprint) == []

    # On the sprint board the other sprints are there to step into, not to take.
    {:ok, other} = Sprints.create_sprint(sprints)
    sprint_cards = sprints |> Sprints.candidates(sprint) |> Enum.flat_map(& &1.cards)
    assert [%{pickable: false, sub_board_id: sub}] = sprint_cards
    assert sub == other.sub_board.id

    assert {:ok, %{added: [], skipped: [{_, "it is a sprint itself" <> _}]}} =
             Sprints.add_cards(sprint, [other])
  end

  test "source boards are the writable top-level boards", %{sprints: sprints, work: work} do
    {:ok, sprint} = Sprints.create_sprint(sprints)
    other = board_fixture(%{"name" => "Someone else's"}, owner: user_fixture("other@example.com"))

    ids = user_fixture() |> Sprints.source_boards(sprint) |> Enum.map(& &1.id)
    assert work.id in ids
    assert sprints.id in ids
    refute other.id in ids
    refute sprint.sub_board.id in ids
  end

  describe "sources" do
    test "a sprint board plans from chosen boards and lists, by id or name", %{
      sprints: sprints,
      work: work
    } do
      user = user_fixture()
      home = board_fixture(%{"name" => "Home"})
      [backlog, todo | _] = work.columns

      assert Sprints.sources(sprints, user) == []

      {:ok, sprints} =
        Sprints.put_sources(sprints, user, [{work.id, ["To Do", backlog.id]}, {home, []}])

      assert [
               %{board: %{id: work_id}, columns: work_lists, all: false},
               %{board: %{id: home_id}, columns: home_lists, all: true}
             ] = Sprints.sources(sprints, user)

      assert work_id == work.id and home_id == home.id
      # In the board's own order, not the order they were named in.
      assert Enum.map(work_lists, & &1.id) == [backlog.id, todo.id]
      # No lists named means every list that is not done.
      refute Enum.any?(home_lists, &(&1.category == "done"))
      assert length(home_lists) == length(home.columns) - 1

      {:ok, sprints} = Sprints.put_sources(sprints, user, [])
      assert Sprints.sources(sprints, user) == []
    end

    test "only boards the person can write to, not itself, and real lists", %{
      sprints: sprints,
      work: work
    } do
      user = user_fixture()
      other = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("them@example.com"))

      assert {:error, "You can only plan" <> _} =
               Sprints.put_sources(sprints, user, [{other, []}])

      assert {:error, "A sprint board cannot" <> _} =
               Sprints.put_sources(sprints, user, [{sprints, []}])

      assert {:error, "Work has no list “Nope”."} =
               Sprints.put_sources(sprints, user, [{work, ["Nope"]}])

      assert {:error, "Work is not a sprint board."} = Sprints.put_sources(work, user, [])

      # A board that later goes out of reach drops out rather than failing.
      {:ok, sprints} = Sprints.put_sources(sprints, user, [{work, []}])
      {:ok, _} = Boards.archive_board(work)
      assert Sprints.sources(sprints, user) == []
    end

    test "the choices are the writable boards other than sprint boards", %{
      sprints: sprints,
      work: work
    } do
      user = user_fixture()
      ids = user |> Sprints.source_choices(sprints) |> Enum.map(& &1.id)
      assert work.id in ids
      refute sprints.id in ids
    end
  end

  describe "plan" do
    setup %{sprints: sprints, work: work} do
      user = user_fixture()
      {:ok, sprints} = Sprints.put_sources(sprints, user, [{work, ["To Do"]}])
      {:ok, sprint} = Sprints.create_sprint(sprints)
      %{user: user, sprints: sprints, sprint: sprint}
    end

    test "shows each source list's open cards with priority, scores and estimates", %{
      user: user,
      sprints: sprints,
      sprint: sprint,
      work: work
    } do
      {:ok, _} = Slipdock.Fields.install_preset(work, "value_effort")
      fields = Slipdock.Fields.list_fields(work.id)
      value = Enum.find(fields, &(&1.key == "value"))
      effort = Enum.find(fields, &(&1.key == "effort"))
      [backlog, todo | _] = work.columns

      _not_shown = card_fixture(backlog, %{"title" => "In the backlog"})
      low = card_fixture(todo, %{"title" => "Low", "priority" => "low", "time_estimate" => 1})
      high = card_fixture(todo, %{"title" => "High", "priority" => "high"})
      {:ok, _} = Slipdock.Fields.set_value(high, value, "4")
      {:ok, _} = Slipdock.Fields.set_value(high, effort, "2")

      # An epic with no estimate of its own takes its open subcards'. Estimates
      # are written in hours and kept in minutes.
      epic = card_fixture(todo, %{"title" => "Epic"})
      {:ok, simple} = Boards.find_template("Simple")
      {:ok, epic_board} = Boards.create_sub_board(epic, simple)
      [epic_todo | _] = Boards.get_board!(epic_board.id).columns
      task = card_fixture(epic_todo, %{"title" => "Task", "time_estimate" => 2})
      _done = card_fixture(epic_todo, %{"completed" => true, "time_estimate" => 10})

      plan = Sprints.plan(sprint, Sprints.sources(sprints, user))
      assert %{committed: %{cards: 0, open: 0, estimate: 0}} = plan
      assert [%{board: %{id: work_id}, formulas: [formula], lists: [list]}] = plan.boards
      assert work_id == work.id and formula.key == "value_effort"
      assert list.name == "To Do"

      by_id = Map.new(list.cards, &{&1.id, &1})
      assert by_id[low.id].estimate == 60 and not by_id[low.id].estimate_derived
      assert [{_, 2.0}] = by_id[high.id].scores
      assert by_id[epic.id].estimate == 120 and by_id[epic.id].estimate_derived
      assert by_id[epic.id].sub_board_id == epic_board.id

      # Ordered by score, by priority.
      [by_score] = Sprints.plan(sprint, Sprints.sources(sprints, user), "score").boards
      assert hd(hd(by_score.lists).cards).id == high.id

      [by_priority] = Sprints.plan(sprint, Sprints.sources(sprints, user), "priority").boards
      assert Enum.map(hd(by_priority.lists).cards, & &1.id) |> Enum.take(2) == [high.id, low.id]

      # Subcards open beneath their card, knowing which card they are inside.
      assert [%{id: task_id, ancestors: [epic_id]}] =
               Sprints.plan_children(epic_board.id, sprint, [epic.id])

      assert task_id == task.id and epic_id == epic.id
    end

    test "the totals do not count a card twice when its parent is ticked too" do
      selected = %{
        1 => %{estimate: 120, ancestors: []},
        2 => %{estimate: 60, ancestors: [1]},
        3 => %{estimate: nil, ancestors: []},
        4 => %{estimate: 30, ancestors: [9]}
      }

      assert Sprints.selection_totals(selected) == %{cards: 4, estimate: 150}
    end

    test "committed is what is in the sprint already", %{sprint: sprint, work: work} do
      [_, todo | _] = work.columns
      a = card_fixture(todo, %{"time_estimate" => 2})
      b = card_fixture(todo, %{"completed" => true, "time_estimate" => 30})
      {:ok, _} = Sprints.add_cards(sprint, [a, b])

      assert Sprints.committed(sprint) == %{cards: 2, open: 1, estimate: 120}
    end
  end

  describe "stand-ins" do
    setup %{sprints: sprints, work: work} do
      {:ok, sprint} = Sprints.create_sprint(sprints)
      [_backlog, todo | _] = work.columns
      %{sprint: sprint, todo: todo}
    end

    defp slot_titles(column_id) do
      column_id
      |> Boards.active_items()
      |> Enum.map(fn {:card, id} -> Slipdock.Repo.get!(Card, id) end)
      |> Enum.map(&if(&1.stand_in_for_id, do: "→ " <> &1.title, else: &1.title))
    end

    test "a card pulled into a sprint leaves a stand-in in its slot", %{
      sprint: sprint,
      work: work,
      todo: todo
    } do
      owner = Slipdock.Repo.preload(work, :owner).owner
      _a = card_fixture(todo, %{"title" => "A"})
      b = card_fixture(todo, %{"title" => "B"})
      _c = card_fixture(todo, %{"title" => "C"})
      used = Slipdock.Quota.used(owner)

      assert {:ok, %{added: [moved]}} = Sprints.add_cards(sprint, [b])
      assert slot_titles(todo.id) == ["A", "→ B", "C"]

      [stand_in] = Boards.stand_ins_for(moved.id)
      assert stand_in.board_id == work.id
      assert Card.stand_in?(stand_in)

      # It renders from the real card: its sprint, and where that card is.
      loaded = Boards.get_card!(stand_in.id)
      assert loaded.stand_in_for.id == moved.id
      assert loaded.stand_in_for.board.parent_card.title == sprint.title
      assert loaded.stand_in_for.column.id == moved.column_id
      assert SlipdockWeb.SlipdockComponents.stand_in_state(loaded.stand_in_for) == :todo

      # Not one more thing: not quota, not a candidate, not in the rollup.
      assert Slipdock.Quota.used(owner) == used

      ids =
        for list <- Sprints.candidates(work, sprint), card <- list.cards, do: card.id

      refute stand_in.id in ids
      refute Map.has_key?(Boards.rollup(work).stats, stand_in.id)
      assert Boards.search_cards(work.id, "B") == []
    end

    test "a stand-in cannot be edited, moved off its board or added to a sprint", %{
      sprint: sprint,
      todo: todo
    } do
      {:ok, %{added: [moved]}} = Sprints.add_cards(sprint, [card_fixture(todo)])
      [stand_in] = Boards.stand_ins_for(moved.id)

      assert {:error, changeset} = Boards.update_card(stand_in, %{"title" => "New"})
      assert changeset.errors[:stand_in_for_id]

      sub = Boards.get_board!(sprint.sub_board.id)

      assert {:error, "A stand-in stays" <> _} =
               Boards.move_card_to_board(stand_in, hd(sub.columns))

      assert {:ok, %{added: [], skipped: [{_, "it is a stand-in" <> _}]}} =
               Sprints.add_cards(sprint, [stand_in])
    end

    test "carried over to the next sprint, a card leaves no second stand-in", %{
      sprints: sprints,
      sprint: one,
      todo: todo
    } do
      {:ok, two} = Sprints.create_sprint(sprints)
      {:ok, %{added: [moved]}} = Sprints.add_cards(one, [card_fixture(todo)])
      {:ok, %{added: [carried]}} = Sprints.add_cards(two, [Boards.get_card!(moved.id)])

      assert [stand_in] = Boards.stand_ins_for(carried.id)
      assert stand_in.column_id == todo.id

      loaded = Boards.get_card!(stand_in.id)
      assert loaded.stand_in_for.board.parent_card.title == two.title
    end

    test "moved back to its board, the card takes the stand-in's slot", %{
      sprint: sprint,
      work: work,
      todo: todo
    } do
      _a = card_fixture(todo, %{"title" => "A"})
      b = card_fixture(todo, %{"title" => "B"})
      _c = card_fixture(todo, %{"title" => "C"})
      {:ok, %{added: [moved]}} = Sprints.add_cards(sprint, [b])

      # Wherever on the board it is sent, the slot is where it goes.
      last = List.last(work.columns)
      assert {:ok, %{card: back}} = Boards.move_card_to_board(moved, last)
      assert back.column_id == todo.id
      assert slot_titles(todo.id) == ["A", "B", "C"]
      assert Boards.stand_ins_for(b.id) == []
    end

    test "reaching a done list takes the stand-in to its board's done list", %{
      sprint: sprint,
      work: work,
      todo: todo
    } do
      {:ok, %{added: [moved]}} = Sprints.add_cards(sprint, [card_fixture(todo)])
      sub = Boards.get_board!(sprint.sub_board.id)
      sprint_done = Enum.find(sub.columns, &(&1.category == "done"))
      work_done = Enum.find(work.columns, &(&1.category == "done"))

      :ok = Boards.move_card(moved.id, sprint_done.id)

      [stand_in] = Boards.stand_ins_for(moved.id)
      assert stand_in.column_id == work_done.id
      refute stand_in.completed
    end

    test "a stand-in for a deleted card stays one, pointing at nothing", %{
      sprint: sprint,
      todo: todo
    } do
      {:ok, %{added: [moved]}} = Sprints.add_cards(sprint, [card_fixture(todo)])
      [stand_in] = Boards.stand_ins_for(moved.id)
      {:ok, _} = Boards.delete_card(moved)

      loaded = Boards.get_card!(stand_in.id)
      assert Card.stand_in?(loaded)
      assert loaded.stand_in_for == nil
    end

    test "stand-ins are not exported", %{sprint: sprint, todo: todo} do
      {:ok, %{added: [moved]}} =
        Sprints.add_cards(sprint, [card_fixture(todo, %{"title" => "Once"})])

      assert [_] = Boards.stand_ins_for(moved.id)

      document = user_fixture() |> Slipdock.Portable.export() |> Jason.encode!()
      assert length(Regex.scan(~r/"title":"Once"/, document)) == 1
    end
  end

  test "sprint_of_board finds the sprint above a sprint's sub-board", %{
    sprints: sprints,
    work: work
  } do
    {:ok, sprint} = Sprints.create_sprint(sprints)
    assert Sprints.sprint_of_board(Boards.get_board!(sprint.sub_board.id)).id == sprint.id
    assert Sprints.sprint_of_board(work) == nil
  end

  test "a sprint board stays one through export and import", %{sprints: sprints} do
    owner = user_fixture()
    to = user_fixture("importer@example.com")
    document = owner |> Slipdock.Portable.export() |> Jason.encode!()
    {:ok, report} = Slipdock.Portable.import(to, document)

    kinds =
      Map.new(report.boards, fn b -> {b.name, Boards.get_board!(b.id).kind} end)

    assert kinds[sprints.name] == "sprints"
    assert kinds["Work"] == nil
  end

  describe "charts" do
    # Completes `card` as if on `date`, by backdating its completed_at.
    defp complete_on(card, date) do
      {:ok, card} = Boards.update_card(card, %{"completed" => true})

      card
      |> Ecto.Changeset.change(completed_at: DateTime.new!(date, ~T[12:00:00], "Etc/UTC"))
      |> Slipdock.Repo.update!()
    end

    test "completing a card stamps completed_at, and reopening clears it", %{work: work} do
      [todo | _] = work.columns
      card = card_fixture(todo)
      assert is_nil(card.completed_at)

      {:ok, done} = Boards.update_card(card, %{"completed" => true})
      assert %DateTime{} = done.completed_at

      {:ok, open} = Boards.update_card(done, %{"completed" => false})
      assert is_nil(open.completed_at)
    end

    test "a burndown counts the work still open at the end of each day", %{
      sprints: sprints,
      work: work
    } do
      {:ok, sprint} =
        Sprints.create_sprint(sprints, %{"start" => "2026-03-02", "days" => "5"})

      [todo | _] = work.columns

      cards =
        for t <- ~w(A B C D), do: card_fixture(todo, %{"title" => t, "time_estimate" => "2"})

      {:ok, _} = Sprints.add_cards(sprint, cards)
      [a, b, _c, _d] = Enum.map(cards, &Boards.get_card!(&1.id))

      complete_on(a, ~D[2026-03-03])
      complete_on(b, ~D[2026-03-04])

      chart = Sprints.burndown(Boards.get_card!(sprint.id), ~D[2026-03-04])

      assert chart.total == 4
      assert chart.done == 2
      assert chart.estimate == 8 * 60

      assert Enum.map(chart.days, & &1.date) ==
               Enum.to_list(Date.range(~D[2026-03-02], ~D[2026-03-06]))

      assert Enum.map(chart.days, & &1.remaining) == [4, 3, 2, nil, nil]
      assert Enum.map(chart.days, & &1.remaining_estimate) == [480, 360, 240, nil, nil]
      assert Enum.map(chart.days, & &1.ideal) == [4.0, 3.0, 2.0, 1.0, 0.0]
    end

    test "velocity is committed and completed per sprint, averaged over finished ones", %{
      sprints: sprints,
      work: work
    } do
      [todo | _] = work.columns
      {:ok, one} = Sprints.create_sprint(sprints, %{"start" => "2026-01-05", "days" => "14"})
      {:ok, two} = Sprints.create_sprint(sprints, %{"start" => "2026-01-19", "days" => "14"})
      {:ok, three} = Sprints.create_sprint(sprints, %{"start" => "2026-02-02", "days" => "14"})

      fill = fn sprint, n, done ->
        cards = for _ <- 1..n, do: card_fixture(todo)
        {:ok, _} = Sprints.add_cards(sprint, cards)

        cards
        |> Enum.take(done)
        |> Enum.each(&complete_on(Boards.get_card!(&1.id), sprint.start_date))
      end

      fill.(one, 5, 3)
      fill.(two, 4, 4)
      fill.(three, 6, 1)

      v = Sprints.velocity(sprints, ~D[2026-02-05])

      assert Enum.map(v.sprints, &{&1.title, &1.committed, &1.completed, &1.finished}) == [
               {"Sprint 1", 5, 3, true},
               {"Sprint 2", 4, 4, true},
               {"Sprint 3", 6, 1, false}
             ]

      assert v.average == 3.5
      assert Sprints.current_sprint(sprints, ~D[2026-02-05]).id == three.id
      assert Sprints.current_sprint(sprints, ~D[2026-01-20]).id == two.id
    end
  end
end
