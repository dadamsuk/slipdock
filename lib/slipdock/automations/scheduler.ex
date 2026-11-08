defmodule Slipdock.Automations.Scheduler do
  @moduledoc """
  The clock behind the time-based triggers: every `:interval` milliseconds
  (a minute by default) it asks `Slipdock.Automations.run_scheduled/1` to look
  for cards that have gone stale, come due or run late.

  Set `config :slipdock, :automations, interval: :manual` to keep it quiet and
  drive it from `tick/1` instead, as the tests do.
  """

  use GenServer

  require Logger

  @default_interval :timer.minutes(1)
  # Nothing is time-critical here, and a fresh boot shouldn't fire a day's
  # worth of rules while the database is still warming up.
  @startup_delay :timer.seconds(20)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs the scheduled rules once, synchronously. Returns how many fired."
  def tick(now \\ DateTime.utc_now()), do: Slipdock.Automations.run_scheduled(now)

  @doc "Asks the running scheduler to tick now, and waits for it."
  def run_now, do: GenServer.call(__MODULE__, :tick, 30_000)

  @impl true
  def init(_opts) do
    if interval() != :manual, do: Process.send_after(self(), :tick, @startup_delay)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    safe_tick()
    if interval() != :manual, do: Process.send_after(self(), :tick, interval())
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, safe_tick(), state}

  # A job or rule that blows up must not take the scheduler with it, nor
  # skip the jobs after it: each runs through `guarded/3` on its own.
  defp safe_tick do
    run_jobs(jobs())
    guarded("Automation scheduler", &tick/0, 0)
  end

  @doc false
  # The periodic jobs, in the order they run, before the rules themselves
  # (`tick/0`). A new one goes here, as `{label, fun}`; `run_jobs/1` logs
  # "<label> failed: ..." if it raises and carries on with the next.
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
  # still run.
  def run_jobs(jobs), do: Enum.each(jobs, fn {label, fun} -> guarded(label, fun) end)

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
