defmodule Slipdock.Health.Detectors.NoRunner do
  @moduledoc """
  A queued job whose pool has had no runner online (seen within three of its
  leases) for `minutes` (default 15), while the job waited at least that
  long. There is no fix on the server: it is flagged. If another pool on the
  tree has a runner online that takes that kind of job, the flag says so. A
  paused pool is left to `long_pause`.
  """
  @behaviour Slipdock.Health.Detector

  import Ecto.Query

  alias Slipdock.Health.{Context, Runs}
  alias Slipdock.Repo
  alias Slipdock.Runners
  alias Slipdock.Runners.Job

  @impl true
  def key, do: "no_runner"
  @impl true
  def label, do: "No runner online"
  @impl true
  def defaults, do: %{"minutes" => 15}

  @impl true
  def detect(%Context{} = ctx, %{"minutes" => minutes}) do
    root_id = ctx.board.id
    cutoff = DateTime.add(ctx.now, -minutes * 60)

    jobs =
      from(j in Job,
        where: j.root_board_id == ^root_id and j.status == "queued" and j.inserted_at <= ^cutoff,
        order_by: j.id
      )
      |> Repo.all()

    runners = Runs.runners(root_id)

    for job <- jobs,
        is_nil(Runners.pause_for(root_id, job.pool)),
        pool = Enum.filter(runners, &(&1.pool == job.pool)),
        not Enum.any?(pool, &Runs.online?(&1, ctx.now)),
        # In a list, so a pool never seen (nil) still passes the comprehension.
        [last] = [last_seen(pool)],
        is_nil(last) or Context.minutes_since(ctx, last) >= minutes do
      %{
        subject: %{"job" => job.id},
        card_id: job.card_id,
        state: job.pool,
        summary:
          "Job ##{job.id} (#{job.kind}) has waited #{Context.minutes_since(ctx, job.inserted_at)} " <>
            "minutes for the #{job.pool} pool, and no runner of that pool is online " <>
            "(#{seen(last)})." <> elsewhere(job, runners, ctx.now)
      }
    end
  end

  defp last_seen(pool) do
    pool
    |> Enum.map(& &1.last_seen_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp seen(nil), do: "none has ever been seen"
  defp seen(at), do: "last seen #{Runs.at_text(at)}"

  # Online runners in other pools that said they take this kind of job.
  defp elsewhere(job, runners, now) do
    pools =
      runners
      |> Enum.filter(
        &(&1.pool != job.pool and Runs.online?(&1, now) and is_list(&1.kinds) and
            Enum.member?(&1.kinds, job.kind))
      )
      |> Enum.map(& &1.pool)
      |> Enum.uniq()

    case pools do
      [] -> ""
      pools -> " Pool #{Enum.join(pools, ", ")} is online and takes #{job.kind} jobs."
    end
  end
end
