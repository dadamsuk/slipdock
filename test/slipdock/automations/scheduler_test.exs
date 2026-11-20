defmodule Slipdock.Automations.SchedulerTest do
  # Every periodic job runs through one guard (#1936): a job that raises is
  # logged under its label and the other jobs still run. Each runs as its own
  # task (#3497), so a slow one holds up nothing but itself, and one that
  # runs past its timeout is stopped.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Slipdock.Automations.Scheduler

  defp scheduler(jobs, opts \\ []) do
    start_supervised!(
      {Scheduler, [name: nil, cluster_lock: false, jobs: jobs] ++ opts},
      id: make_ref()
    )
  end

  test "a job that raises is logged and the other jobs still run" do
    test = self()

    s =
      scheduler([
        {"First job", fn -> send(test, :first) end},
        {"Broken job", fn -> raise "kaboom" end},
        {"Later job", fn -> send(test, :later) end}
      ])

    log = capture_log(fn -> assert 0 = Scheduler.run_now(s) end)

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

    log = capture_log(fn -> Scheduler.run_now(scheduler(jobs)) end)

    for n <- 1..3 do
      assert_received {:ran, ^n}
      assert log =~ "Job #{n} failed: bad #{n}"
    end
  end

  test "a job that exits is logged and the scheduler carries on" do
    s = scheduler([{"Exiting job", fn -> exit(:gone) end}])
    log = capture_log(fn -> assert 0 = Scheduler.run_now(s) end)
    assert log =~ "Exiting job failed"
    assert Process.alive?(s)
  end

  test "no jobs is nothing to do" do
    assert 0 = Scheduler.run_now(scheduler([]))
  end

  test "a slow job doesn't hold up the start of the next" do
    test = self()

    s =
      scheduler([
        {"Slow job",
         fn ->
           send(test, {:slow_started, self()})
           receive do: (:go -> send(test, :slow_done))
         end},
        {"Next job", fn -> send(test, :next_ran) end}
      ])

    caller = Task.async(fn -> Scheduler.run_now(s) end)

    # The next job runs while the slow one is still waiting.
    assert_receive {:slow_started, slow}
    assert_receive :next_ran
    refute_received :slow_done
    # And the scheduler still answers.
    assert %{running: running} = :sys.get_state(s)
    assert map_size(running) == 1
    # But run_now answers only once both are done.
    assert Task.yield(caller, 50) == nil

    send(slow, :go)
    assert_receive :slow_done
    assert Task.await(caller) == 0
  end

  test "run_now answers once the tick's jobs are done, not before" do
    # The answer comes only when the job is let go: no call timeout of its
    # own cuts it short (the job's timeout bounds it).
    test = self()

    s =
      scheduler([
        {"Slow job",
         fn ->
           send(test, {:slow_started, self()})
           receive do: (:go -> :ok)
         end}
      ])

    caller = Task.async(fn -> Scheduler.run_now(s) end)
    assert_receive {:slow_started, slow}
    assert Task.yield(caller, 50) == nil
    send(slow, :go)
    assert Task.await(caller) == 0
  end

  test "a job past its timeout is stopped and logged, and the tick still answers" do
    test = self()

    s =
      scheduler(
        [
          {"Stuck job",
           fn ->
             send(test, {:stuck, self()})
             receive do: (:never -> :ok)
           end}
        ],
        job_timeout: 50
      )

    log = capture_log(fn -> assert 0 = Scheduler.run_now(s) end)

    assert_received {:stuck, pid}
    refute Process.alive?(pid)
    assert log =~ "Stuck job failed: still running after"
  end

  test "a job still running from an earlier tick is skipped, not started twice" do
    test = self()

    s =
      scheduler([
        {"Slow job",
         fn ->
           send(test, {:slow_started, self()})
           receive do: (:go -> :ok)
         end}
      ])

    send(s, :tick)
    assert_receive {:slow_started, slow}

    log = capture_log(fn -> assert 0 = Scheduler.run_now(s) end)
    assert log =~ "Slow job is still running from an earlier tick"
    refute_received {:slow_started, _}

    send(slow, :go)
  end

  test "no more than max_jobs run at once" do
    test = self()

    jobs =
      for n <- 1..3 do
        {"Job #{n}",
         fn ->
           send(test, {:started, n, self()})
           receive do: (:go -> :ok)
         end}
      end

    s = scheduler(jobs, max_jobs: 2)
    caller = Task.async(fn -> Scheduler.run_now(s) end)

    assert_receive {:started, 1, one}
    assert_receive {:started, 2, two}
    refute_receive {:started, 3, _}, 50

    send(one, :go)
    assert_receive {:started, 3, three}
    send(two, :go)
    send(three, :go)
    assert Task.await(caller) == 0
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
             "Releases",
             "Waking snoozed cards",
             "Document reading sweep",
             "Health monitor"
           ]

    assert Enum.all?(Scheduler.jobs(), fn {_label, fun} -> is_function(fun, 0) end)
  end
end
