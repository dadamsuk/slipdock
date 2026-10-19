defmodule Slipdock.CardTimelineTest do
  @moduledoc """
  A card's timeline (#1131, `Slipdock.CardTimeline`): the lists it sat in,
  its waits and its runner jobs as spans of time, read from the movement
  ledger, the waits and the jobs.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, CardTimeline, Repo, Runners}
  alias Slipdock.Boards.{Card, CardMove}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture() |> Ecto.Changeset.change(name: "David") |> Repo.update!()
    board = board_fixture(%{"name" => "Timeline"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  @t0 ~U[2026-10-01 09:00:00Z]

  defp at(minutes), do: DateTime.add(@t0, minutes * 60)

  # Puts the card's ledger rows at these minutes past @t0, in order.
  defp place(card, minutes) do
    rows =
      Repo.all(
        from(m in CardMove,
          where: m.card_id == ^card.id,
          order_by: [asc: m.inserted_at, asc: m.id]
        )
      )

    assert length(rows) == length(minutes)

    for {row, m} <- Enum.zip(rows, minutes) do
      Repo.update_all(from(r in CardMove, where: r.id == ^row.id), set: [inserted_at: at(m)])
    end

    Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [inserted_at: at(hd(minutes))])
    Boards.get_card!(card.id)
  end

  defp lists(timeline), do: Enum.map(timeline.stays, &{&1.list, &1.category})

  describe "stays" do
    test "each list it sat in, from the move in to the next, the last open to now", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Ship it"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      :ok = Boards.move_card(card.id, ctx.done.id, nil, actor: Actor.web(ctx.owner))
      card = place(card, [0, 30, 90])

      tl = CardTimeline.for_card(card, now: at(120))

      assert lists(tl) == [{"To Do", "todo"}, {"In Progress", "doing"}, {"Done", "done"}]
      assert Enum.map(tl.stays, &CardTimeline.seconds/1) == [30 * 60, 60 * 60, 30 * 60]
      assert Enum.map(tl.stays, & &1.open) == [false, false, true]
      refute Enum.any?(tl.stays, & &1.unsure)
      assert {tl.from, tl.to} == {at(0), at(120)}

      [created, moved | _] = tl.stays
      assert created.how.kind == "created"
      assert %{kind: "moved", actor_kind: "human", via: "web", by: "David"} = moved.how
    end

    test "an agent's move is credited to its label", ctx do
      card = card_fixture(ctx.todo)
      actor = %{Actor.unknown() | kind: "agent", via: "mcp", agent: "laptop"}
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: actor)

      assert [_, %{how: %{actor_kind: "agent", by: "laptop"}}] =
               CardTimeline.for_card(card).stays
    end

    test "time archived is a stay of its own, ended by the restore", ctx do
      card = card_fixture(ctx.todo)
      {:ok, card} = Boards.archive_card(card)
      {:ok, card} = Boards.unarchive_card(card)
      card = place(card, [0, 10, 40])

      tl = CardTimeline.for_card(card, now: at(50))

      assert lists(tl) == [{"To Do", "todo"}, {"Archived", "archived"}, {"To Do", "todo"}]
      assert Enum.map(tl.stays, &CardTimeline.seconds/1) == [600, 1800, 600]
      refute Enum.any?(tl.stays, & &1.unsure)
    end

    test "a move from a list the ledger never put it in leaves the stay before unsure", ctx do
      card = card_fixture(ctx.todo)
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      card = place(card, [0, 20])

      # As the backfill leaves it: a move after one it couldn't read.
      Repo.update_all(
        from(m in CardMove, where: m.card_id == ^card.id and m.kind == "moved"),
        set: [
          from_column_name: nil,
          from_category: nil,
          backfilled: true,
          actor_kind: nil,
          via: nil,
          user_id: nil
        ]
      )

      tl = CardTimeline.for_card(card, now: at(30))

      assert [%{list: "To Do", unsure: true}, %{list: "In Progress", unsure: false}] = tl.stays
      assert [_, %{how: %{backfilled: true, by: nil}}] = tl.stays
    end

    test "time before a first row that isn't the card's creation is an unsure lead-in", ctx do
      card = card_fixture(ctx.todo)
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      card = place(card, [0, 20])
      Repo.delete_all(from(m in CardMove, where: m.card_id == ^card.id and m.kind == "created"))
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [inserted_at: at(-60)])
      card = Boards.get_card!(card.id)

      tl = CardTimeline.for_card(card, now: at(30))

      assert [lead, doing] = tl.stays
      assert %{list: "To Do", category: "todo", unsure: true, how: nil} = lead
      assert {lead.from, lead.to} == {at(-60), at(20)}
      assert %{list: "In Progress", open: true} = doing
      assert tl.from == at(-60)
    end

    test "a card with no ledger rows has an empty timeline from its creation", ctx do
      card = card_fixture(ctx.todo)
      Repo.delete_all(from(m in CardMove, where: m.card_id == ^card.id))

      tl = CardTimeline.for_card(card)

      assert CardTimeline.empty?(tl)
      assert tl.from == DateTime.truncate(card.inserted_at, :second)
    end

    test "a renamed list keeps the name it had then", ctx do
      card = card_fixture(ctx.todo)
      {:ok, _} = Boards.update_column(ctx.todo, %{"name" => "Ready"})

      assert [%{list: "To Do"}] = CardTimeline.for_card(card).stays
    end
  end

  describe "waits and jobs" do
    test "a wait runs from opened to answered; an open one runs to now", ctx do
      card = card_fixture(ctx.doing)
      {:ok, _} = Boards.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Which colour?"})
      {:ok, _} = Boards.answer_wait(card, Actor.web(ctx.owner), %{"answer" => "Blue"})
      {:ok, _} = Boards.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Ship it?"})

      now = DateTime.add(DateTime.utc_now(), 3600)
      tl = CardTimeline.for_card(Boards.get_card!(card.id), now: DateTime.add(now, 0))

      assert [first, second] = tl.waits
      assert %{needs: "Which colour?", on: "anyone", open: false, reason: "answered"} = first
      assert %{needs: "Ship it?", open: true, reason: nil} = second
      assert second.to == DateTime.truncate(now, :second)
      refute CardTimeline.empty?(tl)
    end

    test "a job runs from queued to finished; an open one runs to now", ctx do
      card = card_fixture(ctx.doing)
      {:ok, done} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

      Repo.update_all(from(j in Job, where: j.id == ^done.id),
        set: [status: "done", inserted_at: at(0), finished_at: at(15)]
      )

      {:ok, open} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "again"})
      Repo.update_all(from(j in Job, where: j.id == ^open.id), set: [inserted_at: at(20)])

      tl = CardTimeline.for_card(card, now: at(60))

      assert [first, second] = tl.jobs
      assert %{id: id, status: "done", pool: "dev", open: false} = first
      assert id == done.id
      assert CardTimeline.seconds(first) == 15 * 60
      assert %{status: "queued", open: true} = second
      assert second.to == at(60)
      assert tl.from == at(0)
    end

    test "a finished job with no finish time ends when it was last touched", ctx do
      card = card_fixture(ctx.doing)
      {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

      Repo.update_all(from(j in Job, where: j.id == ^job.id),
        set: [status: "cancelled", inserted_at: at(0), updated_at: at(5), finished_at: nil]
      )

      assert [%{to: to, open: false}] = CardTimeline.for_card(card, now: at(60)).jobs
      assert to == at(5)
    end
  end
end
