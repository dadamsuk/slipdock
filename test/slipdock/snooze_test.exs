defmodule Slipdock.SnoozeTest do
  # Snooze (W-1803): the data, the one query helper and every site it is
  # applied at. Waking is in snooze_wake_test.exs.
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Repo, Runners, Snooze}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"timezone" => "Europe/London"})
    board = board_fixture(%{"name" => "Snoozy"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp later, do: DateTime.add(DateTime.utc_now(:second), 3 * 86_400)

  defp snoozed(column, owner, attrs \\ %{}) do
    card = card_fixture(column, attrs)
    {:ok, card} = Snooze.snooze(card, owner, later())
    card
  end

  defp ids(cards), do: cards |> Enum.map(& &1.id) |> Enum.sort()

  describe "snooze/4" do
    test "sets the moment, who, the note and how it wakes", ctx do
      card = card_fixture(ctx.todo)
      until = later()

      {:ok, card} =
        Snooze.snooze(card, ctx.owner, until,
          note: "  waiting for the quote ",
          notify: true,
          wake_on_activity: false
        )

      assert card.snoozed_until == until
      assert card.snoozed_by_id == ctx.owner.id
      assert card.snooze_note == "waiting for the quote"
      assert card.snooze_notify
      refute card.snooze_wake_on_activity
      assert Card.snoozed?(card)

      [line | _] = Boards.list_activities(ctx.board.id, 1, card.id)
      assert line.message =~ "snoozed “#{card.title}” until"
      assert line.message =~ "waiting for the quote"
    end

    test "a date is midnight in the snoozer's timezone", ctx do
      card = card_fixture(ctx.todo)
      # 1 July 2030: London is on BST, an hour ahead of UTC.
      {:ok, card} = Snooze.snooze(card, ctx.owner, ~D[2030-07-01])
      assert card.snoozed_until == ~U[2030-06-30 23:00:00Z]
    end

    test "reads ISO datetimes and quick add's date phrases", ctx do
      now = ~U[2030-01-09 12:00:00Z]
      # 9 Jan 2030 is a Wednesday, London on GMT.
      assert {:ok, ~U[2030-01-10 00:00:00Z]} = Snooze.resolve_until("tomorrow", ctx.owner, now)
      assert {:ok, ~U[2030-01-14 00:00:00Z]} = Snooze.resolve_until("mon", ctx.owner, now)
      assert {:ok, ~U[2030-02-03 00:00:00Z]} = Snooze.resolve_until("2030-02-03", ctx.owner, now)

      assert {:ok, ~U[2030-02-03 09:30:00Z]} =
               Snooze.resolve_until("2030-02-03T10:30:00+01:00", ctx.owner, now)

      assert {:error, :bad_date} = Snooze.resolve_until("someday", ctx.owner, now)
      assert {:error, :bad_date} = Snooze.resolve_until(42, ctx.owner, now)
    end

    test "with nobody, a date is midnight UTC", ctx do
      {:ok, card} = Snooze.snooze(card_fixture(ctx.todo), nil, ~D[2030-07-01])
      assert card.snoozed_until == ~U[2030-07-01 00:00:00Z]
      assert card.snoozed_by_id == nil
    end

    test "refuses the past, a completed, archived or stand-in card, a long note", ctx do
      card = card_fixture(ctx.todo)
      past = DateTime.add(DateTime.utc_now(), -60)
      assert {:error, :past} = Snooze.snooze(card, ctx.owner, past)
      assert {:error, :past} = Snooze.snooze(card, ctx.owner, "yesterday")
      assert {:error, :bad_date} = Snooze.snooze(card, ctx.owner, "whenever")

      assert {:error, :note_too_long} =
               Snooze.snooze(card, ctx.owner, later(), note: String.duplicate("x", 281))

      assert {:ok, _} = Snooze.snooze(card, ctx.owner, later(), note: String.duplicate("x", 280))

      done = card_fixture(ctx.todo, %{"completed" => true})
      assert {:error, :completed} = Snooze.snooze(done, ctx.owner, later())

      {:ok, archived} = Boards.archive_card(card_fixture(ctx.todo))
      assert {:error, :archived} = Snooze.snooze(archived, ctx.owner, later())

      %Card{} = other = card_fixture(ctx.todo)
      stand_in = %{other | stand_in_for_id: card.id}
      assert {:error, :stand_in} = Snooze.snooze(stand_in, ctx.owner, later())

      refute Card.snoozed?(Repo.get!(Card, done.id))
    end

    test "archiving clears the snooze", ctx do
      card = snoozed(ctx.todo, ctx.owner)
      {:ok, archived} = Boards.archive_card(Repo.get!(Card, card.id))
      assert archived.snoozed_until == nil
      {:ok, back} = Boards.unarchive_card(archived)
      refute Card.snoozed?(back)
    end
  end

  describe "Card.snoozed?/2" do
    test "only while the moment is ahead" do
      now = ~U[2030-01-01 00:00:00Z]
      assert Card.snoozed?(%{snoozed_until: ~U[2030-01-01 00:00:01Z]}, now)
      refute Card.snoozed?(%{snoozed_until: now}, now)
      refute Card.snoozed?(%{snoozed_until: nil}, now)
      refute Card.snoozed?(%{}, now)
    end
  end

  describe "left out of" do
    test "the board's lists, into the list's snoozed", ctx do
      awake = card_fixture(ctx.todo, %{"title" => "Awake"})
      asleep = snoozed(ctx.todo, ctx.owner, %{"title" => "Asleep"})
      # One whose time has passed but the tick hasn't cleared is awake.
      overslept = card_fixture(ctx.todo, %{"title" => "Overslept"})

      Repo.update_all(from(c in Card, where: c.id == ^overslept.id),
        set: [snoozed_until: DateTime.add(DateTime.utc_now(:second), -60)]
      )

      todo = Enum.find(reload(ctx.board).columns, &(&1.id == ctx.todo.id))
      assert ids(todo.cards) == ids([awake, overslept])
      assert ids(todo.snoozed) == [asleep.id]
      # Decorated as the rest, so the footer can show it.
      assert hd(todo.snoozed).rollup
    end

    test "a sprint keeps its snoozed work in view", ctx do
      sprints = board_fixture(%{"name" => "Sprints", "kind" => "sprints"}, owner: ctx.owner)
      sprint = card_fixture(hd(sprints.columns), %{"title" => "Sprint 1"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(sprint, t)
      sub = reload(sub)
      work = snoozed(hd(sub.columns), ctx.owner)

      col = hd(reload(sub).columns)
      assert work.id in ids(col.cards)
      assert col.snoozed == []
    end

    test "a snoozed card on an ordinary sub-board is left out", ctx do
      epic = card_fixture(ctx.todo)
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      work = snoozed(hd(reload(sub).columns), ctx.owner)

      col = hd(reload(sub).columns)
      assert ids(col.snoozed) == [work.id]
      refute work.id in ids(col.cards)
    end

    test "My work", ctx do
      awake = card_fixture(ctx.todo, %{"assignee_id" => ctx.owner.id})
      asleep = snoozed(ctx.todo, ctx.owner, %{"assignee_id" => ctx.owner.id})

      mine = ids(Boards.list_assigned_cards(ctx.owner))
      assert awake.id in mine
      refute asleep.id in mine
    end

    test "list_cards by default; include and only on request", ctx do
      awake = card_fixture(ctx.todo)
      asleep = snoozed(ctx.todo, ctx.owner)

      assert ids(Boards.list_cards(ctx.board)) == [awake.id]
      assert ids(Boards.list_cards(ctx.board, %{"snoozed" => "exclude"})) == [awake.id]
      assert ids(Boards.list_cards(ctx.board, %{"snoozed" => "include"})) == ids([awake, asleep])
      assert ids(Boards.list_cards(ctx.board, %{"snoozed" => "only"})) == [asleep.id]
      # --deps ready reads list_cards, so a snoozed card is never ready.
      assert ids(Boards.list_cards(ctx.board, %{"deps" => "ready"})) == [awake.id]
    end

    test "the list_top runner pick", ctx do
      {:ok, _runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})

      rule =
        rule_fixture(
          ctx.board,
          %{
            "trigger" => %{"type" => "list_top", "column" => "To Do"},
            "actions" => [%{"type" => "runner", "pool" => "loop"}]
          },
          %{"enabled" => false}
        )

      top = snoozed(ctx.todo, ctx.owner, %{"title" => "Top"})
      next = card_fixture(ctx.todo, %{"title" => "Next"})
      :ok = Boards.move_card(top.id, ctx.todo.id, next.id)

      assert Automations.next_card(rule).id == next.id
    end

    test "the guide's counts, as a separate snoozed N", ctx do
      card_fixture(ctx.todo)
      snoozed(ctx.todo, ctx.owner)

      guide = SlipdockWeb.APIGuide.markdown(user: ctx.owner)
      assert guide =~ "To Do (todo, 1 open of 1, snoozed 1)"
    end

    test "the stale and due-soon triggers", ctx do
      for trigger <- [
            %{"type" => "card_stale", "days" => 7},
            %{"type" => "card_due_soon", "within_hours" => 24}
          ] do
        rule_fixture(ctx.board, %{
          "trigger" => trigger,
          "actions" => [%{"type" => "add_flags", "flags" => ["flagged"]}]
        })
      end

      today = Date.to_iso8601(Date.utc_today())
      asleep = snoozed(ctx.todo, ctx.owner, %{"due_date" => today})
      sleepy_stale = snoozed(ctx.todo, ctx.owner)
      awake = card_fixture(ctx.todo, %{"due_date" => today})
      stale = card_fixture(ctx.todo)
      then = DateTime.add(DateTime.utc_now(:second), -10 * 86_400)

      Repo.update_all(from(c in Card, where: c.id in ^[sleepy_stale.id, stale.id]),
        set: [updated_at: then]
      )

      assert Automations.run_scheduled() == 2
      assert Repo.get!(Card, awake.id).flags == ["flagged"]
      assert Repo.get!(Card, stale.id).flags == ["flagged"]
      assert Repo.get!(Card, asleep.id).flags == []
      assert Repo.get!(Card, sleepy_stale.id).flags == []
    end
  end

  describe "still counted" do
    test "an epic whose only open subcards are snoozed isn't done", ctx do
      epic = card_fixture(ctx.todo)
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      [first | _] = reload(sub).columns
      card_fixture(first, %{"completed" => true})
      snoozed(first, ctx.owner)

      epic = Boards.get_card!(epic.id)
      assert Card.progress(epic) == {1, 2}
      refute Card.health(epic) == :done
    end

    test "get_card reads a snoozed card", ctx do
      card = snoozed(ctx.todo, ctx.owner)
      assert Card.snoozed?(Boards.get_card!(card.id))
    end
  end
end
