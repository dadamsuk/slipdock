defmodule Slipdock.Automations.Scheduler do
  @moduledoc """
  The clock behind the time-based triggers: every `:interval` milliseconds
  (a minute by default) it asks `Slipdock.Automations.run_scheduled/1` to look
  for cards that have gone stale, come due or run late.

  Set `config :slipdock, :automations, interval: :manual` to keep it quiet,
  as the tests do. A test then drives it with `run_now/0` (a whole tick: the
  periodic jobs and the rules) or calls `Slipdock.Automations.run_scheduled/1`
  directly to run the rules at a chosen time.

  ## One node ticks (#3496)

  Every app node starts a scheduler, but only one of them runs the ticks:
  the leader, which holds a Postgres session advisory lock on a connection
  of its own (`Slipdock.Automations.Scheduler.Leader`). The others check at
  each tick whether they can take it, and skip the tick while they can't, so
  a sweep, a recurrence or a release tick runs once however many nodes
  there are. A node that dies closes its connection, Postgres lets the lock
  go, and the next node to tick takes over. `config :slipdock, :automations,
  cluster_lock: false` ticks on every node without asking (the test env:
  tests drive the node's scheduler with `run_now/0`).

  ## Each job on its own (#3497)

  A tick queues every periodic job and the rules, each as its own task
  under `Slipdock.Automations.Scheduler.Tasks`, and starts them in order,
  `max_jobs` (3) at a time: so one slow job holds up nothing but itself,
  and the scheduler goes on answering. A job is stopped, and logged as
  failed, once it has run for `job_timeout` (5 minutes). One still running
  (or still waiting to start) when the next tick comes is skipped for that
  tick, not started twice. Jobs no longer finish before the rules start: a
  rule that depends on what a job did sees it at the next tick.
  """

  use GenServer

  require Logger

  @default_interval :timer.minutes(1)
  # Nothing is time-critical here, and a fresh boot shouldn't fire a day's
  # worth of rules while the database is still warming up.
  @startup_delay :timer.seconds(20)
  # How long one job may run before it is stopped, and how many run at once
  # (each may hold a database connection, and the pool is shared with the
  # web requests): `config :slipdock, :automations, job_timeout:, max_jobs:`.
  @default_job_timeout :timer.minutes(5)
  @default_max_jobs 3
  @tasks Slipdock.Automations.Scheduler.Tasks

  alias Slipdock.Automations.Scheduler.Leader

  @doc """
  Starts the scheduler. The node's own takes no options; a test starting
  others can give `:name`, `:jobs` (a list of `{label, fun}` run in place
  of the node's jobs and rules), `:cluster_lock` (`false`, or the
  `{key1, key2}` advisory lock to lead by), and `:job_timeout` and
  `:max_jobs` (see *Each job on its own*).
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Asks the running scheduler to tick now, and waits for every job the tick
  started to finish or be stopped at its timeout. Returns how many rules
  fired, or `:not_leader` when another node holds the lead.
  """
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :tick, :infinity)

  @impl true
  def init(opts) do
    if interval() != :manual, do: Process.send_after(self(), :tick, @startup_delay)

    lock = Keyword.get_lazy(opts, :cluster_lock, &configured_lock/0)
    leader = if lock, do: Leader.start_link(lock)
    config = Slipdock.Config.get(:automations, [])

    {:ok,
     %{
       jobs: opts[:jobs],
       leader: leader,
       leading: nil,
       job_timeout: opts[:job_timeout] || config[:job_timeout] || @default_job_timeout,
       max_jobs: opts[:max_jobs] || config[:max_jobs] || @default_max_jobs,
       # ref => %{label, pid, timer, tick}: the jobs running now.
       running: %{},
       # {tick, label, fun}: started as `running` has room.
       queue: :queue.new(),
       # tick => %{from, left, fired}: a `run_now/1` waiting for its tick.
       waiting: %{}
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    {_result, state} = safe_tick(state, nil)
    if interval() != :manual, do: Process.send_after(self(), :tick, interval())
    {:noreply, state}
  end

  # A job finished: its fun's result (the rules' count, for the rules).
  def handle_info({ref, result}, %{running: running} = state)
      when is_reference(ref) and is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finished(ref, result) |> start_queued()}
  end

  # A job's process ended without a result: an exit `guarded/3` can't
  # rescue, or the task supervisor going.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: running} = state)
      when is_map_key(running, ref) do
    Logger.error("#{running[ref].label} failed: #{Exception.format_exit(reason)}")
    {:noreply, state |> finished(ref, nil) |> start_queued()}
  end

  def handle_info({:job_timeout, ref}, %{running: running} = state)
      when is_map_key(running, ref) do
    %{label: label, pid: pid} = running[ref]
    Task.Supervisor.terminate_child(@tasks, pid)
    Process.demonitor(ref, [:flush])

    Logger.error(
      "#{label} failed: still running after #{div(state.job_timeout, 1000)} s, so it was stopped"
    )

    {:noreply, state |> finished(ref, nil) |> start_queued()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:tick, from, state) do
    case safe_tick(state, from) do
      {:not_leader, state} -> {:reply, :not_leader, state}
      {:started, state} -> {:noreply, state}
    end
  end

  # Ticks only on the node that leads (see the moduledoc), and says so in
  # the log when that changes.
  defp safe_tick(state, from) do
    leader = state.leader
    leading = leader == nil or Leader.leading?(leader)
    if leader && leading != state.leading, do: log_lead(leading)
    state = %{state | leading: leading}

    if leading, do: {:started, tick(state, from)}, else: {:not_leader, state}
  end

  defp log_lead(true), do: Logger.info("Automation scheduler: this node leads the ticks")

  defp log_lead(false),
    do: Logger.info("Automation scheduler: another node leads the ticks; this one waits")

  # Queues each of the tick's jobs, skipping one still running (or still
  # queued) from an earlier tick, and starts as many as there is room for.
  # A `run_now/1` caller is answered once the jobs this tick queued are done.
  defp tick(state, from) do
    tick = make_ref()
    busy = busy_labels(state)

    {queued, skipped} =
      Enum.split_with(tick_jobs(state.jobs), fn {label, _} -> not MapSet.member?(busy, label) end)

    for {label, _} <- skipped,
        do:
          Logger.warning("#{label} is still running from an earlier tick, so this tick skips it")

    queue =
      Enum.reduce(queued, state.queue, fn {label, fun}, q -> :queue.in({tick, label, fun}, q) end)

    labels = MapSet.new(queued, &elem(&1, 0))

    state = %{state | queue: queue}

    if from && labels == MapSet.new(), do: GenServer.reply(from, 0)

    waiting =
      if from && labels != MapSet.new(),
        do: Map.put(state.waiting, tick, %{from: from, left: labels, fired: 0}),
        else: state.waiting

    start_queued(%{state | waiting: waiting})
  end

  defp busy_labels(state) do
    running = Enum.map(state.running, fn {_ref, job} -> job.label end)
    queued = Enum.map(:queue.to_list(state.queue), fn {_tick, label, _fun} -> label end)
    MapSet.new(running ++ queued)
  end

  defp start_queued(state) do
    with true <- map_size(state.running) < state.max_jobs,
         {{:value, {tick, label, fun}}, queue} <- :queue.out(state.queue) do
      task = Task.Supervisor.async_nolink(@tasks, fun)
      timer = Process.send_after(self(), {:job_timeout, task.ref}, state.job_timeout)
      job = %{label: label, pid: task.pid, timer: timer, tick: tick}
      start_queued(%{state | queue: queue, running: Map.put(state.running, task.ref, job)})
    else
      _ -> state
    end
  end

  defp finished(state, ref, result) do
    {%{label: label, timer: timer, tick: tick}, running} = Map.pop(state.running, ref)
    Process.cancel_timer(timer)
    state = %{state | running: running}

    case state.waiting do
      %{^tick => wait} ->
        fired = if is_integer(result), do: wait.fired + result, else: wait.fired
        left = MapSet.delete(wait.left, label)

        if left == MapSet.new() do
          GenServer.reply(wait.from, fired)
          %{state | waiting: Map.delete(state.waiting, tick)}
        else
          put_in(state.waiting[tick], %{wait | left: left, fired: fired})
        end

      _ ->
        state
    end
  end

  # The tick's `{label, fun}`s, each already guarded: a job or rule that
  # blows up must not take the scheduler with it, and is logged as
  # "<label> failed: ...". Only the rules answer a number: how many fired.
  defp tick_jobs(nil) do
    Enum.map(jobs(), &as_system/1) ++
      [
        {"Automation scheduler",
         fn -> guarded("Automation scheduler", &Slipdock.Automations.run_scheduled/0, 0) end}
      ]
  end

  defp tick_jobs(jobs), do: Enum.map(jobs, &as_system/1)

  # Each job is the server's own work, with nobody behind it, and says so to
  # `Slipdock.Policy` with its label (#3169).
  defp as_system({label, fun}) do
    {label,
     fn ->
       guarded(label, fn -> Slipdock.Policy.as_system("the scheduler: " <> label, fun) end)
     end}
  end

  defp configured_lock do
    if Keyword.get(Slipdock.Config.get(:automations, []), :cluster_lock, true),
      do: Leader.default_lock()
  end

  @doc false
  # The periodic jobs, in the order they start, before the rules themselves
  # (`Slipdock.Automations.run_scheduled/0`). A new one goes here, as
  # `{label, fun}`; it runs as its own task, and is logged as "<label>
  # failed: ..." if it raises, exits or runs past its timeout.
  def jobs do
    [
      # The scheduler's pulse, for `/healthz` (see `Slipdock.Health.pulse/1`):
      # every tick, before anything that could fail.
      {"Scheduler pulse", fn -> Slipdock.Health.Pulse.beat("scheduler") end},
      # Runner jobs whose lease has run out (see `Slipdock.Runners`), and job
      # logs past their board's time (#1872).
      {"Runner job sweep",
       fn ->
         Slipdock.Runners.sweep()
         Slipdock.Runners.TranscriptRetention.sweep()
       end},
      # The wiki's change log keeps a window, not everything (see
      # `Slipdock.Wiki.Changes`); hourly is plenty.
      {"Wiki change log prune", &Slipdock.Wiki.Changes.prune_hourly/0},
      # Unsaved wiki work nobody came back for (see `Slipdock.Wiki.Autosaves`).
      {"Autosave prune", &Slipdock.Wiki.Autosaves.prune/0},
      # The overseer's watch checks, and its passes when due (#2068, see
      # `Slipdock.Overseer`): every tick, on boards that turned it on.
      {"Overseer", &Slipdock.Overseer.tick/0},
      # Recurring cards whose next instance is due (see `Slipdock.Recurrence`).
      {"Recurring cards", &Slipdock.Recurrence.tick/0},
      # Approval waits past their board's `wait_default_after`, resolved to
      # their proposal (#2096, see `Slipdock.WaitDefaults`).
      {"Wait defaults", fn -> Slipdock.WaitDefaults.tick() end},
      # Batched releases (#2835, see `Slipdock.Releases`): the age cap, and
      # running releases nothing has been heard of.
      {"Releases", fn -> Slipdock.Releases.tick() end},
      # Snoozed cards whose time has come (see `Slipdock.Snooze`).
      {"Waking snoozed cards", &Slipdock.Snooze.tick/0},
      # Uploaded files still to be read for text (see `Slipdock.OCR`).
      {"Document reading sweep", &Slipdock.OCR.sweep/0},
      # The health monitor runs every few minutes, not every tick (see
      # `Slipdock.Health`).
      {"Health monitor", &Slipdock.Health.tick/0}
    ]
  end

  defp guarded(label, fun, fallback \\ nil) do
    fun.()
  rescue
    exception ->
      Logger.error("#{label} failed: #{Exception.message(exception)}")
      fallback
  end

  defp interval,
    do: Slipdock.Config.get(:automations, [])[:interval] || @default_interval
end
