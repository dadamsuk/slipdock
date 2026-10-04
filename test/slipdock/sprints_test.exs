defmodule Slipdock.SprintsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Sprints}
  alias Slipdock.Boards.Board

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
end
