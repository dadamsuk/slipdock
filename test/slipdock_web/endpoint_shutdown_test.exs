defmodule SlipdockWeb.EndpointShutdownTest do
  # A deploy stops the old container with `docker stop`, which waits 10s and
  # then kills it. The server must give up on requests still in flight (a
  # runner's 25s claim is always one) well inside that, or every deploy is 10s
  # of 502s before the new container even starts.
  use ExUnit.Case, async: true

  # Docker's default grace period before it sends SIGKILL.
  @docker_stop_timeout 10_000

  # Long enough for a loaded machine to accept a connection, well inside
  # ExUnit's 60s.
  @setup_timeout 15_000

  # A request that never finishes by itself, like a long-polled claim.
  defmodule Hang do
    @behaviour Plug
    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      send(test_pid, :in_flight)
      Process.sleep(:infinity)
      conn
    end
  end

  defp configured_options do
    Application.fetch_env!(:slipdock, SlipdockWeb.Endpoint)[:http][:thousand_island_options]
  end

  test "the endpoint's shutdown timeout is set, and inside docker's grace period" do
    timeout = configured_options()[:shutdown_timeout]

    assert is_integer(timeout)
    assert timeout > 0
    # With room left over for the rest of the app to stop.
    assert timeout <= @docker_stop_timeout - 5_000
  end

  test "a server with an open request stops within the configured timeout" do
    timeout = configured_options()[:shutdown_timeout]

    {:ok, server} =
      Bandit.start_link(
        plug: {Hang, self()},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        thousand_island_options: configured_options()
      )

    Process.unlink(server)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "POST /api/runner/claim HTTP/1.1\r\nhost: x\r\n\r\n")
    # Only setup: the accept and the handler's spawn. On a loaded machine (the
    # full suite beside `mix pre_push`) that alone took over 2s (#2830).
    assert_receive :in_flight, @setup_timeout

    ref = Process.monitor(server)
    started = System.monotonic_time(:millisecond)
    stopper = Task.async(fn -> GenServer.stop(server, :shutdown, :infinity) end)

    assert_receive {:DOWN, ^ref, :process, ^server, _}, @docker_stop_timeout
    elapsed = System.monotonic_time(:millisecond) - started
    Task.await(stopper)

    # It waited for the request rather than dropping it at once...
    assert elapsed >= timeout - 250
    # ...and then gave up on it, inside docker's grace period and instead of
    # Bandit's default 15s, with room for a loaded machine to stop the server.
    assert elapsed < timeout + 4_000
    assert {:error, _} = :gen_tcp.recv(socket, 0, 1_000)
  end
end
