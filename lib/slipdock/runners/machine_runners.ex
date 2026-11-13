defmodule Slipdock.Runners.MachineRunners do
  @moduledoc """
  A machine's runners (#2571, epic #2569, W-2541, W-2544 §3).

  A runner the daemon runs belongs to its machine and is configured as data:
  its pool and a closed, typed config (`Slipdock.Runners.Config`), with no
  command field. Each change bumps the runner's `config_version` and the
  machine's, and wakes the daemon's long-poll (`wait_for_config/3`), so a
  change made on the board arrives within seconds.

  The daemon checks each runner's config against its machine's ceiling and
  says what it did (`report/3`): accepted (the runner now runs that
  version) or rejected with a reason (the runner keeps its last accepted
  config). Both are kept on the runner and in the machine's log
  (`Slipdock.Runners.ConfigReport`). The ceiling itself the daemon reports
  from its own local file (`record_ceiling/2`); the server shows it and
  never sets it.

  Each runner stays its own identity: it has its own id, so a verify job's
  "not the builder" check tells two runners of one machine apart. It
  authenticates with the machine's key, never a token of its own
  (`machine_runner/2`); the token hash it is given is of a token nobody is
  shown, and `Slipdock.Runners.authenticate/1` refuses a machine runner's
  token besides.
  """

  import Ecto.Query

  alias Slipdock.Boards.Board
  alias Slipdock.Machines.Machine
  alias Slipdock.Repo
  alias Slipdock.Runners.{Ceiling, Config, ConfigReport, Runner}

  @pubsub Slipdock.PubSub
  @max_reason 1000

  @doc "The PubSub topic a machine's config changes and reports go out on."
  def topic(%Machine{id: id}), do: topic(id)
  def topic(machine_id) when is_integer(machine_id), do: "machine_config:#{machine_id}"

  @doc "Subscribes to a machine's config changes and reports (the Machines page)."
  def subscribe(machine), do: Phoenix.PubSub.subscribe(@pubsub, topic(machine))

  @doc """
  Tells whoever follows the machine (its page, Account › Machines, the
  daemon's long-poll) that something about it changed outside its runners'
  config: a rename (#2764). It goes out as `:config_changed`, which the
  pages reload on; the daemon's long-poll looks at `config_version`, which
  this doesn't bump, and goes on waiting.
  """
  def changed(%Machine{} = machine), do: broadcast(machine, :config_changed)

  ## The owner's side --------------------------------------------------------------

  @doc "`machine`'s runners, oldest first."
  def list_runners(%Machine{id: id}) do
    Repo.all(from(r in Runner, where: r.machine_id == ^id, order_by: [asc: r.id]))
  end

  @doc "One of `machine`'s runners, by id or name."
  def get_runner(%Machine{id: machine_id}, ref) do
    ref = to_string(ref)
    base = from(r in Runner, where: r.machine_id == ^machine_id)

    found =
      case Integer.parse(ref) do
        {id, ""} -> Repo.one(from(r in base, where: r.id == ^id))
        _ -> nil
      end || Repo.one(from(r in base, where: r.name == ^ref, limit: 1))

    if found, do: {:ok, found}, else: {:error, :not_found, "runner"}
  end

  @doc """
  The job each of `runners` holds now (claimed or running, card preloaded),
  by runner id: what the Machines page shows as its current job.
  """
  def running_jobs(runners) do
    ids = Enum.map(runners, & &1.id)

    from(j in Slipdock.Runners.Job,
      where: j.runner_id in ^ids and j.status in ["claimed", "running"],
      order_by: [asc: j.id],
      preload: :card
    )
    |> Repo.all()
    |> Map.new(&{&1.runner_id, &1})
  end

  @doc """
  Adds a runner to `machine` for `board`'s tree. `attrs`: `pool` (required),
  `name` (defaults to the machine's name and the pool) and `config` (see
  `Slipdock.Runners.Config`; `directory` is required). The board must be
  one the machine serves. Returns `{:ok, runner}` or
  `{:error, :invalid, message}`.
  """
  def add_runner(%Machine{} = machine, %Board{} = board, attrs) do
    root_id = Board.root_id(board)

    with :ok <- live(machine),
         :ok <- serves(machine, root_id),
         {:ok, config} <- config(attrs["config"] || attrs[:config] || %{}, nil) do
      pool = attrs["pool"] || attrs[:pool]

      %Runner{
        board_id: root_id,
        machine_id: machine.id,
        created_by_id: machine.user_id,
        token_hash: :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)),
        config: config,
        config_version: 1
      }
      |> Runner.changeset(%{
        "pool" => pool,
        "name" => attrs["name"] || attrs[:name] || default_name(machine, pool)
      })
      |> save(machine, &Repo.insert/1)
    end
  end

  # Writes the runner and bumps the machine's version in one transaction,
  # then wakes the daemon's long-poll.
  defp save(changeset, machine, write) do
    Repo.transaction(fn ->
      case write.(changeset) do
        {:ok, runner} ->
          bump(machine)
          runner

        {:error, cs} ->
          Repo.rollback({:invalid, changeset_message(cs)})
      end
    end)
    |> after_change(machine)
  end

  defp default_name(%Machine{name: name}, pool) when is_binary(pool),
    do: "#{name} #{String.trim(pool)}"

  defp default_name(%Machine{name: name}, _pool), do: name

  @doc """
  Changes a machine runner: `pool`, `name` and any of the `config` fields
  (the rest keep their values). A change that alters nothing leaves the
  version where it was. Returns `{:ok, runner}` or
  `{:error, :invalid, message}`.
  """
  def set_runner(%Runner{machine_id: machine_id} = runner, attrs) when is_integer(machine_id) do
    machine = Repo.get!(Machine, machine_id)

    with :ok <- live(machine),
         {:ok, config} <- config(attrs["config"] || attrs[:config] || %{}, runner.config) do
      changeset =
        runner
        |> Runner.changeset(Map.take(stringify(attrs), ["pool", "name"]))
        |> Ecto.Changeset.put_change(:config, config)

      if changeset.changes == %{},
        do: {:ok, runner},
        else:
          changeset
          |> Ecto.Changeset.put_change(:config_version, runner.config_version + 1)
          |> save(machine, &Repo.update/1)
    end
  end

  def set_runner(%Runner{}, _attrs),
    do: {:error, :invalid, "not a machine's runner: its settings live in its own config"}

  @doc """
  Removes a machine runner. The daemon sees it gone from the config on its
  next poll, finishes the job it holds, and stops it.
  """
  def remove_runner(%Runner{machine_id: machine_id} = runner) when is_integer(machine_id) do
    machine = Repo.get!(Machine, machine_id)

    Repo.transaction(fn ->
      Repo.delete!(runner)
      bump(machine)
      runner
    end)
    |> after_change(machine)
  end

  @doc """
  Pauses a machine runner (#2572): the server hands it no job until it is
  resumed, and its config tells the daemon so. The job it holds finishes.
  Pausing one already paused leaves it as it was.
  """
  def pause_runner(%Runner{machine_id: machine_id, paused_at: nil} = runner)
      when is_integer(machine_id),
      do: set_paused(runner, DateTime.utc_now(:second))

  def pause_runner(%Runner{machine_id: machine_id} = runner) when is_integer(machine_id),
    do: {:ok, runner}

  def pause_runner(%Runner{}), do: not_a_machine_runner()

  @doc "Resumes a paused machine runner: it takes jobs again."
  def resume_runner(%Runner{machine_id: machine_id, paused_at: %DateTime{}} = runner)
      when is_integer(machine_id),
      do: set_paused(runner, nil)

  def resume_runner(%Runner{machine_id: machine_id} = runner) when is_integer(machine_id),
    do: {:ok, runner}

  def resume_runner(%Runner{}), do: not_a_machine_runner()

  defp not_a_machine_runner,
    do: {:error, :invalid, "not a machine's runner: its settings live in its own config"}

  defp set_paused(runner, at) do
    machine = Repo.get!(Machine, runner.machine_id)

    with :ok <- live(machine) do
      runner
      |> Ecto.Changeset.change(paused_at: at)
      |> save(machine, &Repo.update/1)
    end
  end

  @doc """
  *Update now* (#2572): asks the machine's daemon to look for a newer
  signed release at once rather than at its next check. The request goes
  out in its config (`update_requested_at`); the daemon decides, and
  verifies what it fetches (W-2542).
  """
  def request_update(%Machine{} = machine) do
    with :ok <- live(machine) do
      now = DateTime.utc_now(:second)

      Repo.update_all(from(m in Machine, where: m.id == ^machine.id),
        inc: [config_version: 1],
        set: [update_requested_at: now, updated_at: now]
      )

      broadcast(machine, :config_changed)
      {:ok, Repo.get!(Machine, machine.id)}
    end
  end

  defp live(%Machine{revoked_at: nil}), do: :ok
  defp live(%Machine{}), do: {:error, :invalid, "the machine is revoked"}

  defp serves(%Machine{board_ids: ids}, root_id) do
    if Enum.member?(ids, root_id),
      do: :ok,
      else: {:error, :invalid, "the machine doesn't serve that board: choose one of its boards"}
  end

  defp config(attrs, base) do
    case Config.build(attrs, base) do
      {:ok, config} -> {:ok, config}
      {:error, message} -> {:error, :invalid, message}
    end
  end

  defp bump(%Machine{id: id}) do
    now = DateTime.utc_now(:second)

    Repo.update_all(from(m in Machine, where: m.id == ^id),
      inc: [config_version: 1],
      set: [updated_at: now]
    )
  end

  defp after_change({:ok, value}, machine) do
    broadcast(machine, :config_changed)
    {:ok, value}
  end

  defp after_change({:error, {:invalid, message}}, _machine), do: {:error, :invalid, message}

  defp broadcast(machine, message),
    do: Phoenix.PubSub.broadcast(@pubsub, topic(machine), {message, machine.id})

  ## The daemon's side -------------------------------------------------------------

  @doc """
  The runner `ref` (an id) names when it is one of `machine`'s, or nil: a
  machine key claims and reports only for its own runners.
  """
  def machine_runner(%Machine{id: machine_id}, ref) do
    case Integer.parse(to_string(ref || "")) do
      {id, ""} -> Repo.one(from(r in Runner, where: r.id == ^id and r.machine_id == ^machine_id))
      _ -> nil
    end
  end

  @doc """
  What the daemon runs: the machine's config version, when *update now*
  was last asked for, and each runner's id, name, board, pool, config,
  config version and whether it is paused.
  """
  def config_for(%Machine{id: id}) do
    machine = Repo.get!(Machine, id)

    %{
      version: machine.config_version,
      update_requested_at: machine.update_requested_at,
      runners:
        Enum.map(list_runners(machine), fn r ->
          %{
            id: r.id,
            name: r.name,
            board_id: r.board_id,
            pool: r.pool,
            config: r.config,
            config_version: r.config_version,
            paused: not is_nil(r.paused_at)
          }
        end)
    }
  end

  @doc """
  The daemon's long-poll: the machine's config (`config_for/1`) as soon as
  its version is above `since`, at once if it already is, or nil when
  `wait_ms` passes with no change.
  """
  def wait_for_config(%Machine{} = machine, since, wait_ms) do
    if current_version(machine) > since do
      config_for(machine)
    else
      subscribe(machine)

      try do
        # Looked at again after subscribing, so a change in between isn't missed.
        if current_version(machine) > since,
          do: config_for(machine),
          else: await_change(machine, since, System.monotonic_time(:millisecond) + wait_ms)
      after
        Phoenix.PubSub.unsubscribe(@pubsub, topic(machine))
      end
    end
  end

  defp await_change(machine, since, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:config_changed, _id} ->
        if current_version(machine) > since,
          do: config_for(machine),
          else: await_change(machine, since, deadline)
    after
      left -> nil
    end
  end

  defp current_version(%Machine{id: id}),
    do: Repo.one(from(m in Machine, where: m.id == ^id, select: m.config_version))

  @doc """
  Records what the daemon said of runner `runner`'s config at `version`:
  `%{"outcome" => "accepted"}`, or `"rejected"` with a `reason`. Only the
  runner's current version can be reported on (a stale one gets
  `{:error, :stale, current}`: the daemon has a newer config to fetch).
  Accepting clears a rejection on record.
  """
  def report(%Machine{} = machine, %Runner{machine_id: machine_id} = runner, attrs)
      when machine_id == machine.id do
    attrs = stringify(attrs)

    with {:ok, version} <- version(attrs["version"], runner),
         {:ok, outcome, reason} <- outcome(attrs) do
      {:ok, runner} =
        Repo.transaction(fn ->
          runner =
            runner
            |> Ecto.Changeset.change(report_changes(runner, outcome, version, reason))
            |> Repo.update!()

          Repo.insert!(%ConfigReport{
            machine_id: machine.id,
            runner_id: runner.id,
            runner_name: runner.name,
            version: version,
            outcome: outcome,
            reason: reason
          })

          runner
        end)

      broadcast(machine, :config_reported)
      {:ok, runner}
    end
  end

  def report(%Machine{}, %Runner{}, _attrs), do: {:error, :not_found}

  # Only the current version is reported on, so an acceptance is never
  # older than a rejection on record: it clears it.
  defp report_changes(runner, "accepted", version, _reason) do
    [
      accepted_version: version,
      accepted_config: runner.config,
      rejected_version: nil,
      rejection: nil,
      rejected_at: nil
    ]
  end

  defp report_changes(_runner, "rejected", version, reason),
    do: [rejected_version: version, rejection: reason, rejected_at: DateTime.utc_now(:second)]

  defp version(value, runner) do
    case Integer.parse(to_string(value || "")) do
      {v, ""} when v == runner.config_version -> {:ok, v}
      {_, ""} -> {:error, :stale, runner.config_version}
      _ -> {:error, :invalid, "version is required: the config version you checked"}
    end
  end

  defp outcome(%{"outcome" => "accepted"}), do: {:ok, "accepted", nil}

  defp outcome(%{"outcome" => "rejected"} = attrs) do
    case clean(attrs["reason"]) do
      nil -> {:error, :invalid, "a rejection says why: give a reason"}
      reason -> {:ok, "rejected", reason}
    end
  end

  defp outcome(_), do: {:error, :invalid, "outcome must be accepted or rejected"}

  @doc "The machine's log of accepted and rejected changes, newest first."
  def reports(%Machine{id: id}, limit \\ 50) do
    Repo.all(
      from(r in ConfigReport,
        where: r.machine_id == ^id,
        order_by: [desc: r.id],
        limit: ^limit
      )
    )
  end

  @doc """
  Records the ceiling the daemon reported from the machine's own local file
  (see `Slipdock.Runners.Ceiling`). `{:ok, machine}` or
  `{:error, :invalid, message}`.
  """
  def record_ceiling(%Machine{} = machine, attrs) do
    case Ceiling.build(attrs) do
      {:ok, ceiling} ->
        {:ok, machine} =
          machine
          |> Ecto.Changeset.change(ceiling: ceiling, ceiling_at: DateTime.utc_now(:second))
          |> Repo.update()

        broadcast(machine, :config_reported)
        {:ok, machine}

      {:error, message} ->
        {:error, :invalid, message}
    end
  end

  @doc """
  Where `runner`'s config falls outside its machine's recorded ceiling, as
  `Slipdock.Runners.Ceiling.check/3` says: what the page greys out. The
  daemon is still what refuses it.
  """
  def outside_ceiling(%Machine{ceiling: ceiling}, %Runner{config: config, board_id: board_id}),
    do: Ceiling.check(config, ceiling, board_id)

  defp clean(value) when is_binary(value) do
    case value |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/u, "") |> String.trim() do
      "" -> nil
      text -> String.slice(text, 0, @max_reason)
    end
  end

  defp clean(_), do: nil

  defp stringify(attrs) when is_map(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  defp changeset_message(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
