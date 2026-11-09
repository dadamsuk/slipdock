defmodule Slipdock.WorkWaitingMergeTest do
  @moduledoc """
  Waiting on you leaves out a failed merge a rebase fixes while a runner is
  reworking the card (#2568): a build job claimed or running on the card or
  on a card above it. Without one it shows as `failed`, and so does a merge
  a rebase won't fix, or a build job that failed or timed out. The count
  and the epic's board line read the same items (`Work.Tree`).
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners, Work}
  alias Slipdock.Runners.Job
  alias Slipdock.Work.Tree

  # The runner's words on #2349's merge job #1281.
  @conflict "merge: gh pr merge refused: Pull Request is not mergeable: " <>
              "the Pull Request has merge conflicts"
  @closed "merge: gh pr merge refused: Pull Request is closed"

  setup do
    owner = user_fixture("merge-owner@example.com")
    board = board_fixture(%{"name" => "Merging"}, owner: owner)
    [_backlog, todo, _doing, _done] = board.columns

    epic = card_fixture(todo, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub_card = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Sub"})

    %{owner: owner, board: board, todo: todo, epic: epic, sub_card: sub_card}
  end

  defp job(card, kind, status, extra \\ []) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: kind, prompt: "go"})

    from(j in Job, where: j.id == ^job.id)
    |> Repo.update_all(
      set: Keyword.merge([status: status, finished_at: DateTime.utc_now()], extra)
    )

    Repo.get!(Job, job.id)
  end

  defp merge_failed(card, said), do: job(card, "merge", "failed", output: "checking out\n#{said}")

  defp failed_ids(user) do
    for %{reason: "failed", card: c} <- Work.waiting_on_me(user), do: c.id
  end

  describe "a merge a rebase fixes" do
    test "#2349: with the epic's build job running, it isn't on the list, the count or the board line",
         ctx do
      job(ctx.epic, "claude", "running")
      merge_failed(ctx.sub_card, @conflict)

      assert failed_ids(ctx.owner) == []
      assert Work.waiting_count(ctx.owner) == 0
      assert {0, _} = Work.waiting_summary(ctx.owner)

      tree = Tree.for_board(ctx.owner, ctx.board)
      assert tree.count == 0
      assert Tree.glance(Tree.of(tree, ctx.epic.id)) == nil
    end

    test "a build job claimed on the card itself keeps it off too", ctx do
      card = card_fixture(ctx.todo)
      merge_failed(card, @conflict)
      job(card, "claude", "claimed", finished_at: nil)
      # The build job is newer, so the card's newest job is no longer the merge.
      assert failed_ids(ctx.owner) == []

      other = card_fixture(ctx.todo)
      job(other, "claude", "claimed")
      merge_failed(other, @conflict)
      assert failed_ids(ctx.owner) == []
    end

    test "with no open build job on it or above it, it shows as failed", ctx do
      merge = merge_failed(ctx.sub_card, @conflict)

      assert [%{reason: "failed", text: text}] = Work.waiting_on_me(ctx.owner)
      assert text == "Job ##{merge.id} failed"
      assert Work.waiting_count(ctx.owner) == 1

      glance = ctx.owner |> Tree.for_board(ctx.board) |> Tree.of(ctx.epic.id) |> Tree.glance()
      assert glance == "Waiting on you: ##{ctx.sub_card.id} (a failed job)"
    end

    test "a build job only queued, ended, or on another card doesn't keep it off", ctx do
      other = card_fixture(ctx.todo)
      job(other, "claude", "running")
      job(ctx.epic, "claude", "done")
      job(ctx.epic, "claude", "queued")
      merge_failed(ctx.sub_card, @conflict)

      assert failed_ids(ctx.owner) == [ctx.sub_card.id]
    end

    test "a verify, merge or overseer job running above it is no build job", ctx do
      job(ctx.epic, "verify", "running")
      job(ctx.epic, "merge", "running")
      job(ctx.epic, Slipdock.Overseer.kind(), "running")
      merge_failed(ctx.sub_card, @conflict)

      assert failed_ids(ctx.owner) == [ctx.sub_card.id]
    end
  end

  describe "anything else still shows while a build job runs" do
    test "a merge a rebase won't fix (a closed pull request)", ctx do
      job(ctx.epic, "claude", "running")
      merge_failed(ctx.sub_card, @closed)

      assert failed_ids(ctx.owner) == [ctx.sub_card.id]
    end

    test "a merge job with no words, or one that timed out", ctx do
      job(ctx.epic, "claude", "running")
      job(ctx.sub_card, "merge", "failed")
      other = card_fixture(hd(Boards.get_board!(ctx.sub_card.board_id).columns))
      job(other, "merge", "timeout", output: @conflict)

      assert Enum.sort(failed_ids(ctx.owner)) == Enum.sort([ctx.sub_card.id, other.id])
    end

    test "a failed or timed-out build job", ctx do
      job(ctx.epic, "claude", "running")
      job(ctx.sub_card, "claude", "failed", output: @conflict)
      other = card_fixture(hd(Boards.get_board!(ctx.sub_card.board_id).columns))
      timed_out = job(other, "claude", "timeout")

      assert Enum.sort(failed_ids(ctx.owner)) == Enum.sort([ctx.sub_card.id, other.id])

      assert Enum.find(Work.waiting_on_me(ctx.owner), &(&1.card.id == other.id)).text ==
               "Job ##{timed_out.id} timed out"
    end
  end
end
