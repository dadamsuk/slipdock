defmodule Slipdock.Runners.Tripwire do
  @moduledoc """
  A job that sent its fake credentials out (#3524).

  The runner daemon plants fake credentials in a job's own home (a fake
  `~/.aws/credentials` and a fake GitHub token, random for each job) and
  its network proxy watches for them in what the job sends. Nothing real
  has those values, so one seen leaving means something in the job read
  them and sent them on. The daemon stops the job and finishes it with
  `tripwire=<which value, where, to what host>`; here the runner's pool is
  paused, so no more of its jobs are claimed until a person resumes it,
  and the board gets an urgent alert naming the job.

  Detection, not prevention: the proxy sees only what isn't encrypted to
  it (see the runner docs), and the daemon reports what it saw.
  """

  alias Slipdock.{Automations, Repo, Runners}
  alias Slipdock.Boards.Board
  alias Slipdock.Runners.{Job, Runner}

  @max 200

  @doc "Whether a finish says the job's tripwire went off."
  def tripped?(attrs), do: what(attrs[:tripwire]) != nil

  @doc """
  Pauses `runner`'s pool (the job's) and raises the alert for `job`,
  whose proxy saw `what`. A pool already paused stays as it is. Answers
  `{:ok, alert}`.
  """
  def tripped(%Runner{} = runner, %Job{} = job, what) do
    what = what(what) || "one of them"
    pool = job.pool || runner.pool

    if root = Repo.get(Board, runner.board_id) do
      Runners.pause(
        root,
        %{"pool" => pool, "reason" => reason(job, runner)},
        nil,
        %{kind: "agent", agent: "tripwire", via: "runner", user_id: nil, job_id: job.id}
      )
    end

    Automations.raise_alert(%{
      "board_id" => runner.board_id,
      "card_id" => job.card_id,
      "severity" => "urgent",
      "title" =>
        String.slice(
          "Tripwire: job ##{job.id} on #{runner.name} sent its fake credentials out",
          0,
          200
        ),
      "body" =>
        Enum.join(
          [
            "The runner daemon stopped job ##{job.id}#{card(job)}: its network proxy saw #{what}.",
            "Those credentials were fake, planted in the job's home, so something in the job read them and sent them on.",
            "Pool #{pool} is paused until a person resumes it. Read the job's log and the card's text before you do."
          ],
          " "
        )
    })
  end

  defp reason(job, runner),
    do: "job ##{job.id} on #{runner.name} sent its fake credentials out"

  defp card(%Job{card_id: nil}), do: ""
  defp card(%Job{card_id: id}), do: " for card ##{id}"

  defp what(text) when is_binary(text) do
    case text |> String.replace(~r/[[:cntrl:]]/u, " ") |> String.trim() do
      "" -> nil
      text -> String.slice(text, 0, @max)
    end
  end

  defp what(_), do: nil
end
