defmodule Slipdock.RecurrencePortableTest do
  @moduledoc "A recurring card's series survives a portable export and import (W-1802)."
  # Sync, as the other import tests: imports derive board codes.
  use Slipdock.DataCase, async: false

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Portable, Recurrence, Repo}
  alias Slipdock.Recurrence.Series

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Chores", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing | _] = board.columns
    card = card_fixture(todo, %{"title" => "Review invoices", "due_date" => "2030-01-07"})

    {:ok, _} =
      Recurrence.set(
        card,
        %{
          "rule" => "mon",
          "at" => "08:15",
          "timezone" => "Europe/London",
          "lead_days" => 1,
          "column" => doing.name,
          "on_missed" => "stack",
          "ends" => "after",
          "count" => 10
        },
        owner
      )

    %{owner: owner, board: board, card: card, receiver: user_fixture("receiver@example.com")}
  end

  defp import_as_receiver(ctx, document) do
    {:ok, report} = Portable.import(ctx.receiver, Jason.encode!(document))
    board = Boards.get_board!(hd(report.boards).id)
    [card] = Boards.list_cards(board, %{})
    {report, board, card}
  end

  test "the export carries the rule and where it had got to", ctx do
    [tree] = Portable.export(ctx.owner, boards: [ctx.board]).boards
    [card] = tree.cards

    assert %{
             rule: "FREQ=WEEKLY;BYDAY=MO",
             at: "08:15",
             timezone: "Europe/London",
             lead_days: 1,
             on_missed: "stack",
             ends: "after",
             count: 10,
             made: 1,
             next_on: ~D[2030-01-14],
             paused: false,
             ended: false
           } = card.recurrence

    assert is_binary(card.recurrence.list)
  end

  test "the import carries on from there", ctx do
    {_report, board, card} =
      import_as_receiver(ctx, Portable.export(ctx.owner, boards: [ctx.board]))

    series = Repo.get_by!(Series, card_id: card.id)
    assert series.rule == "FREQ=WEEKLY;BYDAY=MO"
    assert series.create_at == ~T[08:15:00]
    assert series.next_on == ~D[2030-01-14]
    # A day early, 08:15 GMT.
    assert series.next_at == ~U[2030-01-13 08:15:00Z]
    assert series.on_missed == "stack"
    assert series.count == 10
    assert series.created_by_id == ctx.receiver.id
    assert Repo.get!(Slipdock.Boards.Card, card.id).series_id == series.id
    doing = Enum.find(board.columns, &(&1.name == "In Progress"))
    assert series.column_id == doing.id
  end

  test "a card that doesn't repeat imports as one that doesn't", ctx do
    {:ok, _} = Recurrence.stop(ctx.card)

    {_report, _board, card} =
      import_as_receiver(ctx, Portable.export(ctx.owner, boards: [ctx.board]))

    assert Repo.all(from(s in Series, where: s.card_id == ^card.id)) == []
  end

  test "a rule this server can't read is left out, and said so", ctx do
    document =
      ctx.owner
      |> Portable.export(boards: [ctx.board])
      |> update_in(
        [:boards, Access.at(0), :cards, Access.at(0), :recurrence],
        &%{&1 | rule: "FREQ=HOURLY"}
      )

    {report, _board, card} = import_as_receiver(ctx, document)
    assert Repo.all(from(s in Series, where: s.card_id == ^card.id)) == []
    assert Enum.any?(report.skipped, &(&1 =~ "“Review invoices” was imported without repeating"))
  end
end
