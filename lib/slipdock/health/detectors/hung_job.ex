defmodule Slipdock.Health.Detectors.HungJob do
  @moduledoc """
  A claimed or running job whose lease keeps renewing but which has shown no
  sign of work — no progress step, no note on its card — for `minutes`
  (default 45). Verify jobs are left to `verify_slow`. An agent may be thinking, so by default there is no fix: it
  is flagged. With `cancel` on (`cancel=true`), a job silent for
  `cancel_minutes` (default 120) is asked to stop instead, as Cancel would.
  """
  @behaviour Slipdock.Health.Detector

  alias Slipdock.Health.{Context, Runs}
  alias Slipdock.Repo
  alias Slipdock.Runners
  alias Slipdock.Runners.Job

  @impl true
  def key, do: "hung_job"
  @impl true
  def label, do: "Job with no progress"
  @impl true
  def defaults, do: %{"minutes" => 45, "cancel" => false, "cancel_minutes" => 120}

  @impl true
  def detect(%Context{} = ctx, settings) do
    # Verify jobs are `verify_slow`'s, named for the verdict they hold up.
    ctx
    |> find(settings, nil, "job")
    |> Enum.reject(&(&1.data["kind"] == Slipdock.Verified.verify_kind()))
  end

  @doc false
  # Shared with `verify_slow`, which looks at verify jobs alone.
  def find(ctx, settings, kinds, word) do
    for job <- Runs.live_jobs(ctx.board.id, ctx.now, kinds),
        last = Runs.last_sign(job),
        idle = Context.minutes_since(ctx, last),
        idle >= settings["minutes"] do
      cancel = settings["cancel"] == true and idle >= (settings["cancel_minutes"] || idle)

      %{
        subject: %{"job" => job.id},
        card_id: job.card_id,
        # Crossing the cancel threshold is a new state, so it is tried.
        state: {DateTime.to_iso8601(last), cancel},
        summary:
          "#{String.capitalize(word)} ##{job.id} (#{job.kind}, #{job.runner_name || "a runner"}) " <>
            "is still holding its lease but has shown no progress for #{idle} minutes " <>
            "(last sign #{Runs.at_text(last)}).",
        data: %{"job" => job.id, "cancel" => cancel, "kind" => job.kind}
      }
    end
  end

  @impl true
  def resolve(incident, _attempt), do: cancel(incident)

  @doc false
  def cancel(%{data: %{"cancel" => true, "job" => id}}) do
    with %Job{} = job <- Repo.get(Job, id),
         {:ok, _} <- Runners.cancel_job(job) do
      {:tried, "asked job ##{id}'s runner to stop it (this board cancels silent jobs)"}
    else
      _ -> :no_fix
    end
  end

  def cancel(_incident), do: :no_fix
end
