defmodule Slipdock.Health.Runs do
  @moduledoc """
  What the detectors about runners and jobs share: which runners are online,
  and when a job last showed a sign of work.
  """

  import Ecto.Query

  alias Slipdock.Boards.Comment
  alias Slipdock.Repo
  alias Slipdock.Runners
  alias Slipdock.Runners.{Job, Runner}

  @doc "The runners on the tree rooted at `root_id`."
  def runners(root_id), do: Repo.all(from(r in Runner, where: r.board_id == ^root_id))

  @doc "Whether `runner` is online at `now`: seen within three of its leases."
  def online?(%Runner{last_seen_at: nil}, _now), do: false

  def online?(%Runner{last_seen_at: seen} = runner, now),
    do: DateTime.diff(now, seen) <= 3 * Runners.lease_for(runner)

  @doc "Whether `runner` is online and holds no job."
  def idle?(%Runner{current_job_id: nil} = runner, now), do: online?(runner, now)
  def idle?(_runner, _now), do: false

  @doc "The tree's claimed and running jobs whose lease is still current."
  def live_jobs(root_id, now, kinds \\ nil) do
    from(j in Job,
      where:
        j.root_board_id == ^root_id and j.status in ["claimed", "running"] and
          j.lease_expires_at > ^now and is_nil(j.cancel_requested_at)
    )
    |> then(&if(kinds, do: where(&1, [j], j.kind in ^kinds), else: &1))
    |> Repo.all()
  end

  @doc """
  When `job` last showed a sign of work: its latest progress step, a comment
  on its card since it was claimed (an agent's note), or else when it started.
  """
  def last_sign(%Job{} = job) do
    since = job.claimed_at || job.started_at || job.inserted_at

    comment =
      job.card_id &&
        Repo.one(
          from(c in Comment,
            # The server's own comments (the monitor's, a put-back) are no sign of work.
            where:
              c.card_id == ^job.card_id and c.inserted_at >= ^since and not is_nil(c.user_id),
            select: max(c.inserted_at)
          )
        )

    [job.step_at, job.started_at, job.claimed_at, comment]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_utc/1)
    |> Enum.max(DateTime, fn -> to_utc(since) end)
  end

  defp to_utc(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp to_utc(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> to_utc()

  @doc "`at` as `9 Nov 14:05`, for summaries."
  def at_text(nil), do: "never"
  def at_text(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %H:%M UTC")
end
