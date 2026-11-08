defmodule Slipdock.Automations.SchedulerTest do
  # Every periodic job runs through one guard (#1936): a job that raises is
  # logged under its label and the jobs after it still run.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Slipdock.Automations.Scheduler

  test "a job that raises is logged and the jobs after it still run" do
    test = self()

    jobs = [
      {"First job", fn -> send(test, :first) end},
      {"Broken job", fn -> raise "kaboom" end},
      {"Later job", fn -> send(test, :later) end}
    ]

    log = capture_log(fn -> assert :ok = Scheduler.run_jobs(jobs) end)

    assert log =~ "Broken job failed: kaboom"
    refute log =~ "First job failed"
    refute log =~ "Later job failed"
    assert_received :first
    assert_received :later
  end

  test "every job failing still runs them all" do
    test = self()

    jobs =
      for n <- 1..3 do
        {"Job #{n}",
         fn ->
           send(test, {:ran, n})
           raise ArgumentError, "bad #{n}"
         end}
      end

    log = capture_log(fn -> Scheduler.run_jobs(jobs) end)

    for n <- 1..3 do
      assert_received {:ran, ^n}
      assert log =~ "Job #{n} failed: bad #{n}"
    end
  end

  test "no jobs is nothing to do" do
    assert :ok = Scheduler.run_jobs([])
  end

  test "the scheduler's jobs run in their order, the pulse first" do
    labels = Enum.map(Scheduler.jobs(), &elem(&1, 0))

    assert labels == [
             "Scheduler pulse",
             "Runner job sweep",
             "Wiki change log prune",
             "Autosave prune",
             "Overseer",
             "Recurring cards",
             "Wait defaults",
             "Waking snoozed cards",
             "Document reading sweep",
             "Health monitor"
           ]

    assert Enum.all?(Scheduler.jobs(), fn {_label, fun} -> is_function(fun, 0) end)
  end
end
