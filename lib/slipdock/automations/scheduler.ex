defmodule Slipdock.Automations.Scheduler do
  @moduledoc """
  The clock behind the time-based triggers: every `:interval` milliseconds
  (a minute by default) it asks `Slipdock.Automations.run_scheduled/1` to look
  for cards that have gone stale, come due or run late.

  Set `config :slipdock, :automations, interval: :manual` to keep it quiet,
  as the tests do. A test then drives it with `run_now/0` (a whole tick: the
  periodic jobs, then the rules) or calls `Slipdock.Automations.run_scheduled/1`
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
  """

  use GenServer

  require Logger

  @default_interval :timer.minutes(1)
  # Nothing is time-critical here, and a fresh boot shouldn't fire a day's
  # worth of rules while the database is still warming up.
  @startup_delay :timer.seconds(20)

  alias Slipdock.Automations.Scheduler.Leader

  @doc """
  Starts the scheduler. The node's own takes no options; a test starting
  others can give `:name`, `:jobs` (a list of `{label, fun}` run in place
  of the node's jobs and rules) and `:cluster_lock` (`false`, or the
  `{key1, key2}` advisory lock to lead by).
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Asks the running scheduler to tick now, and waits for it. Returns how
  many rules fired, or `:not_leader` when another node holds the lead.
  """
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :tick, 30_000)

  @impl true
  def init(opts) do
    if interval() != :manual, do: Process.send_after(self(), :tick, @startup_delay)

    lock = Keyword.get_lazy(opts, :cluster_lock, &configured_lock/0)
    leader = if lock, do: Leader.start_link(lock)

    {:ok, %{jobs: opts[:jobs], leader: leader, leading: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    {_result, state} = safe_tick(state)
    if interval() != :manual, do: Process.send_after(self(), :tick, interval())
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:tick, _from, state) do
    {result, state} = safe_tick(state)
    {:reply, result, state}
  end

  # Ticks only on the node that leads (see the moduledoc), and says so in
  # the log when that changes.
  defp safe_tick(state) do
    leader = Map.get(state, :leader)
    leading = leader == nil or Leader.leading?(leader)
    if leader && leading != Map.get(state, :leading), do: log_lead(leading)
    state = Map.put(state, :leading, leading)

    if leading, do: {tick(Map.get(state, :jobs)), state}, else: {:not_leader, state}
  end

  defp log_lead(true), do: Logger.info("Automation scheduler: this node leads the ticks")

  defp log_lead(false),
    do: Logger.info("Automation scheduler: another node leads the ticks; this one waits")

  # A job or rule that blows up must not take the scheduler with it, nor
  # skip the jobs after it: each runs through `guarded/3` on its own. Returns
  # how many rules fired.
  defp tick(nil) do
    run_jobs(jobs())
    guarded("Automation scheduler", &Slipdock.Automations.run_scheduled/0, 0)
  end

  defp tick(jobs) do
    run_jobs(jobs)
    0
  end

  defp configured_lock do
    if Keyword.get(Slipdock.Config.get(:automations, []), :cluster_lock, true),
      do: Leader.default_lock()
  end

  @doc false
  # The periodic jobs, in the order they run, before the rules themselves
  # (`Slipdock.Automations.run_scheduled/0`). A new one goes here, as
  # `{label, fun}`; `run_jobs/1` logs "<label> failed: ..." if it raises and
  # carries on with the next.
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

  @doc false
  # Runs each `{label, fun}` in turn; one that raises is logged and the rest
  # still run. Each is the server's own work, with nobody behind it, and
  # says so to `Slipdock.Policy` with its label (#3169).
  def run_jobs(jobs) do
    Enum.each(jobs, fn {label, fun} ->
      guarded(label, fn -> Slipdock.Policy.as_system("the scheduler: " <> label, fun) end)
    end)
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
