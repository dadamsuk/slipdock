defmodule Slipdock.Health.SchedulerPulseTest do
  # The scheduler records its own pulse on every tick (#1765), for /healthz.
  # Sync: the scheduler is one process for the node, so it needs the shared
  # sandbox to write this test's rows.
  use Slipdock.DataCase, async: false

  alias Slipdock.Health.Pulse

  test "a scheduler tick records the scheduler's pulse" do
    before = DateTime.utc_now(:second)
    Slipdock.Automations.Scheduler.run_now()
    assert %DateTime{} = at = Pulse.last("scheduler")
    assert DateTime.compare(at, before) in [:eq, :gt]
  end
end
