defmodule Slipdock.RunnerStats do
  @moduledoc """
  How a board's runners are doing (#1187), for the Visualise page: read from
  the runner job log (`Slipdock.Runners.Job`), the waits asked from jobs
  (`Slipdock.Boards.Wait`), the movement ledger and the activity log. Worked
  out when asked for, like `Slipdock.Pulse`: nothing is stored.

  For each runner taking work from the board's tree, over the last `days`:

    * `status` — `running` while it holds an open job (with `current`: the
      job, its card and the seconds since it was claimed), `idle` while seen
      within three of its leases (the claim's own reading of online), else
      `offline`;
    * `outcomes` — the window's jobs by how they ended: `done`, `parked`,
      `failed` (failed or timed out) and `running`; `cancelled` is counted
      apart and in no rate;
    * `duration` — P50/P85 seconds claimed → finished, done jobs only;
    * `queue_wait` — P50/P85 seconds from the card coming into its board's
      ready list (or, for a job an answered wait queued, from being sent
      again) to the job being claimed;
    * `success_rate` — done / (done + parked + failed), nil with none;
    * `waits` — waits on people asked from its jobs in the window, how many
      are still open, and the P50 seconds to an answer;
    * `reopened` — its cards reopened in the window, once per reopen;
    * `recent` — its last 12 jobs.

  `recent_jobs` is the last 12 across all of them, for the page's table.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Activity, Board, CardMove, Column, Wait}
  alias Slipdock.{Flow, Repo, Runners}
  alias Slipdock.Runners.Job

  @recent 12

  @doc """
  The stats for `board`'s runners. Options: `:days` (held to 7, 30 or 90 by
  `Slipdock.Flow.clamp_days/1`) and `:now`, for tests.
  """
  def for_board(%Board{} = board, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    days = opts |> Keyword.get(:days) |> Flow.clamp_days()
    since = DateTime.add(now, -days * 86_400, :second)
    runners = Runners.list_runners(board)
    ids = Enum.map(runners, & &1.id)

    jobs =
      Repo.all(
        from j in Job,
          where:
            j.runner_id in ^ids and
              (j.claimed_at >= ^DateTime.truncate(since, :second) or
                 j.status in ^Job.open_statuses()),
          order_by: [desc: j.id],
          preload: :card
      )

    recent =
      Repo.all(
        from j in Job,
          where: j.runner_id in ^ids and not is_nil(j.claimed_at),
          order_by: [desc: j.id],
          limit: @recent,
          preload: :card
      )

    parked = parked_reasons(recent ++ jobs)
    waited = queue_starts(jobs)
    waits = waits(Enum.map(jobs, & &1.id), since)
    reopens = reopens(ids, since)

    %{
      days: days,
      since: DateTime.truncate(since, :second),
      runners:
        Enum.map(runners, fn r ->
          mine = Enum.filter(jobs, &(&1.runner_id == r.id))
          runner(r, mine, recent, parked, waited, waits, reopens, now)
        end),
      recent_jobs: Enum.map(recent, &job_line(&1, parked, now, runners)),
      at: DateTime.truncate(now, :second)
    }
  end

  defp runner(r, jobs, recent, parked, waited, waits, reopens, now) do
    outcomes = %{
      done: Enum.count(jobs, &(&1.status == "done")),
      parked: Enum.count(jobs, &(&1.status == "parked")),
      failed: Enum.count(jobs, &(&1.status in ["failed", "timeout"])),
      running: Enum.count(jobs, &(&1.status in ["claimed", "running"])),
      cancelled: Enum.count(jobs, &(&1.status == "cancelled"))
    }

    ended = outcomes.done + outcomes.parked + outcomes.failed
    current = Enum.find(jobs, &(&1.id == r.current_job_id and Job.open?(&1)))
    job_ids = MapSet.new(jobs, & &1.id)
    my_waits = Enum.filter(waits, &MapSet.member?(job_ids, &1.job_id))
    answered = for w <- my_waits, w.close_reason == "answered", do: w.seconds

    %{
      id: r.id,
      name: r.name,
      pool: r.pool,
      kind: if(Runners.Runner.session?(r), do: "session", else: "runner"),
      status: status(r, current, now),
      last_seen_at: r.last_seen_at,
      current:
        current &&
          %{
            job_id: current.id,
            card_id: current.card_id,
            title: current.card && current.card.title,
            elapsed: elapsed(current, now)
          },
      outcomes: outcomes,
      duration:
        jobs
        |> Enum.filter(&((&1.status == "done" and &1.claimed_at) && &1.finished_at))
        |> Enum.map(&DateTime.diff(&1.finished_at, &1.claimed_at))
        |> Slipdock.Dora.percentiles(),
      queue_wait:
        jobs
        |> Enum.flat_map(fn j ->
          case waited[j.id] do
            nil -> []
            at -> [max(DateTime.diff(j.claimed_at, at), 0)]
          end
        end)
        |> Slipdock.Dora.percentiles(),
      success_rate: if(ended > 0, do: Float.round(outcomes.done / ended, 3)),
      waits: %{
        opened: length(my_waits),
        open: Enum.count(my_waits, &is_nil(&1.close_reason)),
        answer: Slipdock.Dora.percentiles(answered)
      },
      reopened: %{
        count: Enum.count(reopens, &(&1.runner_id == r.id)),
        card_ids: reopens |> Enum.filter(&(&1.runner_id == r.id)) |> Enum.map(& &1.card_id)
      },
      recent:
        recent |> Enum.filter(&(&1.runner_id == r.id)) |> Enum.map(&job_line(&1, parked, now))
    }
  end

  defp status(_r, %Job{}, _now), do: "running"
  defp status(%{last_seen_at: nil}, nil, _now), do: "offline"

  defp status(r, nil, now) do
    if DateTime.diff(now, r.last_seen_at) <= 3 * Runners.lease_for(r),
      do: "idle",
      else: "offline"
  end

  defp elapsed(%Job{claimed_at: nil}, _now), do: 0
  defp elapsed(%Job{claimed_at: at}, now), do: max(DateTime.diff(now, at), 0)

  defp job_line(job, parked, now, runners \\ []) do
    outcome =
      case job.status do
        s when s in ["claimed", "running"] -> "running"
        "timeout" -> "failed"
        s -> s
      end

    %{
      job_id: job.id,
      card_id: job.card_id,
      title: job.card && job.card.title,
      runner: Enum.find_value(runners, &(&1.id == job.runner_id && &1.name)),
      outcome: outcome,
      reason:
        case outcome do
          "parked" -> parked[job.id]
          "failed" -> job.error || (job.exit_code && "exit #{job.exit_code}") || job.status
          _ -> nil
        end,
      duration:
        cond do
          job.claimed_at && job.finished_at -> DateTime.diff(job.finished_at, job.claimed_at)
          outcome == "running" -> elapsed(job, now)
          true -> nil
        end,
      claimed_at: job.claimed_at,
      finished_at: job.finished_at
    }
  end

  # What each parked job is waiting for: its wait's question.
  defp parked_reasons(jobs) do
    ids = for j <- jobs, j.status == "parked", uniq: true, do: j.id

    Repo.all(
      from w in Wait,
        where: w.job_id in ^ids,
        order_by: [asc: w.id],
        select: {w.job_id, w.needs}
    )
    |> Map.new()
  end

  # When each claimed job's wait in the queue began: from being sent again
  # for a job an answered wait queued, else from its card's last entry into
  # its board's ready list before the claim, else from being queued.
  defp queue_starts(jobs) do
    claimed = Enum.filter(jobs, & &1.claimed_at)
    ids = Enum.map(claimed, & &1.id)
    card_ids = claimed |> Enum.map(& &1.card_id) |> Enum.uniq()
    board_ids = claimed |> Enum.map(& &1.board_id) |> Enum.uniq()

    requeued =
      Repo.all(from w in Wait, where: w.requeue_job_id in ^ids, select: w.requeue_job_id)
      |> MapSet.new()

    ready =
      Repo.all(from c in Column, where: c.board_id in ^board_ids)
      |> Enum.group_by(& &1.board_id)
      |> Enum.flat_map(fn {_, cols} -> List.wrap(Flow.ready_list(cols)) end)
      |> Enum.map(& &1.id)

    entries =
      Repo.all(
        from m in CardMove,
          where:
            m.card_id in ^card_ids and m.to_column_id in ^ready and
              m.kind in ^CardMove.entry_kinds(),
          select: {m.card_id, m.inserted_at}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(claimed, fn j ->
      queued = j.inserted_at

      start =
        if MapSet.member?(requeued, j.id) do
          queued
        else
          entries
          |> Map.get(j.card_id, [])
          |> Enum.filter(&(DateTime.compare(&1, j.claimed_at) != :gt))
          |> Enum.max(DateTime, fn -> queued end)
        end

      {j.id, start}
    end)
  end

  # Waits asked from these jobs that were opened in the window.
  defp waits(job_ids, since) do
    Repo.all(
      from w in Wait,
        where: w.job_id in ^job_ids and w.inserted_at >= ^DateTime.truncate(since, :second),
        select: %{
          job_id: w.job_id,
          close_reason: w.close_reason,
          opened: w.inserted_at,
          closed: w.closed_at
        }
    )
    |> Enum.map(fn w ->
      Map.put(w, :seconds, w.closed && DateTime.diff(w.closed, w.opened))
    end)
  end

  # Each reopen in the window of a card one of these runners has had a job
  # on, credited to the runner of the card's latest job before the reopen.
  defp reopens(runner_ids, since) do
    jobs =
      Repo.all(
        from j in Job,
          where: j.runner_id in ^runner_ids and not is_nil(j.claimed_at),
          select: {j.card_id, j.runner_id, j.claimed_at}
      )
      |> Enum.group_by(&elem(&1, 0))

    card_ids = Map.keys(jobs)

    Repo.all(
      from a in Activity,
        where:
          a.card_id in ^card_ids and a.kind == "card" and like(a.message, "reopened %") and
            a.inserted_at >= ^DateTime.truncate(since, :second),
        order_by: [asc: a.id],
        select: {a.card_id, a.inserted_at}
    )
    |> Enum.flat_map(fn {card_id, at} ->
      jobs[card_id]
      |> Enum.filter(fn {_, _, claimed} -> DateTime.compare(claimed, at) != :gt end)
      |> Enum.max_by(&elem(&1, 2), DateTime, fn -> nil end)
      |> case do
        nil -> []
        {_, runner_id, _} -> [%{card_id: card_id, runner_id: runner_id, at: at}]
      end
    end)
  end
end
