defmodule Slipdock.Runners.IdleTest do
  @moduledoc """
  Whether a runner is idle (#1965): `Runners.idle?/1`, which sends a merge to
  an idle runner first, and `Health.Runs.idle?/2`, which the idle_feed
  detector reads. Both decide busy from the runner's open jobs (claimed or
  running), not its `current_job_id`: one token can be claimed through by
  several processes or a session, so that is only its last claim.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Health.Runs
  alias Slipdock.Runners.{Job, Runner}

  setup do
    board = board_fixture(%{"name" => "Idle"})
    [_backlog, todo, _doing, _done] = board.columns
    {:ok, runner, _token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [last_seen_at: now()])
    %{todo: todo, runner: Repo.get!(Runner, runner.id)}
  end

  defp now, do: DateTime.utc_now(:second)

  # Queues a job on a fresh card and claims it through `runner`'s token.
  defp claim(ctx, title) do
    card = card_fixture(ctx.todo, %{"title" => title})
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    assert %Job{id: id} = Runners.claim(ctx.runner)
    assert id == job.id
    job
  end

  defp fresh(runner), do: Repo.get!(Runner, runner.id)

  defp idle_both?(runner) do
    runner = fresh(runner)
    both = {Runners.idle?(runner), Runs.idle?(runner, now())}
    assert elem(both, 0) == elem(both, 1)
    elem(both, 0)
  end

  test "a runner seen lately with no jobs is idle; one never seen or long gone isn't", ctx do
    assert idle_both?(ctx.runner)
    refute Runners.busy?(ctx.runner)

    Repo.update_all(from(r in Runner, where: r.id == ^ctx.runner.id), set: [last_seen_at: nil])
    refute idle_both?(ctx.runner)

    long_ago = DateTime.add(now(), -3 * 3600)

    Repo.update_all(from(r in Runner, where: r.id == ^ctx.runner.id),
      set: [last_seen_at: long_ago]
    )

    refute idle_both?(ctx.runner)
  end

  test "a token with two open claims is busy until both have ended", ctx do
    first = claim(ctx, "First")
    second = claim(ctx, "Second")
    assert fresh(ctx.runner).current_job_id == second.id

    assert Runners.busy?(ctx.runner)
    refute idle_both?(ctx.runner)

    {:ok, %Job{status: "done"}} = Runners.finish(ctx.runner, first.id, %{exit: 0})
    refute idle_both?(ctx.runner)

    {:ok, %Job{status: "done"}} = Runners.finish(ctx.runner, second.id, %{exit: 0})
    refute Runners.busy?(ctx.runner)
    assert idle_both?(ctx.runner)
  end

  test "a token whose last claim has ended is busy while another is still running", ctx do
    first = claim(ctx, "Long run")
    {:ok, _} = Runners.heartbeat(ctx.runner, first.id)
    assert %Job{status: "running"} = Repo.get!(Job, first.id)

    last = claim(ctx, "Quick one")
    {:ok, _} = Runners.finish(ctx.runner, last.id, %{exit: 0})

    # The last claim ending clears current_job_id, though the first runs on.
    assert fresh(ctx.runner).current_job_id == nil
    assert Runners.busy?(ctx.runner)
    refute idle_both?(ctx.runner)

    {:ok, _} = Runners.finish(ctx.runner, first.id, %{exit: 1})
    assert idle_both?(ctx.runner)
  end

  test "a job of another runner's doesn't make this one busy", ctx do
    board = Repo.get!(Slipdock.Boards.Board, ctx.todo.board_id)
    {:ok, other, _} = Runners.create_runner(board, %{"name" => "other", "pool" => "dev"})
    card = card_fixture(ctx.todo, %{"title" => "Theirs"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    assert %Job{} = Runners.claim(other)

    assert Runners.busy?(other)
    refute Runners.busy?(ctx.runner)
    assert idle_both?(ctx.runner)
  end

  test "a stale current_job_id with no open job doesn't make a runner busy", ctx do
    job = claim(ctx, "Ended elsewhere")

    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [status: "timeout"])
    assert fresh(ctx.runner).current_job_id == job.id
    assert idle_both?(ctx.runner)
  end
end
