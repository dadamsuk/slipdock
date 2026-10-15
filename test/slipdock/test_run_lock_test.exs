defmodule Slipdock.TestRunLockTest do
  @moduledoc """
  The lock that keeps two `mix test` runs off one database at once (#830).
  Each test takes a key of its own, so none waits on the suite's lock or on
  another test's.
  """
  use ExUnit.Case, async: true

  alias Slipdock.TestRunLock

  defp key, do: System.unique_integer([:positive])

  # Whether somebody else could take the lock right now, asked from a
  # connection of its own and let go again straight away.
  defp free?(key) do
    {:ok, conn} =
      Slipdock.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Postgrex.start_link()

    %{rows: [[free?]]} =
      Postgrex.query!(conn, "SELECT pg_try_advisory_lock(7401, $1)", [key])

    GenServer.stop(conn)
    free?
  end

  # Returns once somebody is queued for the lock, as Postgres sees it.
  defp await_waiter(key) do
    {:ok, conn} =
      Slipdock.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Postgrex.start_link()

    waiting? = fn ->
      %{rows: [[n]]} =
        Postgrex.query!(
          conn,
          "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND classid = 7401 AND objid = $1 AND NOT granted",
          [key]
        )

      n > 0
    end

    Stream.repeatedly(waiting?) |> Enum.find(& &1)
    GenServer.stop(conn)
  end

  test "this run holds the suite's lock, so a second run would wait" do
    refute free?(0)
  end

  test "a free lock is taken without waiting, and held until its connection goes" do
    key = key()
    test = self()
    {:ok, conn} = TestRunLock.hold(key: key, on_wait: &send(test, {:waited, &1}))

    refute_received {:waited, _}
    refute free?(key)

    GenServer.stop(conn)
    assert free?(key)
  end

  test "a second holder says it is waiting, naming the database, and gets the lock once the first lets go" do
    key = key()
    test = self()
    {:ok, first} = TestRunLock.hold(key: key)

    second =
      Task.async(fn -> TestRunLock.hold(key: key, on_wait: &send(test, {:waited, &1})) end)

    database = Slipdock.Repo.config()[:database]
    assert_receive {:waited, ^database}
    await_waiter(key)
    assert Task.yield(second, 0) == nil

    GenServer.stop(first)
    assert {:ok, conn} = Task.await(second)
    refute free?(key)
    GenServer.stop(conn)
  end

  test "a different key doesn't wait" do
    {:ok, first} = TestRunLock.hold(key: key())
    test = self()
    {:ok, other} = TestRunLock.hold(key: key(), on_wait: &send(test, {:waited, &1}))

    refute_received {:waited, _}
    Enum.each([first, other], &GenServer.stop/1)
  end

  test "the wait is announced on stderr by default" do
    key = key()
    {:ok, first} = TestRunLock.hold(key: key)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        second = Task.async(fn -> TestRunLock.hold(key: key) end)
        await_waiter(key)
        GenServer.stop(first)
        {:ok, conn} = Task.await(second)
        GenServer.stop(conn)
      end)

    assert output =~ "Another mix test run is using #{Slipdock.Repo.config()[:database]}"
    assert output =~ "MIX_TEST_PARTITION"
  end
end
