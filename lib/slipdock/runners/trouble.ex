defmodule Slipdock.Runners.Trouble do
  @moduledoc """
  A job its agent couldn't run on the runner's machine goes back to the
  queue, its card untouched (#2920).

  When the runners' agent account hits its usage limit, or the agent can't
  sign in, every job fails within seconds the same way: the fault is the
  machine's, not the card's. The daemon reads it (the agent's limit
  message, or an exit within a minute before a single tool call), holds
  its runners off claiming until the stated reset or a backoff, and
  finishes the job with `status=requeue`, the trouble's kind (`limit` or
  `quick_exit`), when its runners hold off `until`, and a `reason` line.

  The job goes back to `queued` as though it had never been claimed: the
  claim's try is given back, and nothing is said on the card beyond one
  activity line. It isn't finished, so there is no handoff, no
  `requeue_stuck` count, no blocked flag and no `job_finished` notice to the
  board's rules; the card stays where the claim put it, its job next in the
  queue. The board's owner gets one warning alert per machine for the
  episode (`alert/3`), not one per job.

  A job somebody asked to cancel, or one with an open wait, is not
  requeued: `Slipdock.Runners.finish/3` ends it cancelled or parked as
  ever.
  """

  import Ecto.Query

  alias Slipdock.{Automations, Boards, Repo}
  alias Slipdock.Automations.Alert
  alias Slipdock.Runners.{Job, Runner}

  # One alert a machine says it; another is raised only once this long has
  # gone by since the last, should the trouble outlast it.
  @alert_every 6 * 3600

  @doc """
  Puts `job`, held by `runner`, back in the queue, uncounted, and raises the
  machine's alert. `attrs` carries `:trouble`, `:until` and `:reason` as the
  runner sent them, and `:output`, the job's log tail. Answers `{:ok, job}`,
  or `{:error, :not_found}` when the runner no longer holds the job.
  """
  def requeue(%Runner{} = runner, %Job{} = job, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(j in Job,
          where:
            j.id == ^job.id and j.runner_id == ^runner.id and
              j.status in ["claimed", "running"]
        ),
        set: [
          status: "queued",
          runner_id: nil,
          last_runner_id: nil,
          claimed_at: nil,
          started_at: nil,
          lease_expires_at: nil,
          exit_code: nil,
          output: output(job, attrs[:output]),
          updated_at: now
        ],
        # The claim counted a try; a try the machine couldn't make isn't one.
        inc: [attempts: if(job.attempts > 0, do: -1, else: 0)]
      )

    if count == 1 do
      Repo.update_all(
        from(r in Runner, where: r.id == ^runner.id and r.current_job_id == ^job.id),
        set: [current_job_id: nil]
      )

      # `limit`, or anything else as the agent not starting (`quick_exit`).
      kind = attrs[:trouble]
      until = until(attrs[:until])

      if job.card_id do
        Boards.ActivityLog.log_activity(
          job.board_id,
          job.card_id,
          "runner",
          "#{runner.name} couldn't run job ##{job.id} (#{describe(kind)}): " <>
            "it went back to the queue, uncounted"
        )
      end

      alert(runner, kind, %{until: until, reason: clip(attrs[:reason])})
      job = Repo.get(Job, job.id)
      Slipdock.Runners.requeued(job)
      {:ok, job}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Raises the machine's alert for `kind` of trouble, unless one was raised
  for it in the last #{div(@alert_every, 3600)} hours: one alert an
  episode, however many jobs and runners it stopped.
  """
  def alert(%Runner{} = runner, kind, info) do
    machine = machine_name(runner)
    title = title(machine, kind)
    since = DateTime.add(DateTime.utc_now(), -@alert_every)

    recent =
      Repo.exists?(
        from(a in Alert,
          where:
            a.board_id == ^runner.board_id and a.title == ^title and is_nil(a.card_id) and
              a.inserted_at >= ^since
        )
      )

    if recent do
      :ok
    else
      Automations.raise_alert(%{
        "board_id" => runner.board_id,
        "severity" => "warning",
        "title" => title,
        "body" => body(runner, kind, info)
      })
    end
  end

  defp title(machine, "limit"), do: "Runners on #{machine} stopped: the agent hit its usage limit"
  defp title(machine, _), do: "Runners on #{machine} stopped: the agent can't start"

  defp body(runner, kind, %{until: until, reason: reason}) do
    [
      "#{runner.name}'s agent couldn't run a job (#{describe(kind)})#{said(reason)}.",
      "The job went back to the queue with its card untouched: no failure, no flag.",
      if(until,
        do: "Its runners take no job until #{Calendar.strftime(until, "%Y-%m-%d %H:%M UTC")}.",
        else: "Its runners hold off and try again."
      ),
      "Restart the runner daemon on the machine to try sooner, once the account is fixed."
    ]
    |> Enum.join(" ")
  end

  defp said(nil), do: ""
  defp said(""), do: ""
  defp said(reason), do: ": “#{reason}”"

  defp describe("limit"), do: "the agent's usage limit"
  defp describe(_), do: "the agent exited before it started work"

  defp until(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> DateTime.truncate(at, :second)
      _ -> nil
    end
  end

  defp until(_), do: nil

  defp clip(nil), do: nil
  defp clip(text), do: text |> to_string() |> String.trim() |> String.slice(0, 200)

  defp output(job, text) when text in [nil, ""], do: job.output
  defp output(_job, text), do: Slipdock.Runners.tail(text)

  defp machine_name(%Runner{machine_id: nil, name: name}), do: "runner #{name}"

  defp machine_name(%Runner{machine_id: id, name: name}) do
    case Repo.get(Slipdock.Machines.Machine, id) do
      %{name: machine} when is_binary(machine) and machine != "" -> machine
      _ -> "runner #{name}"
    end
  end
end
