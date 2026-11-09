defmodule Slipdock.Runners.Probe do
  @moduledoc """
  The probe (#2580, epic #2569, W-2544 §8): a machine runner checking its
  own setup, sent by the machine's owner from the Machines page, the API or
  the CLI.

  A probe is a job like any other (`Slipdock.Runners.Job`): kind `probe`,
  in the job table, claimed, leased, heartbeated and finished over the
  runner protocol, its log kept and expired as every job's is. Two things
  set it apart:

  - it has no card (`card_id` is nil), so nothing it does touches a card:
    no handoff, no comment, no flag, no finding, no status update;
  - it goes to one runner (`for_runner_id`), never another in its pool,
    and ahead of the pool's queue (`Slipdock.Runners.claim/2`).

  Its prompt is data, not instructions: what the server knows of the
  runner that the daemon can't see for itself, one `name: value` line each
  (`prompt/1`). The daemon runs its built-in checks and then the runner's
  probe hook, if its config names one, from the machine's own file; the
  server never says what to run. A probe that ends `done` is green, any
  other end is red, with the log it sent.
  """

  import Ecto.Query

  alias Slipdock.Machines.Machine
  alias Slipdock.Repo
  alias Slipdock.Runners
  alias Slipdock.Runners.{Drift, Job, Runner}

  @kind "probe"
  @pubsub Slipdock.PubSub

  @doc "The probe's job kind."
  def kind, do: @kind

  @doc """
  Sends a probe to `runner`, one of `machine`'s runners. A probe already
  queued or running for it is answered instead of a second one. Refused
  for a revoked machine and a paused runner (it takes no job, so the probe
  would wait for ever). `{:ok, job}` or `{:error, :invalid, message}`.
  """
  def send_probe(%Machine{} = machine, %Runner{} = runner) do
    cond do
      runner.machine_id != machine.id ->
        {:error, :invalid, "that runner is not one of #{machine.name}'s"}

      Machine.revoked?(machine) ->
        {:error, :invalid, "#{machine.name} is revoked, so it takes no probe"}

      runner.paused_at ->
        {:error, :invalid, "#{runner.name} is paused: resume it, then probe it"}

      job = open_probe(runner) ->
        {:ok, job}

      true ->
        insert(runner)
    end
  end

  defp insert(runner) do
    {:ok, job} =
      %Job{
        board_id: runner.board_id,
        root_board_id: runner.board_id,
        card_id: nil,
        for_runner_id: runner.id,
        pool: runner.pool,
        kind: @kind,
        prompt: "",
        status: "queued"
      }
      |> Ecto.Changeset.change()
      |> Repo.insert()

    Runners.wake_pool(runner.board_id, runner.pool)
    broadcast(job)
    {:ok, job}
  end

  defp open_probe(%Runner{id: id}) do
    Repo.one(
      from(j in Job,
        where: j.for_runner_id == ^id and j.status in ^Job.open_statuses(),
        order_by: [desc: j.id],
        limit: 1
      )
    )
  end

  @doc """
  Hands `runner` its own queued probe, claimed with a lease, or nil. Only
  for a runner that said on its claim that it takes probes: an older
  daemon would refuse the kind.
  """
  def claim(%Runner{} = runner) do
    if takes_probes?(runner), do: claim_queued(runner)
  end

  defp claim_queued(runner) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    candidate =
      from(j in Job,
        where: j.for_runner_id == ^runner.id and j.status == "queued" and j.kind == ^@kind,
        order_by: [asc: j.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED",
        select: j.id
      )

    {:ok, claimed} =
      Repo.transaction(fn ->
        with id when is_integer(id) <- Repo.one(candidate),
             {1, [job]} <-
               Repo.update_all(
                 from(j in Job, where: j.id == ^id and j.status == "queued", select: j),
                 set: [
                   status: "claimed",
                   runner_id: runner.id,
                   runner_name: runner.name,
                   claimed_at: now,
                   lease_expires_at: DateTime.add(now, Runners.lease_for(runner)),
                   updated_at: now
                 ],
                 inc: [attempts: 1]
               ) do
          Repo.update_all(from(r in Runner, where: r.id == ^runner.id),
            set: [current_job_id: job.id]
          )

          job
        else
          _ -> nil
        end
      end)

    claimed
  end

  @doc "Whether `runner` takes probes: it listed the kind on its last claim."
  def takes_probes?(%Runner{kinds: kinds}) when is_list(kinds), do: Enum.member?(kinds, @kind)
  def takes_probes?(_runner), do: false

  @doc """
  The probe's prompt as the runner is handed it: what the server knows of
  the runner, one `name: value` line each. `skills` and `cli` are the drift
  states its claim just reported, against what this server serves
  (`Slipdock.Runners.Drift`): `current`, `drifted (names)`, `old`, `none`
  or `unknown`.
  """
  def prompt(%Job{runner_id: runner_id}) do
    case runner_id && Repo.get(Runner, runner_id) do
      %Runner{} = runner ->
        %{skills: skills, cli: cli} = Drift.states(runner)

        "probe of runner #{runner.name} (##{runner.id})\n" <>
          "skills: #{Drift.describe(skills)}\n" <>
          "cli: #{Drift.describe(cli)}\n"

      _ ->
        "probe\n"
    end
  end

  @doc """
  The newest probe of each of `runners`, by runner id: what the Machines
  page and `machine show` give as its probe result.
  """
  def latest(runners) do
    ids = Enum.map(runners, & &1.id)

    from(j in Job,
      where: j.for_runner_id in ^ids and j.kind == ^@kind,
      distinct: j.for_runner_id,
      order_by: [asc: j.for_runner_id, desc: j.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.for_runner_id, &1})
  end

  @doc """
  How a probe stands: `:green` (it ended done), `:red` (it ended any other
  way) or `:pending` (queued, claimed or running).
  """
  def result(%Job{status: "done"}), do: :green

  def result(%Job{status: status}) when status in ["queued", "claimed", "running"],
    do: :pending

  def result(%Job{}), do: :red

  @doc "The log a probe sent: its finish's output, else its last heartbeat's tail."
  def log(%Job{output: output}) when is_binary(output) and output != "", do: output
  def log(%Job{log_tail: tail}) when is_binary(tail), do: tail
  def log(_job), do: ""

  @doc false
  # A probe changed (queued, claimed, heartbeated, ended): its machine's
  # page hears of it on the machine's topic.
  def broadcast(%Job{kind: @kind, for_runner_id: runner_id} = job) when is_integer(runner_id) do
    case Repo.one(from(r in Runner, where: r.id == ^runner_id, select: r.machine_id)) do
      machine_id when is_integer(machine_id) ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          Slipdock.Runners.MachineRunners.topic(machine_id),
          {:probe_changed, job.id}
        )

      _ ->
        :ok
    end
  end

  def broadcast(_job), do: :ok
end
