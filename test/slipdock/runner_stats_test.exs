defmodule Slipdock.RunnerStatsTest do
  @moduledoc """
  How a board's runners are doing (#1187, `Slipdock.RunnerStats`), from
  hand-written job, wait, ledger and activity rows at fixed times.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners, RunnerStats}
  alias Slipdock.Boards.{Activity, CardMove, Wait}
  alias Slipdock.Runners.{Job, Runner}

  @now ~U[2026-10-19 15:00:00Z]
  @hour 3600
  @day 86_400

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Runners"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "dev-box", "pool" => "dev"})
    %{owner: owner, board: board, todo: todo, doing: doing, runner: runner}
  end

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  # A job on a fresh card, claimed `claimed` seconds ago and, unless still
  # open, finished `took` seconds later.
  defp job(ctx, status, claimed, took, attrs \\ %{}) do
    card = attrs[:card] || card_fixture(ctx.todo)
    claimed_at = ago(claimed)

    Repo.insert!(
      struct!(
        Job,
        Map.merge(
          %{
            pool: "dev",
            kind: "claude",
            prompt: "do it",
            status: status,
            board_id: card.board_id,
            root_board_id: ctx.board.id,
            card_id: card.id,
            runner_id: ctx.runner.id,
            inserted_at: ago(claimed + 60),
            claimed_at: claimed_at,
            finished_at: took && DateTime.add(claimed_at, took, :second)
          },
          Map.drop(attrs, [:card])
        )
      )
    )
  end

  defp seen(ctx, at, current \\ nil) do
    Repo.update_all(from(r in Runner, where: r.id == ^ctx.runner.id),
      set: [last_seen_at: at, current_job_id: current]
    )
  end

  defp stats(board, opts \\ []),
    do: RunnerStats.for_board(board, Keyword.merge([now: @now], opts))

  defp the_runner(stats), do: hd(stats.runners)

  test "a board with no runners is empty, not an error" do
    board = board_fixture(%{"name" => "Quiet"})
    assert %{runners: [], recent_jobs: [], days: 30} = stats(board)
  end

  test "days are held to the windows", ctx do
    assert stats(ctx.board, days: 3).days == 7
    assert stats(ctx.board, days: "60").days == 90
  end

  test "each outcome is counted, cancelled apart, and the rate is over ended jobs", ctx do
    job(ctx, "done", 5 * @hour, 600)
    job(ctx, "done", 4 * @hour, 1200)
    job(ctx, "parked", 3 * @hour, 300)
    job(ctx, "failed", 2 * @hour, 30, %{exit_code: 2})
    job(ctx, "timeout", 2 * @hour, 30)
    job(ctx, "cancelled", 2 * @hour, 30)
    job(ctx, "done", 40 * @day, 60)

    r = the_runner(stats(ctx.board))
    assert r.outcomes == %{done: 2, parked: 1, failed: 2, running: 0, cancelled: 1}
    assert r.success_rate == 0.4
    assert r.duration == %{p50: 900, p85: 1110}
    assert r.kind == "runner"
  end

  test "no ended jobs gives no rate", ctx do
    r = the_runner(stats(ctx.board))
    assert r.success_rate == nil
    assert r.outcomes == %{done: 0, parked: 0, failed: 0, running: 0, cancelled: 0}
    assert r.duration == %{p50: nil, p85: nil}
  end

  test "a job with no finish is running, with its card and elapsed time", ctx do
    card = card_fixture(ctx.doing, %{"title" => "Busy"})
    running = job(ctx, "running", 10 * 60, nil, %{card: card})
    seen(ctx, ago(5), running.id)

    s = stats(ctx.board)
    r = the_runner(s)
    assert r.status == "running"

    assert r.current == %{
             job_id: running.id,
             card_id: card.id,
             board_id: ctx.board.id,
             title: "Busy",
             elapsed: 600
           }

    assert r.outcomes.running == 1

    assert [%{job_id: id, outcome: "running", duration: 600, title: "Busy"}] = s.recent_jobs
    assert id == running.id
  end

  test "idle while seen within three leases, offline after", ctx do
    assert the_runner(stats(ctx.board)).status == "offline"
    seen(ctx, ago(60))
    assert the_runner(stats(ctx.board)).status == "idle"
    seen(ctx, ago(3 * @day))
    assert the_runner(stats(ctx.board)).status == "offline"
  end

  test "a parked job retried to done counts both, and the parked one says why", ctx do
    card = card_fixture(ctx.todo)
    parked = job(ctx, "parked", 5 * @hour, 120, %{card: card})

    Repo.insert!(%Wait{
      card_id: card.id,
      job_id: parked.id,
      needs: "Which colour?",
      inserted_at: ago(5 * @hour - 60),
      closed_at: ago(4 * @hour),
      close_reason: "answered"
    })

    job(ctx, "done", 3 * @hour, 600, %{card: card})

    s = stats(ctx.board)
    assert %{done: 1, parked: 1} = the_runner(s).outcomes
    assert [%{outcome: "done"}, %{outcome: "parked", reason: "Which colour?"}] = s.recent_jobs
  end

  test "queue wait runs from the card's last entry into the ready list", ctx do
    card = card_fixture(ctx.todo)
    Repo.delete_all(from m in CardMove, where: m.card_id == ^card.id)

    for {at, to} <- [{10 * @hour, ctx.todo}, {9 * @hour, ctx.doing}, {6 * @hour, ctx.todo}] do
      Repo.insert!(%CardMove{
        card_id: card.id,
        board_id: ctx.board.id,
        kind: "moved",
        to_column_id: to.id,
        to_category: to.category,
        inserted_at: ago(at) |> DateTime.add(0, :microsecond)
      })
    end

    job(ctx, "done", 5 * @hour, 60, %{card: card, inserted_at: ago(8 * @hour)})
    assert the_runner(stats(ctx.board)).queue_wait == %{p50: @hour, p85: @hour}
  end

  test "a job an answered wait sent again waits from being queued", ctx do
    card = card_fixture(ctx.todo)
    Repo.delete_all(from m in CardMove, where: m.card_id == ^card.id)
    first = job(ctx, "parked", 40 * @day, 60, %{card: card})
    again = job(ctx, "done", 2 * @hour, 60, %{card: card, inserted_at: ago(3 * @hour)})

    # Put back on the ready list after being sent again: not where its wait began.
    Repo.insert!(%CardMove{
      card_id: card.id,
      board_id: ctx.board.id,
      kind: "moved",
      to_column_id: ctx.todo.id,
      to_category: "todo",
      inserted_at: ago(div(5 * @hour, 2)) |> DateTime.add(0, :microsecond)
    })

    Repo.insert!(%Wait{
      card_id: card.id,
      job_id: first.id,
      requeue_job_id: again.id,
      needs: "OK?",
      inserted_at: ago(40 * @day),
      closed_at: ago(3 * @hour),
      close_reason: "answered"
    })

    assert the_runner(stats(ctx.board)).queue_wait == %{p50: @hour, p85: @hour}

    Repo.update_all(from(w in Wait, where: w.card_id == ^card.id), set: [requeue_job_id: nil])
    assert the_runner(stats(ctx.board)).queue_wait == %{p50: div(@hour, 2), p85: div(@hour, 2)}
  end

  test "waits opened from jobs in the window: count, open and time to answer", ctx do
    a = job(ctx, "parked", 6 * @hour, 60)
    b = job(ctx, "parked", 5 * @hour, 60)
    c = job(ctx, "parked", 40 * @day, 60)

    Repo.insert!(%Wait{
      card_id: a.card_id,
      job_id: a.id,
      needs: "One",
      inserted_at: ago(6 * @hour),
      closed_at: ago(4 * @hour),
      close_reason: "answered"
    })

    Repo.insert!(%Wait{
      card_id: b.card_id,
      job_id: b.id,
      needs: "Two",
      inserted_at: ago(5 * @hour)
    })

    Repo.insert!(%Wait{
      card_id: c.card_id,
      job_id: c.id,
      needs: "Old",
      inserted_at: ago(40 * @day)
    })

    r = the_runner(stats(ctx.board))
    assert r.waits == %{opened: 2, open: 1, answer: %{p50: 2 * @hour, p85: 2 * @hour}}
  end

  test "a reopen is counted once per reopen, for the runner that had the card", ctx do
    done = job(ctx, "done", 5 * @hour, 60)

    for at <- [4 * @hour, 2 * @hour, 40 * @day] do
      Repo.insert!(%Activity{
        board_id: ctx.board.id,
        card_id: done.card_id,
        kind: "card",
        message: "reopened “x”",
        inserted_at: ago(at)
      })
    end

    # A card no runner touched doesn't count.
    other = card_fixture(ctx.todo)

    Repo.insert!(%Activity{
      board_id: ctx.board.id,
      card_id: other.id,
      kind: "card",
      message: "reopened “y”",
      inserted_at: ago(@hour)
    })

    r = the_runner(stats(ctx.board))
    assert r.reopened == %{count: 2, card_ids: [done.card_id, done.card_id]}
  end

  test "recent jobs are the last 12, newest first, across runners", ctx do
    {:ok, other, _} = Runners.create_runner(ctx.board, %{"name" => "laptop", "pool" => "dev"})
    jobs = for n <- 1..14, do: job(ctx, "done", (20 - n) * @hour, 60)
    last = job(ctx, "failed", @hour, 60, %{runner_id: other.id, error: "boom"})

    s = stats(ctx.board)
    assert length(s.recent_jobs) == 12

    assert [%{job_id: id, runner: "laptop", outcome: "failed", reason: "boom"} | rest] =
             s.recent_jobs

    assert id == last.id

    assert Enum.map(rest, & &1.job_id) ==
             jobs |> Enum.reverse() |> Enum.take(11) |> Enum.map(& &1.id)

    laptop = Enum.find(s.runners, &(&1.name == "laptop"))
    assert [%{job_id: ^id}] = laptop.recent
  end

  test "a sub-board sees its tree's runners", ctx do
    epic = card_fixture(ctx.todo, %{"title" => "Epic"})
    {:ok, t} = Slipdock.Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    assert [%{name: "dev-box"}] = stats(sub).runners
  end
end
