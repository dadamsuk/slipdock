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

  # A rule that blows up must not take the scheduler with it. The same clock
  # takes back runner jobs whose lease has run out (see `Slipdock.Runners`).
  defp safe_tick do
    sweep_runner_jobs()
    resume_captures()
    tick()
  rescue
    exception ->
      Logger.error("Automation scheduler failed: #{Exception.message(exception)}")
      0
  end

  defp sweep_runner_jobs do
    Slipdock.Runners.sweep()
  rescue
    exception -> Logger.error("Runner job sweep failed: #{Exception.message(exception)}")
  end

  # Meeting captures a restart or a crash left half-read (see
  # `Slipdock.Meetings.Pipeline`).
  defp resume_captures do
    Slipdock.Meetings.Pipeline.sweep()
    Slipdock.Meetings.Audio.purge_expired()
  rescue
    exception -> Logger.error("Meeting capture sweep failed: #{Exception.message(exception)}")
  end

  defp interval,
    do: Slipdock.Config.get(:automations, [])[:interval] || @default_interval
end
