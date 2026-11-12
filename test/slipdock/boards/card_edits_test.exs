defmodule Slipdock.Boards.CardEditsTest do
  @moduledoc """
  `CardEdits.edit/3` (#2790): several changes to a card as one write, each
  part landing, the parts that are already so, and every kind of failure
  rolling the rest back.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Recurrence, Repo, Snooze}
  alias Slipdock.Boards.{Card, CardEdits}

  setup do
    owner = user_fixture()
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"timezone" => "Europe/London"})
    board = board_fixture(%{"name" => "Edits"}, owner: owner)
    todo = Enum.at(board.columns, 1)
    card = card_fixture(todo, %{"title" => "The card"})
    %{owner: owner, board: board, todo: todo, card: Boards.Cards.get_card!(card.id)}
  end

  defp later, do: DateTime.add(DateTime.utc_now(:second), 3 * 86_400)

  defp title(new), do: &Boards.Cards.update_card(&1, %{"title" => new})

  defp checklist_lines(card) do
    card.board_id
    |> Boards.ActivityLog.list_activities(50)
    |> Enum.filter(&(&1.kind == "checklist" and &1.message =~ card.title))
  end

  defp fresh(card), do: Boards.Cards.get_card!(card.id)

  describe "every part at once" do
    test "lands together and gives the card back reloaded", ctx do
      blocker = card_fixture(ctx.todo, %{"title" => "Blocker"})
      {:ok, ticked} = Boards.Checklists.add_checklist_item(ctx.card, "first")

      assert {:ok, card} =
               CardEdits.edit(
                 ctx.card,
                 %{
                   fields: title("Renamed"),
                   recurrence: %{"rule" => "every mon"},
                   snooze: {:until, later(), "after the quote"},
                   add_blockers: [blocker],
                   add_checklist: ["second", "third"],
                   check: [ticked]
                 },
                 by: ctx.owner
               )

      assert card.title == "Renamed"
      assert Recurrence.series_of(card).rule =~ "MO"
      assert Card.snoozed?(card)
      assert card.snooze_note == "after the quote"
      assert Enum.map(card.blocked_by, & &1.id) == [blocker.id]

      assert card.checklist_items |> Enum.sort_by(& &1.position) |> Enum.map(&{&1.text, &1.done}) ==
               [{"first", true}, {"second", false}, {"third", false}]

      # The checklist's changes are one activity line, not one per item.
      assert [line] = checklist_lines(card)
      assert line.message =~ "added 2"
      assert line.message =~ "ticked 1"
    end

    test "an empty edit changes nothing", ctx do
      assert {:ok, card} = CardEdits.edit(ctx.card, %{}, by: ctx.owner)
      assert card.title == "The card"
      assert card.updated_at == ctx.card.updated_at
      assert checklist_lines(card) == []
    end
  end

  describe "each part on its own" do
    test "stops a recurrence, unblocks and unticks", ctx do
      blocker = card_fixture(ctx.todo)
      {:ok, _} = Boards.Dependencies.add_dependency(ctx.card, blocker)
      {:ok, _} = Recurrence.set(ctx.card, %{"rule" => "every day"}, ctx.owner)
      {:ok, item} = Boards.Checklists.add_checklist_item(ctx.card, "done already")
      {:ok, item} = Boards.Checklists.toggle_checklist_item(item)

      assert {:ok, card} =
               CardEdits.edit(
                 fresh(ctx.card),
                 %{recurrence: :stop, remove_blockers: [blocker], uncheck: [item]},
                 by: ctx.owner
               )

      assert Recurrence.series_of(card) == nil
      assert card.blocked_by == []
      assert [%{done: false}] = card.checklist_items
    end

    test "skip alone lets the next occurrence go and changes nothing else", ctx do
      {:ok, series} = Recurrence.set(ctx.card, %{"rule" => "every day"}, ctx.owner)

      assert {:ok, card} =
               CardEdits.edit(ctx.card, %{recurrence: %{"skip" => true}}, by: ctx.owner)

      after_skip = Recurrence.series_of(card)
      assert after_skip.rule == series.rule
      assert Date.compare(after_skip.next_on, series.next_on) == :gt
    end

    test "a note alone changes the note and keeps the rest of the snooze", ctx do
      until = later()

      {:ok, _} =
        Snooze.snooze(ctx.card, ctx.owner, until,
          note: "old",
          notify: true,
          wake_on_activity: false
        )

      assert {:ok, card} = CardEdits.edit(ctx.card, %{snooze: {:note, "new"}}, by: ctx.owner)
      assert card.snooze_note == "new"
      assert card.snoozed_until == until
      # How it wakes and who it tells stay as the card had them.
      assert {card.snooze_notify, card.snooze_wake_on_activity} == {true, false}
    end

    test "wakes a snoozed card", ctx do
      {:ok, _} = Snooze.snooze(ctx.card, ctx.owner, later())

      assert {:ok, card} = CardEdits.edit(ctx.card, %{snooze: :wake}, by: ctx.owner)
      refute Card.snoozed?(card)
    end
  end

  describe "what is already so" do
    test "a blocker it has, items ticked or unticked already and an awake card woken", ctx do
      blocker = card_fixture(ctx.todo)
      {:ok, _} = Boards.Dependencies.add_dependency(ctx.card, blocker)
      {:ok, item} = Boards.Checklists.add_checklist_item(ctx.card, "ticked")
      {:ok, item} = Boards.Checklists.toggle_checklist_item(item)
      {:ok, open} = Boards.Checklists.add_checklist_item(ctx.card, "open")
      card = fresh(ctx.card)

      assert {:ok, card} =
               CardEdits.edit(
                 card,
                 %{add_blockers: [blocker], check: [item], uncheck: [open], snooze: :wake},
                 by: ctx.owner
               )

      assert Enum.map(card.blocked_by, & &1.id) == [blocker.id]

      assert card.checklist_items |> Enum.sort_by(& &1.position) |> Enum.map(& &1.done) ==
               [true, false]

      # Neither is a change, so nothing is logged for them: the three lines
      # are the setup's two adds and its tick.
      assert length(checklist_lines(card)) == 3
    end
  end

  describe "a failure rolls everything back" do
    test "a dependency that would make a loop", ctx do
      other = card_fixture(ctx.todo, %{"title" => "Other"})
      {:ok, _} = Boards.Dependencies.add_dependency(other, ctx.card)

      assert {:error, message} =
               CardEdits.edit(
                 ctx.card,
                 %{fields: title("Renamed"), add_checklist: ["lost"], add_blockers: [other]},
                 by: ctx.owner
               )

      assert message =~ "circular dependency"
      card = fresh(ctx.card)
      assert card.title == "The card"
      assert card.checklist_items == []
      assert card.blocked_by == []
    end

    test "a recurrence rule that doesn't parse", ctx do
      assert {:error, "recurrence " <> _} =
               CardEdits.edit(
                 ctx.card,
                 %{fields: title("Renamed"), recurrence: %{"rule" => "now and then"}},
                 by: ctx.owner
               )

      assert fresh(ctx.card).title == "The card"
      assert Recurrence.series_of(ctx.card) == nil
    end

    test "skipping a card that doesn't repeat", ctx do
      assert {:error, message} =
               CardEdits.edit(
                 ctx.card,
                 %{fields: title("Renamed"), recurrence: %{"skip" => true}},
                 by: ctx.owner
               )

      assert message == "card ##{ctx.card.id} doesn't repeat, so there is nothing to skip"
      assert fresh(ctx.card).title == "The card"
    end

    test "a snooze in the past, and a note with no snooze", ctx do
      past = DateTime.add(DateTime.utc_now(:second), -86_400)

      assert {:error, "snooze: the snooze must end in the future"} =
               CardEdits.edit(
                 ctx.card,
                 %{fields: title("Renamed"), snooze: {:until, past, nil}},
                 by: ctx.owner
               )

      assert {:error, "card #" <> rest} =
               CardEdits.edit(
                 ctx.card,
                 %{fields: title("Renamed"), snooze: {:note, "why"}},
                 by: ctx.owner
               )

      assert rest =~ "isn't snoozed"
      assert fresh(ctx.card).title == "The card"
    end

    test "the field write's own error comes back as it gave it, before anything else", ctx do
      refused = {:error, :unprocessable_entity, "no such tag"}

      assert ^refused =
               CardEdits.edit(
                 ctx.card,
                 %{fields: fn _ -> refused end, add_checklist: ["lost"]},
                 by: ctx.owner
               )

      assert fresh(ctx.card).checklist_items == []
    end

    test "a later step undoes the field write", ctx do
      assert {:error, %Ecto.Changeset{}} =
               CardEdits.edit(
                 ctx.card,
                 %{fields: title("Renamed"), add_checklist: [""]},
                 by: ctx.owner
               )

      assert fresh(ctx.card).title == "The card"
    end
  end

  test "by: is required", ctx do
    assert_raise KeyError, fn -> CardEdits.edit(ctx.card, %{}, []) end
  end

  test "a card given without its blockers loaded", ctx do
    blocker = card_fixture(ctx.todo)
    bare = Repo.get!(Card, ctx.card.id)

    assert {:ok, card} = CardEdits.edit(bare, %{add_blockers: [blocker]}, by: ctx.owner)
    assert Enum.map(card.blocked_by, & &1.id) == [blocker.id]
  end
end
