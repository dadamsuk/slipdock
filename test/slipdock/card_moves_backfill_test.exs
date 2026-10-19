defmodule Slipdock.CardMovesBackfillTest do
  @moduledoc """
  The movement ledger's backfill (#1112): the SQL the migration that made
  `card_moves` runs to recover each card's history from the activity log.
  Run here against a seeded log, on cards that have no ledger rows yet.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.Repo
  alias Slipdock.Boards.{Activity, Card, CardMove, Column}

  [{migration, _}] =
    Code.require_file("priv/repo/migrations/20261019013000_create_card_moves.exs")

  @migration migration

  setup do
    board = board_fixture(%{"name" => "Home #{System.unique_integer([:positive])}"})
    other = board_fixture(%{"name" => "Away #{System.unique_integer([:positive])}"})
    [_backlog, todo, doing, done] = board.columns
    doing = doing |> Ecto.Changeset.change(name: "Doing") |> Repo.update!()
    qa = Repo.insert!(%Column{board_id: board.id, name: "QA", category: "doing", position: 5})
    later1 = Repo.insert!(%Column{board_id: board.id, name: "Later", position: 6})
    _later2 = Repo.insert!(%Column{board_id: board.id, name: "Later", position: 7})
    [_, inbox, _, _] = other.columns
    inbox = inbox |> Ecto.Changeset.change(name: "Inbox") |> Repo.update!()

    %{
      board: board,
      other: other,
      todo: todo,
      doing: doing,
      done: done,
      qa: qa,
      later: later1,
      inbox: inbox
    }
  end

  @t0 ~U[2026-01-01 09:00:00Z]

  defp at(minutes), do: DateTime.add(@t0, minutes * 60)

  defp card(column, title, extra \\ []) do
    Repo.insert!(
      struct!(
        %Card{
          board_id: column.board_id,
          column_id: column.id,
          title: title,
          position: 0,
          inserted_at: @t0,
          updated_at: @t0
        },
        extra
      )
    )
  end

  defp activity(board, card, minutes, message) do
    Repo.insert!(%Activity{
      board_id: board.id,
      card_id: card && card.id,
      kind: "card",
      message: message,
      inserted_at: at(minutes)
    })
  end

  defp backfill do
    for sql <- @migration.backfill_sql(), do: Repo.query!(sql)
  end

  defp rows(card) do
    Repo.all(
      from(m in CardMove, where: m.card_id == ^card.id, order_by: [asc: m.inserted_at, asc: m.id])
    )
  end

  defp lists(rows), do: Enum.map(rows, &{&1.kind, &1.from_column_name, &1.to_column_name})

  test "recovers a mixed log, row for row", ctx do
    %{board: board, other: other, todo: todo, doing: doing, done: done} = ctx

    # A title with "” to " in it: the list is what follows the last one.
    fix = card(done, "Fix the to-do list")
    activity(board, fix, 0, "added “Fix the to-do list” to To Do")
    activity(board, fix, 1, "moved “Fix the to-do list” to Doing")
    activity(board, fix, 2, "moved “Fix the to-do list” to Done")

    # Moved into "Review", since renamed QA: that move is dropped, and the
    # move after it has no source, so the To Do stay doesn't stretch over it.
    renamed = card(done, "Renamed list")
    activity(board, renamed, 0, "added “Renamed list” to To Do")
    activity(board, renamed, 1, "moved “Renamed list” to Review")
    activity(board, renamed, 2, "moved “Renamed list” to Done")

    # Two lists called Later: ambiguous, so skipped.
    twice = card(done, "Twice named")
    activity(board, twice, 0, "added “Twice named” to To Do")
    activity(board, twice, 1, "moved “Twice named” to Later")
    activity(board, twice, 2, "moved “Twice named” to Done")

    # Nothing in the log: created where it is.
    quiet = card(todo, "Quiet")

    # Added to a list that has gone, and never moved: created where it is.
    gone = card(doing, "Gone list")
    activity(board, gone, 0, "added “Gone list” to Somewhere")

    # Moved to the other board: the leaving line on this board has no card;
    # the arriving line on the other names where it came from.
    away = card(ctx.inbox, "Travelling")
    activity(board, away, 0, "added “Travelling” to Doing")
    activity(board, nil, 3, "moved “Travelling” to #{other.name} › Inbox")
    activity(other, away, 3, "moved “Travelling” in from #{board.name} › Doing")

    # Put away and brought back, in the list it was in.
    shelved = card(doing, "Shelved")
    activity(board, shelved, 0, "added “Shelved” to Doing")
    activity(board, shelved, 4, "archived “Shelved”")
    activity(board, shelved, 5, "restored “Shelved”")

    # A stand-in has no history of its own.
    stand_in = card(todo, "Shelved", stand_in_for_id: shelved.id)

    backfill()

    assert lists(rows(fix)) == [
             {"created", nil, "To Do"},
             {"moved", "To Do", "Doing"},
             {"moved", "Doing", "Done"}
           ]

    assert lists(rows(renamed)) == [{"created", nil, "To Do"}, {"moved", nil, "Done"}]
    # The stay in To Do ends only at a row leaving To Do, and there is none.
    refute Enum.any?(rows(renamed), &(&1.from_column_id == todo.id))

    assert lists(rows(twice)) == [{"created", nil, "To Do"}, {"moved", nil, "Done"}]
    assert lists(rows(quiet)) == [{"created", nil, "To Do"}]
    assert lists(rows(gone)) == [{"created", nil, "Doing"}]

    assert [created, crossed] = rows(away)

    assert {created.kind, created.board_id, created.to_column_id} ==
             {"created", board.id, doing.id}

    assert crossed.kind == "moved"
    assert {crossed.from_board_id, crossed.from_column_id} == {board.id, doing.id}
    assert {crossed.board_id, crossed.to_column_id} == {other.id, ctx.inbox.id}
    assert crossed.inserted_at == usec(at(3))

    assert lists(rows(shelved)) == [
             {"created", nil, "Doing"},
             {"archived", "Doing", nil},
             {"restored", nil, "Doing"}
           ]

    assert rows(stand_in) == []

    # The created row is the card's own time; the rest are the log's.
    assert hd(rows(fix)).inserted_at == usec(@t0)
    assert Enum.map(tl(rows(fix)), & &1.inserted_at) == [usec(at(1)), usec(at(2))]

    # Ids and categories as well as names.
    [_, to_doing, to_done] = rows(fix)
    assert {to_doing.from_column_id, to_doing.to_column_id} == {todo.id, doing.id}
    assert {to_doing.from_category, to_doing.to_category} == {"todo", "doing"}
    assert {to_done.to_column_id, to_done.to_category} == {done.id, "done"}

    ids = [fix, renamed, twice, quiet, gone, away, shelved, stand_in] |> Enum.map(& &1.id)
    all = Repo.all(from(m in CardMove, where: m.card_id in ^ids))
    assert length(all) == 14
    assert Enum.all?(all, & &1.backfilled)
    assert Enum.all?(all, &is_nil(&1.actor_kind))
    assert Enum.all?(all, &(is_nil(&1.via) and is_nil(&1.user_id) and is_nil(&1.agent)))
  end

  test "leaves a card that already has ledger rows alone, so it can run again", ctx do
    card = card(ctx.todo, "Has history")
    activity(ctx.board, card, 1, "moved “Has history” to Doing")

    backfill()
    assert length(rows(card)) == 2

    backfill()
    assert length(rows(card)) == 2
  end

  test "a list renamed back to a name it now shares is still ambiguous", ctx do
    card = card(ctx.qa, "Into QA")
    activity(ctx.board, card, 1, "moved “Into QA” to QA")
    Repo.insert!(%Column{board_id: ctx.board.id, name: "QA", position: 9})

    backfill()

    assert lists(rows(card)) == [{"created", nil, nil}]
  end

  test "a move to another board with no leaving line keeps neither end", ctx do
    card = card(ctx.inbox, "Half a move")
    activity(ctx.other, card, 1, "moved “Half a move” in from #{ctx.board.name} › Doing")

    backfill()

    # Moves exist but none parsed: where it was created is unknown.
    assert lists(rows(card)) == [{"created", nil, nil}]
  end

  defp usec(dt), do: %{dt | microsecond: {0, 6}}
end
