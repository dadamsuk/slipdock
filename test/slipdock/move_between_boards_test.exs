defmodule Slipdock.MoveBetweenBoardsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields}
  alias Slipdock.Boards.{Board, Card, Tag}

  setup do
    from = board_fixture(%{"name" => "Plan"})
    to = board_fixture(%{"name" => "Errands"})
    [from_backlog, from_todo | _] = from.columns
    [to_backlog, to_todo | _] = to.columns

    %{
      from: from,
      to: to,
      from_backlog: from_backlog,
      from_todo: from_todo,
      to_backlog: to_backlog,
      to_todo: to_todo
    }
  end

  defp reload_card(card), do: Boards.Cards.get_card!(card.id)

  test "the card lands on the other board, in the list it was sent to", %{
    from_todo: from_todo,
    to: to,
    to_backlog: to_backlog
  } do
    keep = card_fixture(from_todo, %{"title" => "Stays"})
    card = card_fixture(from_todo, %{"title" => "Goes"})

    assert {:ok, %{card: moved}} = Boards.Moves.move_card_to_board(card, to_backlog)

    assert moved.board_id == to.id
    assert moved.column_id == to_backlog.id

    # And the list it left closes the gap behind it.
    left =
      Boards.get_board!(from_todo.board_id).columns
      |> Enum.find(&(&1.id == from_todo.id))
      |> Map.get(:cards)

    assert [%{id: kept_id, position: 0}] = left
    assert kept_id == keep.id
  end

  test "tags travel by name, making the ones the other board lacks", %{
    from: from,
    from_todo: from_todo,
    to: to,
    to_backlog: to_backlog
  } do
    bug = tag_fixture(from, "bug", "red")
    urgent = tag_fixture(from, "urgent", "amber")
    _theirs = tag_fixture(to, "Bug", "sky")

    card = card_fixture(from_todo, %{"title" => "Goes"})
    Boards.Cards.set_card_tags(card, [bug, urgent])

    assert {:ok, %{tags_created: 1}} = Boards.Moves.move_card_to_board(card, to_backlog)

    names = reload_card(card).tags |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["Bug", "urgent"]

    # The new tag is the destination's, not a stray pointer at the old board.
    assert Enum.all?(reload_card(card).tags, &(&1.board_id == to.id))
    assert Enum.map(Boards.Tags.list_tags(to.id), & &1.name) |> Enum.sort() == ["Bug", "urgent"]

    # …and the board it left keeps its own.
    assert Enum.map(Boards.Tags.list_tags(from.id), & &1.name) |> Enum.sort() == ["bug", "urgent"]
  end

  test "subcards come too, and their tags are remapped with the card's", %{
    from: from,
    from_todo: from_todo,
    to: to,
    to_backlog: to_backlog
  } do
    bug = tag_fixture(from, "bug", "red")
    epic = card_fixture(from_todo, %{"title" => "Epic"})
    {:ok, sub} = sub_board(epic, hd(Boards.Templates.list_templates(nil)))
    sub = Boards.get_board!(sub.id)
    subcard = card_fixture(hd(sub.columns), %{"title" => "Step one"})
    Boards.Cards.set_card_tags(subcard, [bug])

    assert {:ok, _} = Boards.Moves.move_card_to_board(epic, to_backlog)

    # The sub-board is re-rooted, so its tags and fields resolve on the new tree.
    assert Repo.get!(Board, sub.id).root_id == to.id
    assert [%Tag{name: "bug", board_id: to_id}] = reload_card(subcard).tags
    assert to_id == to.id

    # The subcard itself did not move board: it still lives on the sub-board.
    assert reload_card(subcard).board_id == sub.id
  end

  test "a card cannot be moved into its own subcards", %{from_todo: from_todo} do
    epic = card_fixture(from_todo, %{"title" => "Epic"})
    {:ok, sub} = sub_board(epic, hd(Boards.Templates.list_templates(nil)))
    sub = Boards.get_board!(sub.id)

    assert {:error, message} = Boards.Moves.move_card_to_board(epic, hd(sub.columns))
    assert message =~ "its own subcards"
  end

  test "field values follow a field of the same key and kind, and are dropped otherwise", %{
    from: from,
    from_todo: from_todo,
    to: to,
    to_backlog: to_backlog
  } do
    {:ok, effort} = Fields.create_field(from, %{"name" => "Effort", "kind" => "number"})
    {:ok, notes} = Fields.create_field(from, %{"name" => "Notes", "kind" => "text"})
    {:ok, _} = Fields.create_field(to, %{"name" => "Effort", "kind" => "number"})

    card = card_fixture(from_todo, %{"title" => "Goes"})
    {:ok, _} = Fields.set_value(card, effort, "3")
    {:ok, _} = Fields.set_value(card, notes, "careful")

    assert {:ok, %{fields_dropped: 1}} = Boards.Moves.move_card_to_board(card, to_backlog)

    values = reload_card(card).field_values
    assert [%{number: 3.0}] = values
    assert hd(values).field_id == hd(Fields.list_fields(to.id)).id
  end

  test "a pinned milestone is unpinned; it is the old board's date", %{
    from: from,
    from_todo: from_todo,
    to_backlog: to_backlog
  } do
    card = card_fixture(from_todo, %{"title" => "Goes"})

    {:ok, milestone} =
      Boards.Milestones.create_milestone(from, %{
        "name" => "Launch",
        "date" => Date.utc_today(),
        "card_id" => card.id
      })

    assert {:ok, %{milestones_unpinned: 1}} = Boards.Moves.move_card_to_board(card, to_backlog)
    assert is_nil(Boards.Milestones.get_milestone!(milestone.id).card_id)
  end

  test "landing in a done list completes the card, as it does on one board", %{
    from_todo: from_todo,
    to: to
  } do
    card = card_fixture(from_todo, %{"title" => "Goes"})
    done = Enum.find(to.columns, &(&1.category == "done"))

    assert {:ok, _} = Boards.Moves.move_card_to_board(card, done)
    assert reload_card(card).completed
  end

  test "moving inside one tree keeps the tags it already shares", %{
    from: from,
    from_todo: from_todo,
    from_backlog: from_backlog
  } do
    bug = tag_fixture(from, "bug", "red")
    epic = card_fixture(from_backlog, %{"title" => "Epic"})
    {:ok, sub} = sub_board(epic, hd(Boards.Templates.list_templates(nil)))
    sub = Boards.get_board!(sub.id)
    subcard = card_fixture(hd(sub.columns), %{"title" => "Step one"})
    Boards.Cards.set_card_tags(subcard, [bug])

    # Promoting a subcard to the board above it: same tree, nothing to remap.
    assert {:ok, %{tags_created: 0}} = Boards.Moves.move_card_to_board(subcard, from_todo)

    assert reload_card(subcard).board_id == from.id
    assert [%Tag{id: tag_id}] = reload_card(subcard).tags
    assert tag_id == bug.id
    assert length(Boards.Tags.list_tags(from.id)) == 1
  end

  test "an archived card is not moved", %{from_todo: from_todo, to_backlog: to_backlog} do
    card = card_fixture(from_todo, %{"title" => "Goes"})
    {:ok, card} = Boards.Cards.archive_card(card)

    assert {:error, message} = Boards.Moves.move_card_to_board(card, to_backlog)
    assert message =~ "Restore"
    assert %Card{board_id: board_id} = Repo.get!(Card, card.id)
    assert board_id == from_todo.board_id
  end

  test "a move to a list on the same board is just a move", %{
    from_todo: from_todo,
    from_backlog: from_backlog
  } do
    card = card_fixture(from_todo, %{"title" => "Goes"})

    assert {:ok, %{card: moved, tags_created: 0}} =
             Boards.Moves.move_card_to_board(card, from_backlog)

    assert moved.column_id == from_backlog.id
    assert moved.board_id == from_todo.board_id
  end

  test "both boards record it", %{
    from: from,
    from_todo: from_todo,
    to: to,
    to_backlog: to_backlog
  } do
    card = card_fixture(from_todo, %{"title" => "Goes"})
    {:ok, _} = Boards.Moves.move_card_to_board(card, to_backlog)

    assert Enum.any?(
             Boards.ActivityLog.list_activities(from.id),
             &(&1.message =~ "moved “Goes” to Errands")
           )

    assert Enum.any?(
             Boards.ActivityLog.list_activities(to.id),
             &(&1.message =~ "moved “Goes” in from Plan")
           )
  end

  test "each board's row names the other board and its list", %{
    from: from,
    from_todo: from_todo,
    to: to,
    to_backlog: to_backlog
  } do
    # Lists named apart, so a row naming the wrong one shows.
    refute from_todo.name == to_backlog.name
    card = card_fixture(from_todo, %{"title" => "Goes"})
    {:ok, _} = Boards.Moves.move_card_to_board(card, to_backlog)

    messages = fn board ->
      Enum.map(Boards.ActivityLog.list_activities(board.id), & &1.message)
    end

    assert "moved “Goes” to Errands › #{to_backlog.name}" in messages.(from)
    assert "moved “Goes” in from Plan › #{from_todo.name}" in messages.(to)
  end

  test "moved back to its board, the card takes a stand-in's slot below other cards" do
    {:ok, template} = Boards.Templates.find_template(nil, "Sprint planning")
    sprints = board_fixture(%{"name" => "Sprints"}, template: template)
    work = board_fixture(%{"name" => "Work"})
    [_backlog, todo | _] = work.columns
    {:ok, sprint} = Slipdock.Sprints.create_sprint(sprints)

    _a = card_fixture(todo, %{"title" => "A"})
    _b = card_fixture(todo, %{"title" => "B"})
    c = card_fixture(todo, %{"title" => "C"})
    {:ok, %{added: [moved]}} = Slipdock.Sprints.add_cards(sprint, [c])
    [stand_in] = Boards.Cards.stand_ins_for(c.id)
    assert stand_in.position == 2

    assert {:ok, %{card: back}} = Boards.Moves.move_card_to_board(moved, List.last(work.columns))
    assert back.column_id == todo.id
    assert back.position == 2
    assert Boards.Cards.stand_ins_for(c.id) == []
  end

  test "moving inside one tree keeps a pinned milestone pinned", %{
    from: from,
    from_todo: from_todo,
    from_backlog: from_backlog
  } do
    epic = card_fixture(from_backlog, %{"title" => "Epic"})
    {:ok, sub} = sub_board(epic, hd(Boards.Templates.list_templates(nil)))
    subcard = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Step one"})

    {:ok, milestone} =
      Boards.Milestones.create_milestone(from, %{
        "name" => "Launch",
        "date" => Date.utc_today(),
        "card_id" => subcard.id
      })

    # The tree's roadmap is the same on either board, so nothing is carried.
    assert {:ok, %{milestones_unpinned: 0}} = Boards.Moves.move_card_to_board(subcard, from_todo)
    assert Boards.Milestones.get_milestone!(milestone.id).card_id == subcard.id
  end

  test "both boards are told", %{from: from, from_todo: from_todo, to: to, to_backlog: to_backlog} do
    card = card_fixture(from_todo, %{"title" => "Goes"})
    Boards.PubSub.subscribe(from.id)
    Boards.PubSub.subscribe(to.id)

    {:ok, _} = Boards.Moves.move_card_to_board(card, to_backlog)

    from_id = from.id
    to_id = to.id
    assert_received {:board_changed, ^from_id}
    assert_received {:board_changed, ^to_id}
  end

  test "the destination board's card_moved rules run", %{
    from_todo: from_todo,
    to: to,
    to_backlog: to_backlog
  } do
    rule_fixture(to, %{
      "trigger" => %{"type" => "card_moved", "to" => to_backlog.name},
      "actions" => [
        %{"type" => "alert", "title" => "{{card.title}} came in", "severity" => "info"}
      ]
    })

    card = card_fixture(from_todo, %{"title" => "Goes"})
    {:ok, _} = Boards.Moves.move_card_to_board(card, to_backlog)

    assert [alert] = Slipdock.Automations.list_alerts(user_fixture())
    assert alert.title == "Goes came in"
    assert alert.card_id == card.id
  end
end
