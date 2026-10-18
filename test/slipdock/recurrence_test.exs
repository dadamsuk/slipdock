defmodule Slipdock.RecurrenceTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Boards, Recurrence, Repo, Settings}
  alias Slipdock.Boards.Card
  alias Slipdock.Recurrence.Series

  setup do
    owner = user_fixture()
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"timezone" => "Europe/London"})
    board = board_fixture(%{}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp cards_on(board_id),
    do: Repo.all(from(c in Card, where: c.board_id == ^board_id, order_by: c.id))

  defp complete(card) do
    {:ok, card} = Boards.update_card(Repo.get!(Card, card.id), %{"completed" => true})
    card
  end

  # 11 Jan 2027 is a Monday; London is on GMT, so local is UTC.
  describe "set/3" do
    test "a card with no due date becomes the first occurrence", ctx do
      card = card_fixture(ctx.backlog, %{"title" => "Review invoices"})

      today = Slipdock.Timezones.today("Europe/London")
      {:ok, series} = Recurrence.set(card, %{"rule" => "every day"}, ctx.owner)

      assert series.kind == "fixed"
      assert series.rule == "FREQ=DAILY"
      assert series.timezone == "Europe/London"
      assert series.create_at == ~T[07:00:00]
      assert series.made == 1
      assert Repo.get!(Card, card.id).due_date == today
      assert Repo.get!(Card, card.id).series_id == series.id
      assert series.next_on == Date.add(today, 1)

      assert series.next_at ==
               Slipdock.Timezones.to_utc(Date.add(today, 1), ~T[07:00:00], "Europe/London")
    end

    test "a card with a due date: the next is the occurrence after it", ctx do
      card = card_fixture(ctx.backlog, %{"due_date" => "2027-07-12"})

      {:ok, series} =
        Recurrence.set(card, %{"rule" => "mon", "at" => "09:30", "lead_days" => 2}, ctx.owner)

      assert series.next_on == ~D[2027-07-19]
      # Two days early, at 09:30 BST.
      assert series.next_at == ~U[2027-07-17 08:30:00Z]
      assert Series.summary(series) == "Every week on Mon, 09:30 Europe/London"
    end

    test "changes an existing series rather than adding one", ctx do
      card = card_fixture(ctx.backlog, %{"due_date" => "2027-01-11"})
      {:ok, first} = Recurrence.set(card, %{"rule" => "mon"}, ctx.owner)

      {:ok, second} =
        Recurrence.set(card, %{"rule" => "month 1", "on_missed" => "stack"}, ctx.owner)

      assert first.id == second.id
      assert second.rule == "FREQ=MONTHLY;BYMONTHDAY=1"
      assert second.on_missed == "stack"
      assert second.next_on == ~D[2027-02-01]
      assert Repo.aggregate(Series, :count) >= 1
      assert Recurrence.for_card(card).id == first.id

      # Leaving the rule out keeps it.
      {:ok, third} = Recurrence.set(card, %{"at" => "08:00"}, ctx.owner)
      assert third.rule == "FREQ=MONTHLY;BYMONTHDAY=1"
      assert third.create_at == ~T[08:00:00]
    end

    test "refuses what it can't use", ctx do
      card = card_fixture(ctx.backlog)
      assert {:error, msg} = Recurrence.set(card, %{}, ctx.owner)
      assert msg =~ "how often"
      assert {:error, "rule: " <> _} = Recurrence.set(card, %{"rule" => "sometimes"}, ctx.owner)

      assert {:error, "at: " <> _} =
               Recurrence.set(card, %{"rule" => "mon", "at" => "25:00"}, ctx.owner)

      assert {:error, "at: " <> _} =
               Recurrence.set(card, %{"rule" => "mon", "at" => "soon"}, ctx.owner)

      assert {:error, "column: " <> _} =
               Recurrence.set(card, %{"rule" => "mon", "column" => "Nowhere"}, ctx.owner)

      assert {:error, "timezone: " <> _} =
               Recurrence.set(card, %{"rule" => "mon", "timezone" => "Mars/Base"}, ctx.owner)

      assert {:error, cs} =
               Recurrence.set(card, %{"rule" => "mon", "ends" => "on"}, ctx.owner)

      assert %{ends_on: _} = errors_on(cs)

      assert {:error, cs} =
               Recurrence.set(
                 card,
                 %{"rule" => "mon", "ends" => "after", "count" => 0},
                 ctx.owner
               )

      assert %{count: _} = errors_on(cs)

      assert {:error, cs} =
               Recurrence.set(card, %{"rule" => "mon", "on_missed" => "panic"}, ctx.owner)

      assert %{on_missed: _} = errors_on(cs)

      assert {:error, cs} = Recurrence.set(card, %{"rule" => "mon", "lead_days" => -1}, ctx.owner)
      assert %{lead_days: _} = errors_on(cs)
      assert Recurrence.for_card(card) == nil
    end
  end

  describe "tick/1, fixed rules" do
    setup ctx do
      card =
        card_fixture(ctx.backlog, %{
          "title" => "Weekly review",
          "start_date" => "2027-01-09",
          "due_date" => "2027-01-11",
          "flags" => ["blocked"]
        })

      {:ok, item} = Boards.add_checklist_item(card, "Look back")
      {:ok, _} = Boards.toggle_checklist_item(item)
      {:ok, series} = Recurrence.set(card, %{"rule" => "mon"}, ctx.owner)
      %{card: card, series: series}
    end

    test "nothing before its time", ctx do
      complete(ctx.card)
      assert Recurrence.tick(~U[2027-01-18 06:59:59Z]) == 0
      assert length(cards_on(ctx.board.id)) == 1
    end

    test "copies the finished instance to the top of the ready list, once", ctx do
      card_fixture(ctx.todo, %{"title" => "Already in To Do"})
      complete(ctx.card)

      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 1
      # A second tick at the same moment, or a minute later, makes nothing.
      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 0
      assert Recurrence.tick(~U[2027-01-18 07:01:00Z]) == 0

      series = Repo.get!(Series, ctx.series.id)
      new = Boards.get_card!(series.card_id)

      assert new.id != ctx.card.id
      assert new.title == "Weekly review"
      assert new.column_id == ctx.todo.id
      assert [{:card, top} | _] = Boards.active_items(ctx.todo.id)
      assert top == new.id
      assert new.due_date == ~D[2027-01-18]
      assert new.start_date == ~D[2027-01-16]
      assert new.flags == []
      refute new.completed
      assert [%{text: "Look back", done: false}] = new.checklist_items
      assert new.series_id == series.id
      assert series.last_created_card_id == new.id
      assert series.made == 2
      assert series.next_on == ~D[2027-01-25]
      assert series.next_at == ~U[2027-01-25 07:00:00Z]

      # The old one stays done where it was.
      assert Repo.get!(Card, ctx.card.id).completed
    end

    test "bump (the default): an open instance takes the new date, nothing new is made", ctx do
      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 1

      assert [card] = cards_on(ctx.board.id)
      assert card.due_date == ~D[2027-01-18]
      [comment | _] = Boards.get_card!(card.id).comments
      assert comment.body =~ "Missed occurrence of 2027-01-11"
      assert comment.body =~ "now due 2027-01-18"
      assert Repo.get!(Series, ctx.series.id).next_on == ~D[2027-01-25]

      # Six weeks forgotten is still one card.
      for week <- 1..5,
          do: Recurrence.tick(DateTime.add(~U[2027-01-25 07:00:00Z], week * 7, :day))

      assert length(cards_on(ctx.board.id)) == 1
    end

    test "skip: the open instance is left alone, with a comment", ctx do
      {:ok, _} = Recurrence.set(ctx.card, %{"on_missed" => "skip"}, ctx.owner)
      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 1

      assert [card] = cards_on(ctx.board.id)
      assert card.due_date == ~D[2027-01-11]
      assert hd(Boards.get_card!(card.id).comments).body =~ "Skipped the occurrence of 2027-01-18"
      assert Repo.get!(Series, ctx.series.id).next_on == ~D[2027-01-25]
    end

    test "stack: a new instance even though the last is open", ctx do
      {:ok, _} = Recurrence.set(ctx.card, %{"on_missed" => "stack"}, ctx.owner)
      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 1
      assert length(cards_on(ctx.board.id)) == 2
      refute Repo.get!(Card, ctx.card.id).completed
    end

    test "after a long gap it catches up once, to the latest occurrence", ctx do
      complete(ctx.card)
      assert Recurrence.tick(~U[2027-02-10 12:00:00Z]) == 1
      assert length(cards_on(ctx.board.id)) == 2

      series = Repo.get!(Series, ctx.series.id)
      assert Repo.get!(Card, series.card_id).due_date == ~D[2027-02-08]
      assert series.next_on == ~D[2027-02-15]
    end

    test "a paused series is idle", ctx do
      complete(ctx.card)
      {:ok, _} = Recurrence.set(ctx.card, %{"paused" => true}, ctx.owner)
      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 0
      assert length(cards_on(ctx.board.id)) == 1
    end

    test "the list the series names", ctx do
      complete(ctx.card)
      {:ok, _} = Recurrence.set(ctx.card, %{"column" => ctx.doing.name}, ctx.owner)
      Recurrence.tick(~U[2027-01-18 07:00:00Z])
      series = Repo.get!(Series, ctx.series.id)
      assert Repo.get!(Card, series.card_id).column_id == ctx.doing.id
    end

    test "ends after a count", ctx do
      {:ok, _} = Recurrence.set(ctx.card, %{"ends" => "after", "count" => 2}, ctx.owner)
      complete(ctx.card)
      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 1
      series = Repo.get!(Series, ctx.series.id)
      assert series.made == 2
      assert series.ended_at
      assert series.next_at == nil

      complete(Repo.get!(Card, series.card_id))
      assert Recurrence.tick(~U[2027-01-25 07:00:00Z]) == 0
      assert length(cards_on(ctx.board.id)) == 2
    end

    test "ends on a date", ctx do
      {:ok, _} = Recurrence.set(ctx.card, %{"ends" => "on", "ends_on" => "2027-01-20"}, ctx.owner)
      complete(ctx.card)
      Recurrence.tick(~U[2027-01-18 07:00:00Z])
      series = Repo.get!(Series, ctx.series.id)
      assert series.ended_at
      assert length(cards_on(ctx.board.id)) == 2
    end

    test "skip/1 lets the next occurrence go", ctx do
      {:ok, series} = Recurrence.skip(ctx.card)
      assert series.next_on == ~D[2027-01-25]
      complete(ctx.card)
      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 0
      assert Recurrence.tick(~U[2027-01-25 07:00:00Z]) == 1
    end

    test "an occurrence already acted on is stepped over, not made twice", ctx do
      complete(ctx.card)
      Recurrence.tick(~U[2027-01-18 07:00:00Z])
      series = Repo.get!(Series, ctx.series.id)

      # Wind the series back onto the 18th by hand.
      series
      |> Ecto.Changeset.change(next_on: ~D[2027-01-18], next_at: ~U[2027-01-18 07:00:00Z])
      |> Repo.update!()

      complete(Repo.get!(Card, series.card_id))
      assert Recurrence.tick(~U[2027-01-18 08:00:00Z]) == 0
      assert length(cards_on(ctx.board.id)) == 2
      assert Repo.get!(Series, ctx.series.id).next_on == ~D[2027-01-25]
    end

    test "archiving the current instance pauses it, with a notice", ctx do
      {:ok, _} = Boards.archive_card(Repo.get!(Card, ctx.card.id))
      series = Repo.get!(Series, ctx.series.id)
      assert series.paused
      assert hd(Boards.get_card!(ctx.card.id).comments).body =~ "paused the series"
      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 0
    end

    test "archiving an older instance doesn't", ctx do
      complete(ctx.card)
      Recurrence.tick(~U[2027-01-18 07:00:00Z])
      {:ok, _} = Boards.archive_card(Repo.get!(Card, ctx.card.id))
      refute Repo.get!(Series, ctx.series.id).paused
    end

    test "deleting the current instance removes the series", ctx do
      complete(ctx.card)
      Recurrence.tick(~U[2027-01-18 07:00:00Z])
      series = Repo.get!(Series, ctx.series.id)
      {:ok, _} = Boards.delete_card(Repo.get!(Card, series.card_id))
      assert Repo.get(Series, series.id) == nil
      # The older instance keeps nothing pointing at a series that's gone.
      assert Repo.get!(Card, ctx.card.id).series_id == nil
    end

    test "stop/1", ctx do
      assert {:ok, _} = Recurrence.stop(ctx.card)
      assert Recurrence.for_card(ctx.card) == nil
      assert {:error, :not_found} = Recurrence.stop(ctx.card)
      assert {:error, :not_found} = Recurrence.skip(ctx.card)
    end

    test "series_of/1 finds the series from an older instance", ctx do
      complete(ctx.card)
      Recurrence.tick(~U[2027-01-18 07:00:00Z])
      assert Recurrence.for_card(Repo.get!(Card, ctx.card.id)) == nil
      assert Recurrence.series_of(Repo.get!(Card, ctx.card.id)).id == ctx.series.id
    end

    test "list_for_board/1 includes series on sub-boards", ctx do
      epic = card_fixture(ctx.backlog, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      subcard = card_fixture(hd(sub.columns), %{"title" => "Sub chore"})
      {:ok, _} = Recurrence.set(subcard, %{"rule" => "daily"}, ctx.owner)

      titles = ctx.board |> Recurrence.list_for_board() |> Enum.map(& &1.card.title)
      assert Enum.sort(titles) == ["Sub chore", "Weekly review"]
      assert [%{card: %{title: "Sub chore"}}] = Recurrence.list_for_board(sub)
    end
  end

  describe "after-done rules" do
    test "wait for the current one to be done, then count from the local day", ctx do
      {:ok, tokyo} = Slipdock.Accounts.update_profile(ctx.owner, %{"timezone" => "Asia/Tokyo"})
      card = card_fixture(ctx.backlog, %{"title" => "Water the plants"})
      {:ok, series} = Recurrence.set(card, %{"rule" => "3d after"}, tokyo)

      assert series.kind == "after_done"
      assert series.next_at == nil
      assert Repo.get!(Card, card.id).due_date == nil
      assert Recurrence.tick(~U[2030-01-01 00:00:00Z]) == 0

      # Done at 23:30 UTC on the 11th: already the 12th in Tokyo.
      card = complete(card)

      from(c in Card, where: c.id == ^card.id)
      |> Repo.update_all(set: [completed_at: ~U[2027-01-11 23:30:00Z]])

      Recurrence.completion_changed(Repo.get!(Card, card.id))
      series = Repo.get!(Series, series.id)
      assert series.next_on == ~D[2027-01-15]
      # 07:00 in Tokyo is 22:00 UTC the day before.
      assert series.next_at == ~U[2027-01-14 22:00:00Z]

      assert Recurrence.tick(~U[2027-01-14 22:00:00Z]) == 1
      series = Repo.get!(Series, series.id)
      new = Repo.get!(Card, series.card_id)
      assert new.due_date == ~D[2027-01-15]
      refute new.completed
      # And waits again.
      assert series.next_at == nil
      assert Recurrence.tick(~U[2027-02-01 00:00:00Z]) == 0
    end

    test "reopening before it's made takes it back", ctx do
      card = card_fixture(ctx.backlog)
      {:ok, series} = Recurrence.set(card, %{"rule" => "AFTER=1W"}, ctx.owner)
      card = complete(card)
      assert Repo.get!(Series, series.id).next_at

      {:ok, _} = Boards.update_card(card, %{"completed" => false})
      assert Repo.get!(Series, series.id).next_at == nil
    end

    test "setting one on a card already done schedules from when it was done", ctx do
      card = complete(card_fixture(ctx.backlog))
      {:ok, series} = Recurrence.set(card, %{"rule" => "2d after"}, ctx.owner)

      assert series.next_on ==
               Date.add(Slipdock.Timezones.today("Europe/London", card.completed_at), 2)
    end

    test "skip/1 moves the date it will be due on", ctx do
      card = complete(card_fixture(ctx.backlog))
      {:ok, series} = Recurrence.set(card, %{"rule" => "2d after"}, ctx.owner)
      {:ok, skipped} = Recurrence.skip(card)
      assert skipped.next_on == Date.add(series.next_on, 2)
    end

    test "skip/1 with nothing coming", ctx do
      card = card_fixture(ctx.backlog)
      {:ok, _} = Recurrence.set(card, %{"rule" => "2d after"}, ctx.owner)
      assert {:error, "there is no next occurrence to skip"} = Recurrence.skip(card)
    end
  end

  test "the card limit pauses the series and says so on the card" do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 1})

    owner = user_fixture("full@example.com")
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"due_date" => "2027-01-11"})
    {:ok, series} = Recurrence.set(card, %{"rule" => "mon"}, owner)
    complete(card)

    assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 0
    series = Repo.get!(Series, series.id)
    assert series.paused
    assert series.card_id == card.id
    assert hd(Boards.get_card!(card.id).comments).body =~ "couldn't be made"
    assert Recurrence.tick(~U[2027-01-18 07:01:00Z]) == 0
  end
end
