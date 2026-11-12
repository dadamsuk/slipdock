defmodule Slipdock.WorkWaitingVerifyTest do
  @moduledoc """
  Waiting on you leaves out a verification a runner is about to do (#2125):
  a card pending verification is not on its owner while a verify job for it
  is queued or running, or a runner of its board's verify pool is online,
  until `Work.verify_grace_seconds/0` passes with no verify job started.
  With no verifier, it shows at once. The epic's glance line reads the same
  items (`Work.Tree`).
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners, Work}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Runners.{Job, Runner}
  alias Slipdock.Work.Tree

  setup do
    owner = user_fixture("verify-owner@example.com")
    board = board_fixture(%{"name" => "Verified"}, owner: owner)
    [_backlog, todo, _doing, _done] = board.columns

    epic = card_fixture(todo, %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)

    from(b in Board, where: b.id in ^[board.id, sub.id])
    |> Repo.update_all(set: [verify_work: true, verify_pool: "checkers"])

    card = card_fixture(todo, %{"title" => "Built"})
    sub_card = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Sub built"})

    %{owner: owner, board: board, card: card, epic: epic, sub_card: sub_card}
  end

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  defp pending(card, seconds_ago \\ 60) do
    from(c in Card, where: c.id == ^card.id)
    |> Repo.update_all(set: [verify_state: "pending", verify_at: ago(seconds_ago)])
  end

  defp runner(board, pool, seen) do
    {:ok, runner, _token} = Runners.create_runner(board, %{name: "checker", pool: pool})

    from(r in Runner, where: r.id == ^runner.id)
    |> Repo.update_all(set: [last_seen_at: seen])
  end

  defp verify_job(card, status) do
    {:ok, job} = Runners.queue(card, %{pool: "checkers", kind: "verify", prompt: "verify"})

    from(j in Job, where: j.id == ^job.id) |> Repo.update_all(set: [status: status])
  end

  defp verify_ids(user) do
    for %{reason: "verify", card: c} <- Work.waiting_on_me(user), do: c.id
  end

  describe "no verifier" do
    test "shows at once", ctx do
      pending(ctx.card, 5)
      assert verify_ids(ctx.owner) == [ctx.card.id]
    end

    test "a runner in another pool, or one long unseen, is no verifier", ctx do
      runner(ctx.board, "dev", ago(0))
      runner(ctx.board, "checkers", ago(86_400))
      pending(ctx.card)
      assert verify_ids(ctx.owner) == [ctx.card.id]
    end

    test "a verify job that ended is no verifier", ctx do
      verify_job(ctx.card, "failed")
      pending(ctx.card)
      assert verify_ids(ctx.owner) == [ctx.card.id]
    end
  end

  describe "a verifier on it" do
    test "a verify runner online keeps it off, and the epic's glance too", ctx do
      runner(ctx.board, "checkers", ago(0))
      pending(ctx.card)
      pending(ctx.sub_card)

      assert verify_ids(ctx.owner) == []
      tree = Tree.for_board(ctx.owner, ctx.board)
      assert tree.count == 0
      assert Tree.glance(Tree.of(tree, ctx.epic.id)) == nil
    end

    test "a queued verify job keeps it off with no runner online", ctx do
      verify_job(ctx.card, "queued")
      pending(ctx.card)
      assert verify_ids(ctx.owner) == []
    end

    test "a claimed or running verify job keeps it off past the grace period", ctx do
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Other"})
      verify_job(ctx.card, "running")
      verify_job(other, "claimed")
      pending(ctx.card, Work.verify_grace_seconds() + 600)
      pending(other, Work.verify_grace_seconds() + 600)
      assert verify_ids(ctx.owner) == []
    end

    test "the person can still accept it by hand: it is still pending", ctx do
      runner(ctx.board, "checkers", ago(0))
      pending(ctx.card)
      assert Repo.get!(Card, ctx.card.id).verify_state == "pending"
    end
  end

  describe "the grace period" do
    test "past it with the runner online but no job started, it comes back", ctx do
      runner(ctx.board, "checkers", ago(0))
      pending(ctx.card, Work.verify_grace_seconds() + 1)
      pending(ctx.sub_card, Work.verify_grace_seconds() + 1)

      assert Enum.sort(verify_ids(ctx.owner)) == Enum.sort([ctx.card.id, ctx.sub_card.id])

      glance = ctx.owner |> Tree.for_board(ctx.board) |> Tree.of(ctx.epic.id) |> Tree.glance()
      assert glance == "Waiting on you: ##{ctx.sub_card.id} (to verify)"
    end

    test "past it with a job still only queued, it comes back", ctx do
      verify_job(ctx.card, "queued")
      pending(ctx.card, Work.verify_grace_seconds() + 1)
      assert verify_ids(ctx.owner) == [ctx.card.id]
    end

    test "it counts from the submission, since stays the submission", ctx do
      runner(ctx.board, "checkers", ago(0))
      pending(ctx.card, Work.verify_grace_seconds() - 60)
      assert verify_ids(ctx.owner) == []

      pending(ctx.card, Work.verify_grace_seconds() + 60)
      assert [%{since: since}] = Work.waiting_on_me(ctx.owner)
      assert DateTime.diff(DateTime.utc_now(), since) >= Work.verify_grace_seconds()
    end
  end
end
