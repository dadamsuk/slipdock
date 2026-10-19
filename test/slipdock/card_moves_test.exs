defmodule Slipdock.CardMovesTest do
  @moduledoc """
  The movement ledger (#1112, `Slipdock.Boards.CardMove`): a row for every
  change of a card's list, and for its creation, archive and restore, in
  order and with who made it; never for a stand-in. And
  `Boards.list_entered_at/1`, read from it.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Portable, Repo}
  alias Slipdock.Boards.{Card, CardMove, Column}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Ledger"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp rows(card_id) do
    Repo.all(
      from(m in CardMove, where: m.card_id == ^card_id, order_by: [asc: m.inserted_at, asc: m.id])
    )
  end

  defp moves(card_id), do: card_id |> rows() |> Enum.filter(&(&1.kind == "moved"))

  describe "moves" do
    test "To Do → In Progress is one row with both lists and the actor", ctx do
      card = card_fixture(ctx.todo)
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))

      assert [row] = moves(card.id)
      assert {row.from_column_id, row.to_column_id} == {ctx.todo.id, ctx.doing.id}
      assert {row.from_column_name, row.to_column_name} == {"To Do", "In Progress"}
      assert {row.from_category, row.to_category} == {"todo", "doing"}
      assert {row.board_id, row.from_board_id} == {ctx.board.id, ctx.board.id}
      assert {row.actor_kind, row.via, row.user_id} == {"human", "web", ctx.owner.id}
      refute row.backfilled
    end

    test "an agent's label and job are kept, and a job id that names no job is dropped", ctx do
      card = card_fixture(ctx.todo)
      actor = %{Actor.unknown() | kind: "agent", via: "cli", agent: "laptop", job_id: 999_999_999}
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: actor)

      assert [%{actor_kind: "agent", via: "cli", agent: "laptop", job_id: nil}] = moves(card.id)
    end

    test "a reorder within the list writes nothing", ctx do
      card = card_fixture(ctx.todo)
      _other = card_fixture(ctx.todo)
      :ok = Boards.move_card_to_index(card, ctx.todo, :bottom, actor: Actor.web(ctx.owner))

      assert moves(card.id) == []
    end

    test "a rule the move sets off, moving the card on, writes the second row after", ctx do
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "card_moved", "to" => ctx.doing.name},
        "actions" => [%{"type" => "move_card", "column" => ctx.done.name}]
      })

      card = card_fixture(ctx.todo)
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))

      assert [first, second] = moves(card.id)
      assert {first.from_column_name, first.to_column_name} == {"To Do", "In Progress"}
      assert first.actor_kind == "human"
      assert {second.from_column_name, second.to_column_name} == {"In Progress", "Done"}
      assert second.actor_kind == "automation"
      assert first.id < second.id
    end

    test "to another board: one row carrying both boards, none for the subcards", ctx do
      other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
      [_, inbox | _] = other.columns
      card = card_fixture(ctx.todo)
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card, t)
      sub = Boards.get_board!(sub.id)
      child = card_fixture(hd(sub.columns))

      {:ok, _} = Boards.move_card_to_board(card, inbox, actor: Actor.assistant(ctx.owner))

      assert [row] = moves(card.id)
      assert {row.from_board_id, row.from_column_id} == {ctx.board.id, ctx.todo.id}
      assert {row.board_id, row.to_column_id} == {other.id, inbox.id}
      assert {row.actor_kind, row.via} == {"agent", "assistant"}
      assert moves(child.id) == []
    end

    test "a stand-in taken to done by its card's move gets no row", ctx do
      other = board_fixture(%{"name" => "Sprint"}, owner: ctx.owner)
      [_, sprint_todo, _, sprint_done] = other.columns
      card = card_fixture(ctx.todo)
      {:ok, stand_in} = Boards.leave_stand_in(card)
      {:ok, _} = Boards.move_card_to_board(card, sprint_todo, actor: Actor.web(ctx.owner))
      :ok = Boards.move_card(card.id, sprint_done.id, nil, actor: Actor.web(ctx.owner))

      assert Repo.get!(Card, stand_in.id).column_id == ctx.done.id
      assert rows(stand_in.id) == []
      assert length(moves(card.id)) == 2
    end

    test "a stand-in moved by hand gets no row either", ctx do
      card = card_fixture(ctx.todo)
      {:ok, stand_in} = Boards.leave_stand_in(card)
      :ok = Boards.move_card(stand_in.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))

      assert rows(stand_in.id) == []
    end
  end

  describe "creation" do
    test "create_card writes a created row in its list, by whoever made it", ctx do
      {:ok, card} = Boards.create_card(ctx.doing, %{"title" => "New"}, by: ctx.owner)

      assert [row] = rows(card.id)
      assert {row.kind, row.from_column_id, row.to_column_id} == {"created", nil, ctx.doing.id}
      assert {row.to_column_name, row.to_category} == {"In Progress", "doing"}
      assert row.user_id == ctx.owner.id
    end

    test "a copy writes its own created row, in the list it went to", ctx do
      card = card_fixture(ctx.todo)
      {:ok, copy} = Boards.copy_card(card, ctx.done, by: ctx.owner)

      assert [%{kind: "created", to_column_id: done_id}] = rows(copy.id)
      assert done_id == ctx.done.id
    end

    test "an imported card writes a created row in its list", ctx do
      document =
        Jason.encode!(%{
          slipdock_portable: 1,
          boards: [
            %{
              root: %{
                ref: "r",
                name: "Imported",
                code: unique_code(),
                lists: [%{ref: "l1", name: "Inbox", category: "todo"}]
              },
              boards: [],
              cards: [%{ref: "c1", board: "r", title: "Came in", list: "l1"}]
            }
          ]
        })

      {:ok, report} = Portable.import(ctx.owner, document)
      board = Boards.get_board!(hd(report.boards).id)
      [card] = Repo.all(from(c in Card, where: c.board_id == ^board.id))

      assert [row] = rows(card.id)
      assert {row.kind, row.to_column_name, row.to_category} == {"created", "Inbox", "todo"}
      assert row.user_id == ctx.owner.id
      assert row.actor_kind == nil
    end
  end

  describe "archive and restore" do
    test "write archived then restored, and the restore is when it entered its list", ctx do
      card = card_fixture(ctx.doing)
      {:ok, archived} = Boards.archive_card(card)
      # Archiving again changes nothing it records.
      {:ok, archived} = Boards.archive_card(archived)
      {:ok, _} = Boards.unarchive_card(archived)

      assert [created, put_away, back] = rows(card.id)
      assert created.kind == "created"

      assert {put_away.kind, put_away.from_column_id, put_away.to_column_id} ==
               {"archived", ctx.doing.id, nil}

      assert {back.kind, back.from_column_id, back.to_column_id} ==
               {"restored", nil, ctx.doing.id}

      assert Boards.list_entered_at(ctx.board)[card.id] == back.inserted_at
    end

    test "restoring a card that isn't archived writes nothing", ctx do
      card = card_fixture(ctx.doing)
      {:ok, _} = Boards.unarchive_card(card)

      assert Enum.map(rows(card.id), & &1.kind) == ["created"]
    end
  end

  describe "list_entered_at/1" do
    test "is each open card's latest entry into the list it is in", ctx do
      stays = card_fixture(ctx.todo)
      moved = card_fixture(ctx.todo)
      :ok = Boards.move_card(moved.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      shelved = card_fixture(ctx.todo)
      {:ok, _} = Boards.archive_card(shelved)

      entered = Boards.list_entered_at(ctx.board.id)

      assert entered[stays.id] == hd(rows(stays.id)).inserted_at
      assert entered[moved.id] == List.last(rows(moved.id)).inserted_at
      refute Map.has_key?(entered, shelved.id)
    end

    test "leaves out a card whose latest entry isn't into its current list", ctx do
      card = card_fixture(ctx.todo)
      # A move the ledger never saw: the list changed behind its back.
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [column_id: ctx.done.id])

      refute Map.has_key?(Boards.list_entered_at(ctx.board), card.id)
    end

    test "is empty for a board with no cards", ctx do
      empty = board_fixture(%{"name" => "Empty"}, owner: ctx.owner)
      assert Boards.list_entered_at(empty) == %{}
    end
  end

  describe "lists changing under the history" do
    test "renaming a list keeps the old rows' names", ctx do
      card = card_fixture(ctx.todo)
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      {:ok, _} = Boards.update_column(ctx.doing, %{"name" => "Doing"})

      assert [%{to_column_name: "In Progress", to_column_id: id}] = moves(card.id)
      assert id == ctx.doing.id
    end

    test "deleting a list nilifies its ids and keeps the rows", ctx do
      card = card_fixture(ctx.backlog)
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      {:ok, _} = Boards.delete_column(Repo.get!(Column, ctx.backlog.id))

      assert [created, moved] = rows(card.id)
      assert {created.to_column_id, created.to_column_name} == {nil, "Backlog"}
      assert {moved.from_column_id, moved.from_column_name} == {nil, "Backlog"}
      assert moved.to_column_id == ctx.doing.id
    end
  end
end
