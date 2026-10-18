defmodule Slipdock.SnoozePortableTest do
  @moduledoc "A snoozed card stays snoozed through a portable export and import (W-1803)."
  # Sync, as the other import tests: imports derive board codes.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Portable, Repo, Snooze}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Later", "code" => unique_code()}, owner: owner)
    [_backlog, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Chase the quote"})

    {:ok, card} =
      Snooze.snooze(card, owner, ~U[2030-03-01 00:00:00Z], note: "vendor", notify: true)

    %{owner: owner, board: board, card: card}
  end

  defp import_as(user, document) do
    {:ok, report} = Portable.import(user, Jason.encode!(document))
    board = Boards.get_board!(hd(report.boards).id)
    [card] = Boards.list_cards(board, %{"snoozed" => "include"})
    Repo.get!(Card, card.id)
  end

  test "the export carries the snooze", ctx do
    [tree] = Portable.export(ctx.owner, boards: [ctx.board]).boards
    [card] = tree.cards

    assert %{
             until: ~U[2030-03-01 00:00:00Z],
             note: "vendor",
             by: "owner@example.com",
             notify: true,
             wake_on_activity: true
           } = card.snooze
  end

  test "the import keeps it, by the importer when they were the snoozer", ctx do
    card = import_as(ctx.owner, Portable.export(ctx.owner, boards: [ctx.board]))
    assert card.snoozed_until == ~U[2030-03-01 00:00:00Z]
    assert card.snooze_note == "vendor"
    assert card.snooze_notify
    assert card.snoozed_by_id == ctx.owner.id
    assert card.snoozed_at
  end

  test "somebody else importing it keeps the snooze but not the snoozer", ctx do
    card =
      import_as(
        user_fixture("receiver@example.com"),
        Portable.export(ctx.owner, boards: [ctx.board])
      )

    assert Card.snoozed?(card)
    assert card.snoozed_by_id == nil
  end

  test "a snooze that has run out by now arrives awake", ctx do
    document =
      ctx.owner
      |> Portable.export(boards: [ctx.board])
      |> update_in(
        [:boards, Access.at(0), :cards, Access.at(0), :snooze],
        &%{&1 | until: ~U[2020-01-01 00:00:00Z]}
      )

    card = import_as(ctx.owner, document)
    assert card.snoozed_until == nil
  end

  test "a card that isn't snoozed exports none", ctx do
    {:ok, _} = Snooze.wake(Repo.get!(Card, ctx.card.id))
    [tree] = Portable.export(ctx.owner, boards: [ctx.board]).boards
    assert hd(tree.cards).snooze == nil
  end
end
