defmodule Slipdock.Posthog.ErrorTrackingTest do
  # The :logger handler is global: while one is attached, every error logged
  # anywhere in the run reaches it. So these run alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Slipdock.Posthog.ErrorTracking

  @posthog %{key: "phc_test", host: "https://eu.i.posthog.com"}

  ## payload/2 ---------------------------------------------------------------

  defp event(level, msg, meta \\ %{}) do
    %{level: level, msg: msg, meta: Map.merge(%{time: 1_791_000_000_000_000}, meta)}
  end

  describe "payload/2" do
    test "a plain Logger.error is an $exception carrying its message, no stack" do
      body = ErrorTracking.payload("phc_test", event(:error, {:string, "disk full"}))

      assert body["api_key"] == "phc_test"
      assert body["event"] == "$exception"
      assert body["distinct_id"] == "slipdock-server"
      assert body["timestamp"] == "2026-10-03T04:00:00.000000Z"

      props = body["properties"]
      assert props["$exception_level"] == "error"
      assert props["$process_person_profile"] == false
      assert props["$lib"] == "slipdock"

      assert [exception] = props["$exception_list"]
      assert exception["type"] == "Logger.error"
      assert exception["value"] == "disk full"
      assert exception["mechanism"] == %{"handled" => true, "type" => "generic"}
      assert exception["stacktrace"] == %{"type" => "raw", "frames" => []}
    end

    test "a crash with an exception names it and sends its frames, oldest first" do
      stacktrace = [
        {Slipdock.Boards, :get_board!, 2, [file: ~c"lib/slipdock/boards.ex", line: 42]},
        {Enum, :map, [[1], :fun], [file: ~c"lib/enum.ex", line: 1]}
      ]

      meta = %{crash_reason: {%RuntimeError{message: "boom"}, stacktrace}}
      body = ErrorTracking.payload("phc_test", event(:error, {:string, "crashed"}, meta))

      assert [exception] = body["properties"]["$exception_list"]
      assert exception["type"] == "RuntimeError"
      assert exception["value"] == "boom"
      assert exception["mechanism"]["handled"] == false

      assert [enum, ours] = exception["stacktrace"]["frames"]
      assert ours["function"] == "Slipdock.Boards.get_board!/2"
      assert ours["module"] == "Slipdock.Boards"
      assert ours["filename"] == "lib/slipdock/boards.ex"
      assert ours["lineno"] == 42
      assert ours["in_app"] == true
      assert ours["lang"] == "elixir"
      # Arguments in place of an arity are counted, never sent.
      assert enum["function"] == "Enum.map/2"
      assert enum["in_app"] == false
    end

    test "an exit that is not an exception is reported as one, with the log line" do
      meta = %{crash_reason: {{:shutdown, :db_gone}, []}}
      body = ErrorTracking.payload("phc_test", event(:error, {:string, "worker died"}, meta))

      assert [exception] = body["properties"]["$exception_list"]
      assert exception["type"] == "exit"
      assert exception["value"] == "{:shutdown, :db_gone}\n\nworker died"
    end

    test "a report-shaped message is formatted the way the console shows it" do
      body = ErrorTracking.payload("phc_test", event(:critical, {:report, %{what: :lost}}))

      assert [exception] = body["properties"]["$exception_list"]
      assert exception["type"] == "Logger.critical"
      assert exception["value"] == "what: lost"
      assert body["properties"]["$exception_level"] == "critical"
    end

    test "format-and-args messages are formatted" do
      body = ErrorTracking.payload("phc_test", event(:error, {~c"~p failed", [:sync]}))
      assert [%{"value" => "sync failed"}] = body["properties"]["$exception_list"]
    end

    test "a very long message is cut short" do
      long = String.duplicate("x", 10_000)
      body = ErrorTracking.payload("phc_test", event(:error, {:string, long}))

      [%{"value" => value}] = body["properties"]["$exception_list"]
      assert byte_size(value) < 4_100
      assert String.ends_with?(value, "…")
    end

    test "request id and the logging function come along when there are any" do
      meta = %{request_id: "F1x", mfa: {SlipdockWeb.BoardLive, :mount, 3}}
      body = ErrorTracking.payload("phc_test", event(:error, {:string, "x"}, meta))

      assert body["properties"]["request_id"] == "F1x"
      assert body["properties"]["source"] == "SlipdockWeb.BoardLive.mount/3"

      bare = ErrorTracking.payload("phc_test", event(:error, {:string, "x"}))
      refute Map.has_key?(bare["properties"], "request_id")
      refute Map.has_key?(bare["properties"], "source")
    end

    test "with no time in the metadata it is stamped now" do
      body = ErrorTracking.payload("phc_test", %{level: :error, msg: {:string, "x"}, meta: %{}})
      assert {:ok, _, 0} = DateTime.from_iso8601(body["timestamp"])
    end
  end

  ## The handler and reporter, end to end ------------------------------------

  defp start_reporter(settings) do
    name = :"posthog_reporter_#{System.unique_integer([:positive])}"
    pid = start_supervised!({ErrorTracking, name: name, settings: settings})
    Req.Test.allow(ErrorTracking, self(), pid)

    handler = :"posthog_handler_#{System.unique_integer([:positive])}"
    :ok = ErrorTracking.attach(handler, name)
    on_exit(fn -> ErrorTracking.detach(handler) end)

    test = self()

    Req.Test.stub(ErrorTracking, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{status: 1})
    end)

    pid
  end

  defp flush(pid), do: :sys.get_state(pid)

  test "with a key, a logged error is posted to PostHog's capture endpoint" do
    pid = start_reporter(fn -> @posthog end)

    capture_log(fn -> Logger.error("the import broke") end)
    flush(pid)

    assert_receive {:posted, "/i/v0/e/", body}
    assert body["api_key"] == "phc_test"
    assert body["event"] == "$exception"
    assert [%{"value" => "the import broke"}] = body["properties"]["$exception_list"]
  end

  test "a crashed task arrives as its exception, with a stack trace" do
    pid = start_reporter(fn -> @posthog end)

    capture_log(fn ->
      {:ok, task} = Task.start(fn -> raise ArgumentError, "bad card" end)
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, _, _, _}
      Process.sleep(50)
    end)

    flush(pid)

    assert_receive {:posted, _, body}
    assert [exception] = body["properties"]["$exception_list"]
    assert exception["type"] == "ArgumentError"
    assert exception["value"] == "bad card"
    assert exception["stacktrace"]["frames"] != []
  end

  test "warnings and below are not sent" do
    pid = start_reporter(fn -> @posthog end)

    capture_log(fn -> Logger.warning("only a warning") end)
    flush(pid)

    refute_receive {:posted, _, _}, 100
  end

  test "with no key configured nothing is sent" do
    pid = start_reporter(fn -> nil end)

    capture_log(fn -> Logger.error("unconfigured") end)
    flush(pid)

    refute_receive {:posted, _, _}, 100
  end

  test "settings that cannot be read send nothing and leave the reporter running" do
    pid = start_reporter(fn -> raise "no database" end)

    capture_log(fn -> Logger.error("while the database is down") end)
    flush(pid)

    refute_receive {:posted, _, _}, 100
    assert Process.alive?(pid)
  end

  test "a capture PostHog refuses, or that cannot connect, is dropped quietly" do
    pid = start_reporter(fn -> @posthog end)

    Req.Test.stub(ErrorTracking, fn conn -> Plug.Conn.send_resp(conn, 401, "nope") end)
    capture_log(fn -> Logger.error("refused") end)
    flush(pid)

    Req.Test.stub(ErrorTracking, &Req.Test.transport_error(&1, :econnrefused))
    capture_log(fn -> Logger.error("unreachable") end)
    flush(pid)

    assert Process.alive?(pid)
  end

  test "no more than 30 a minute are sent; the rest are dropped" do
    pid = start_reporter(fn -> @posthog end)

    # Straight to the reporter: through the logger, the mailbox guard could
    # drop some before the rate limit is what is being tested.
    for n <- 1..35 do
      GenServer.cast(pid, {:report, event(:error, {:string, "error #{n}"})})
    end

    state = flush(pid)

    for _ <- 1..30, do: assert_receive({:posted, _, _})
    refute_receive {:posted, _, _}, 100
    assert state.sent == 30
    assert state.dropped == 5
  end

  describe "log/2" do
    test "ignores events logged by the reporter itself" do
      name = :"posthog_self_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      assert :ok = ErrorTracking.log(event(:error, {:string, "x"}), %{config: %{target: name}})
      refute_received {:"$gen_cast", _}
    end

    test "with no reporter running it does nothing, and does not raise" do
      config = %{config: %{target: :posthog_nobody_here}}
      assert :ok = ErrorTracking.log(event(:error, {:string, "x"}), config)
    end

    test "casts the event to the reporter" do
      name = :"posthog_target_#{System.unique_integer([:positive])}"
      test = self()

      pid =
        spawn_link(fn ->
          receive do
            message -> send(test, {:got, message})
          end
        end)

      Process.register(pid, name)

      ErrorTracking.log(event(:error, {:string, "x"}), %{config: %{target: name}})
      assert_receive {:got, {:"$gen_cast", {:report, %{level: :error}}}}
    end
  end

  test "attach/2 is idempotent and detach/1 removes the handler" do
    id = :"posthog_attach_#{System.unique_integer([:positive])}"

    assert :ok = ErrorTracking.attach(id, :nowhere)
    assert :ok = ErrorTracking.attach(id, :nowhere)
    assert id in :logger.get_handler_ids()

    assert :ok = ErrorTracking.detach(id)
    refute id in :logger.get_handler_ids()
  end
end
