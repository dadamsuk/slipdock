defmodule Slipdock.SandboxQueueTest do
  # A test shares one sandboxed connection with every process working for it —
  # a LiveView, and the tasks Ecto starts to run a preload in parallel. Under a
  # loaded CI runner one of those can wait its turn for longer than the pool's
  # default queue target (#468), and DBConnection drops it rather than letting
  # it wait. The test repo is configured to wait instead.
  use Slipdock.DataCase, async: true

  alias Slipdock.Repo

  test "a query waiting behind a slow one on the shared connection still runs" do
    slow = Task.async(fn -> Repo.query!("SELECT pg_sleep(1.5)") end)
    # Let the slow query take the connection first.
    Process.sleep(100)

    waiting = Task.async(fn -> Repo.query!("SELECT 1") end)

    assert %{rows: [[1]]} = Task.await(waiting, 5_000)
    assert %{num_rows: 1} = Task.await(slow, 5_000)
  end

  test "the test repo waits seconds, not milliseconds, for the connection" do
    config = Repo.config()
    assert is_integer(config[:queue_target]) and config[:queue_target] >= 5_000
    assert config[:queue_interval] >= config[:queue_target]
  end
end
