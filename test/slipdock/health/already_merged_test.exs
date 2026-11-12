defmodule Slipdock.Health.AlreadyMergedTest do
  @moduledoc """
  A pull request merged outside the runner (#2759, from #2705's three
  failed merge jobs): a merge job that finds it merged at the accepted
  commit completes the card whoever merged it; one that finds it merged at
  a head it can't match stops after that one failure, flagged once for a
  person, and the health monitor neither queues the merge again
  (`merge_missing`) nor counts it as a failing merge (`merge_failing`).
  Driven through the real flow: acceptance, the runner's claim and finish,
  then the health monitor.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Health, Repo, Runners, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Health.{Context, Incident, Settings}
  alias Slipdock.Health.Detectors.{MergeFailing, MergeMissing}
  alias Slipdock.Runners.Job

  @pr "https://github.com/acme/app/pull/7"
  @sha "abc1234def5678abc1234def5678abc1234def56"

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Merged", "code" => unique_code()}, owner: user)

    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

    [_backlog, _todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: user.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: user.id, agent: "checker"}

    {:ok, _} =
      Boards.Cards.update_card(
        card,
        %{"completed" => true, "evidence_pr" => @pr, "evidence_commit" => "abc1234"},
        actor: builder
      )

    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "m-dev", "pool" => "dev"})
    runner = Runners.report_kinds(runner, "claude,merge")
    {:ok, _} = Verified.decide(Repo.get!(Card, card.id), "accept", %{}, checker, user)
    %{id: job_id} = Runners.claim(runner)

    %{board: board, card: card, done: done, runner: runner, job_id: job_id}
  end

  defp later(minutes), do: DateTime.add(DateTime.utc_now(), minutes * 60)

  defp merge_jobs(card),
    do: Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == "merge"))

  defp incidents(board),
    do: Repo.all(from(i in Incident, where: i.board_id == ^board.id, order_by: i.id))

  defp detect(detector, board, minutes),
    do: detector.detect(Context.new(board, later(minutes)), Settings.for(%{}, detector))

  defp finish(ctx, said),
    do: {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "2", output: "x\n#{said}\n"})

  test "merged by a person at the accepted commit: the one merge job completes the card", ctx do
    said = "merge: #{@pr} was already merged at the accepted commit (head abc1234ff) as #{@sha}"
    {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "0", merged: @sha, output: said})

    card = Repo.get!(Card, ctx.card.id)
    assert card.completed
    assert card.merge_sha == @sha
    assert card.column_id == ctx.done.id

    assert detect(MergeMissing, ctx.board, 30) == []
    assert detect(MergeFailing, ctx.board, 30) == []
    assert [_one] = merge_jobs(card)
  end

  for said <- [
        "merge: #{@pr} was already merged at head 999fff, not the accepted commit abc1234; " <>
          "nothing merged",
        "merge: #{@pr} is MERGED, not open; nothing merged"
      ] do
    test "#{String.slice(said, 0, 60)}…: flagged once after one failure, never queued again",
         ctx do
      finish(ctx, unquote(said))
      card = Repo.get!(Card, ctx.card.id)
      assert card.verify_state == "merging"

      # Not counted as a failing merge, even next to another like it.
      assert detect(MergeFailing, ctx.board, 30) == []

      assert [f] = detect(MergeMissing, ctx.board, 30)
      assert f.data == %{"card" => card.id, "already_merged" => true}
      assert f.summary =~ "found the pull request already merged, not at a head it could match"

      # The monitor flags it at once, without queuing another merge job.
      assert {:ok, %{"flagged" => 1, "fixed" => 0, "tried" => 0}} =
               Health.run(ctx.board, detectors: [MergeMissing, MergeFailing], now: later(30))

      assert [%Job{status: "failed"}] = merge_jobs(card)
      assert "stuck" in Repo.get!(Card, card.id).flags

      assert [%Incident{detector: "merge_missing", status: "flagged"} = incident] =
               incidents(ctx.board)

      assert List.last(incident.log)["what"] =~
               "Not queued again: the pull request is already merged"

      assert List.last(incident.log)["what"] =~ "slipdock verify #{card.id} merged"

      # Later runs leave it as it is: still one job, still one incident.
      assert {:ok, %{"flagged" => 0, "fixed" => 0, "tried" => 0, "opened" => 0}} =
               Health.run(ctx.board, detectors: [MergeMissing, MergeFailing], now: later(60))

      assert [_one] = merge_jobs(card)
      assert [%Incident{status: "flagged"}] = incidents(ctx.board)
    end
  end

  test "an already-merged job from before this acceptance doesn't stop the merge", ctx do
    finish(ctx, "merge: #{@pr} is MERGED, not open; nothing merged")

    # Accepted again since (a person sent it back and it was accepted anew).
    Repo.update_all(from(c in Card, where: c.id == ^ctx.card.id),
      set: [verify_at: DateTime.truncate(later(1), :second)]
    )

    assert [f] = detect(MergeMissing, ctx.board, 30)
    assert f.data["already_merged"] == false
    refute f.summary =~ "already merged"

    assert {:ok, %{"fixed" => 1}} =
             Health.run(ctx.board, detectors: [MergeMissing], now: later(30))

    assert [_failed, %Job{status: "queued"}] = Enum.sort_by(merge_jobs(ctx.card), & &1.id)
  end

  test "the same words outside the runner's merge: line are a failure, counted", ctx do
    {:ok, _} =
      Runners.finish(ctx.runner, ctx.job_id, %{
        exit: "1",
        output: "gh: #{@pr} is MERGED, not open"
      })

    refute Verified.already_merged?(Repo.get!(Job, ctx.job_id))
  end

  describe "Verified.already_merged?/1" do
    test "only a failed job whose merge: line says so" do
      yes = "merge: x was already merged at head 9f, not the accepted commit 1a; nothing merged"
      assert Verified.already_merged?(%Job{status: "failed", output: "x\n" <> yes})

      assert Verified.already_merged?(%Job{
               status: "failed",
               log_tail: "merge: x is MERGED, not open"
             })

      refute Verified.already_merged?(%Job{status: "done", output: yes})

      refute Verified.already_merged?(%Job{
               status: "failed",
               output: "merge: conflict in mix.lock"
             })

      refute Verified.already_merged?(%Job{status: "failed", output: "x is MERGED, not open"})
      refute Verified.already_merged?(%Job{status: "failed"})
      refute Verified.already_merged?(nil)
    end
  end
end
