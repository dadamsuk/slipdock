defmodule Slipdock.Automations.SchedulerLeaderTest do
  # Two nodes' schedulers against one database run a tick once (#3496): the
  # one holding the advisory lock ticks, the other skips, and a leader that
  # dies lets the other take over. Each test leads by a lock of its own, so
  # it never meets the node's scheduler or another test.
  use ExUnit.Case, async: true

  # The schedulers log when they take or lose the lead.
  @moduletag :capture_log

  alias Slipdock.Automations.Scheduler

  defp lock, do: {7_401, 1_000 + System.unique_integer([:positive])}

  defp scheduler(name, lock) do
    test = self()

    {:ok, pid} =
      Scheduler.start_link(
        name: nil,
        cluster_lock: lock,
        jobs: [{"Count", fn -> send(test, {:ran, name}) end}]
      )

    pid
  end

  # Ticks each; the first waits for its connection to come up (a checkout
  # waits for the connection rather than failing).
  defp tick(pids), do: Enum.map(pids, &Scheduler.run_now/1)

  test "two schedulers on one lock run a tick once" do
    lock = lock()
    a = scheduler(:a, lock)
    b = scheduler(:b, lock)

    assert Enum.sort(tick([a, b])) == [0, :not_leader]
    assert_received {:ran, first}
    refute_received {:ran, _}

    # And the same one leads the next tick.
    assert Enum.sort(tick([a, b])) == [0, :not_leader]
    assert_received {:ran, ^first}
    refute_received {:ran, _}
  end

  test "a leader that dies lets the other take over" do
    lock = lock()
    a = scheduler(:a, lock)
    assert [0] = tick([a])
    assert_received {:ran, :a}

    b = scheduler(:b, lock)
    assert Scheduler.run_now(b) == :not_leader
    refute_received {:ran, :b}

    # The node dies: its connection goes with it.
    {conn, _lock} = :sys.get_state(a).leader
    ref = Process.monitor(conn)
    Process.unlink(a)
    Process.exit(a, :kill)
    assert_receive {:DOWN, ^ref, :process, ^conn, _}

    # Postgres ends the session as it sees the socket close: wait for that
    # by taking the lock and letting it go, on a connection of the test's.
    {key1, key2} = lock

    {:ok, waiter} =
      Postgrex.start_link(
        Keyword.merge(Keyword.drop(Slipdock.Repo.config(), [:pool, :name]), pool_size: 1)
      )

    Postgrex.query!(waiter, "SELECT pg_advisory_lock($1::int4, $2::int4)", [key1, key2])
    Postgrex.query!(waiter, "SELECT pg_advisory_unlock($1::int4, $2::int4)", [key1, key2])

    assert [0] = tick([b])
    assert_received {:ran, :b}
  end

  test "with the lock off every scheduler ticks" do
    test = self()

    for name <- [:a, :b] do
      {:ok, pid} =
        Scheduler.start_link(
          name: nil,
          cluster_lock: false,
          jobs: [{"Count", fn -> send(test, {:ran, name}) end}]
        )

      assert Scheduler.run_now(pid) == 0
    end

    assert_received {:ran, :a}
    assert_received {:ran, :b}
  end
end
