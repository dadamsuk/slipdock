defmodule Slipdock.SnoozeWakeTest do
  # Snooze (W-1803): waking — by the clock, by hand, and by somebody else's
  # comment or assignment — and the card_woken trigger.
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Repo, Snooze}
  alias Slipdock.Automations.Scheduler
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"name" => "Ann"})

    {:ok, other} =
      Slipdock.Accounts.update_profile(user_fixture("bo@example.com"), %{"name" => "Bo"})

    board = board_fixture(%{"name" => "Wakey"}, owner: owner)
    share_fixture(board, [other])
    [_backlog, todo | _] = board.columns
    %{owner: owner, other: other, board: board, todo: todo}
  end

  defp soon, do: DateTime.add(DateTime.utc_now(:second), 3600)

  # A card at the bottom of To Do, snoozed for an hour.
  defp asleep(ctx, opts \\ []) do
    card_fixture(ctx.todo, %{"title" => "First"})
    card = card_fixture(ctx.todo, %{"title" => "Sleeper"})
    {:ok, card} = Snooze.snooze(card, ctx.owner, soon(), opts)
    card
  end

  defp top_of(column) do
    column.id |> Boards.active_items() |> List.first()
  end

  defp later, do: DateTime.add(DateTime.utc_now(), 7200)

  describe "tick/1" do
    test "wakes a card whose time has come: cleared, on top, said so", ctx do
      card = asleep(ctx, note: "the vendor's quote")

      assert Snooze.tick(DateTime.utc_now()) == 0
      assert Card.snoozed?(Repo.get!(Card, card.id))

      assert Snooze.tick(later()) == 1
      woke = Repo.get!(Card, card.id)
      assert woke.snoozed_until == nil
      assert woke.snoozed_by_id == nil
      assert woke.snooze_note == nil
      assert top_of(ctx.todo) == {:card, card.id}

      [line | _] = Boards.list_activities(ctx.board.id, 1, card.id)
      assert line.message =~ "woke up “Sleeper” (snoozed by Ann on "
      assert line.message =~ ": the vendor's quote)"
    end

    test "is idempotent: a second tick wakes nothing", ctx do
      card = asleep(ctx)
      assert Snooze.tick(later()) == 1
      assert Snooze.tick(later()) == 0

      lines = Boards.list_activities(ctx.board.id, 50, card.id)
      assert Enum.count(lines, &(&1.message =~ "woke up")) == 1
    end

    test "two readers of one card wake it once", ctx do
      card = asleep(ctx)
      stale_copy = Repo.get!(Card, card.id)
      assert {:ok, _} = Snooze.wake(stale_copy, reason: :time)
      assert {:error, :not_snoozed} = Snooze.wake(stale_copy, reason: :time)
    end

    test "the scheduler's tick runs it", ctx do
      card = asleep(ctx)

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [snoozed_until: DateTime.add(DateTime.utc_now(:second), -1)]
      )

      Scheduler.handle_info(:tick, %{})
      refute Repo.get!(Card, card.id).snoozed_until
    end

    test "alerts the board when the snooze asked, and not otherwise", ctx do
      quiet = asleep(ctx)
      loud = asleep(ctx, notify: true)
      assert Snooze.tick(later()) == 2

      alerts = Automations.list_alerts(ctx.owner)
      assert [%{card_id: id, title: "Awake: Sleeper"}] = alerts
      assert id == loud.id
      refute Enum.any?(alerts, &(&1.card_id == quiet.id))
    end

    test "an archived card is left alone", ctx do
      card = asleep(ctx)
      # Archive clears the snooze; force one back to check the tick skips it.
      {:ok, archived} = Boards.archive_card(Repo.get!(Card, card.id))

      Repo.update_all(from(c in Card, where: c.id == ^archived.id),
        set: [snoozed_until: DateTime.utc_now(:second)]
      )

      assert Snooze.tick(later()) == 0
    end
  end

  describe "wake/2 by hand" do
    test "wakes it now, and says who", ctx do
      card = asleep(ctx, notify: true)
      {:ok, woke} = Snooze.wake(Repo.get!(Card, card.id), by: ctx.other)
      refute Card.snoozed?(woke)
      [line | _] = Boards.list_activities(ctx.board.id, 1, card.id)
      assert line.message =~ ", woken by Bo"
      # Someone else woke it, so the snoozer is told.
      assert [_] = Automations.list_alerts(ctx.owner)
    end

    test "the snoozer waking it needs no alert", ctx do
      card = asleep(ctx, notify: true)
      {:ok, _} = Snooze.wake(Repo.get!(Card, card.id), by: ctx.owner)
      assert Automations.list_alerts(ctx.owner) == []
    end

    test "a card that isn't snoozed", ctx do
      card = card_fixture(ctx.todo)
      assert {:error, :not_snoozed} = Snooze.wake(card)
      assert {:error, :not_snoozed} = Snooze.wake(nil)
    end
  end

  describe "waking on activity" do
    test "a comment by somebody else wakes it", ctx do
      card = asleep(ctx)
      {:ok, _} = Boards.add_comment(Repo.get!(Card, card.id), "any news?", by: ctx.other)

      woke = Repo.get!(Card, card.id)
      refute Card.snoozed?(woke)
      assert top_of(ctx.todo) == {:card, card.id}

      [line | _] =
        Boards.list_activities(ctx.board.id, 5, card.id) |> Enum.filter(&(&1.message =~ "woke"))

      assert line.message =~ "by Bo's activity"
    end

    test "a comment by the snoozer doesn't", ctx do
      card = asleep(ctx)
      {:ok, _} = Boards.add_comment(Repo.get!(Card, card.id), "note to self", by: ctx.owner)
      assert Card.snoozed?(Repo.get!(Card, card.id))
    end

    test "nor anything, when the snooze said not to", ctx do
      card = asleep(ctx, wake_on_activity: false)
      {:ok, _} = Boards.add_comment(Repo.get!(Card, card.id), "any news?", by: ctx.other)
      assert Card.snoozed?(Repo.get!(Card, card.id))
    end

    test "assigning it to someone new wakes it", ctx do
      card = asleep(ctx)

      {:ok, _} =
        Boards.update_card(Repo.get!(Card, card.id), %{"assignee_id" => ctx.other.id},
          by: ctx.other
        )

      refute Card.snoozed?(Repo.get!(Card, card.id))
    end

    test "a change that adds nobody doesn't", ctx do
      card = asleep(ctx)

      {:ok, _} =
        Boards.update_card(Repo.get!(Card, card.id), %{"title" => "Renamed"}, by: ctx.other)

      assert Card.snoozed?(Repo.get!(Card, card.id))
    end
  end

  describe "card_woken" do
    test "runs the rules that wait for it", ctx do
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "card_woken"},
        "actions" => [%{"type" => "add_flags", "flags" => ["starred"]}]
      })

      card = asleep(ctx)
      other = card_fixture(ctx.todo)
      assert Snooze.tick(later()) == 1
      assert Repo.get!(Card, card.id).flags == ["starred"]
      assert Repo.get!(Card, other.id).flags == []
    end

    test "is in the vocabulary" do
      assert {:ok, _} =
               Automations.Spec.validate(%{
                 "trigger" => %{"type" => "card_woken"},
                 "actions" => [%{"type" => "add_flags", "flags" => ["starred"]}]
               })

      assert Automations.Spec.catalogue() =~ "card_woken"
    end
  end
end
