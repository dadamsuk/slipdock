defmodule Slipdock.AwaitLogTest do
  use ExUnit.Case, async: true

  require Logger

  alias Slipdock.AwaitLog

  describe "assert_logged/3" do
    test "waits for a line another process writes after the test moves on" do
      log = AwaitLog.watch()
      test = self()

      # Logs only once the test has said it has moved on: a capture_log
      # around the start would have closed by then.
      Task.start(fn ->
        assert_receive :go
        Logger.error("the lookup blew up late")
        send(test, :logged)
      end)
      |> then(fn {:ok, pid} -> send(pid, :go) end)

      assert AwaitLog.assert_logged(log, "blew up late") =~ "the lookup blew up late"
      assert_receive :logged
    end

    test "takes a regex, and skips lines that don't match" do
      log = AwaitLog.watch()
      Logger.error("first, unrelated")
      Logger.error("job 42 failed")

      assert AwaitLog.assert_logged(log, ~r/job \d+ failed/) == "job 42 failed"
    end

    test "fails in time, listing the lines it saw" do
      log = AwaitLog.watch()
      Logger.error("something else")

      error =
        assert_raise ExUnit.AssertionError, fn ->
          AwaitLog.assert_logged(log, "never logged", 50)
        end

      assert error.message =~ ~s(no log line matching "never logged")
      assert error.message =~ "something else"
    end

    test "doesn't see another test's process" do
      log = AwaitLog.watch()
      # Not started by this test: no $callers leading back to it.
      spawn(fn -> Logger.error("from a stranger") end)

      assert_raise ExUnit.AssertionError, fn ->
        AwaitLog.assert_logged(log, "from a stranger", 200)
      end
    end
  end

  describe "refute_logged/2" do
    test "passes on nothing matching, and fails on a line that does" do
      log = AwaitLog.watch()
      Logger.error("all is well")
      # The handler runs in the logging process, so the line is here now.
      assert AwaitLog.refute_logged(log, "blew up") == :ok

      Logger.error("it blew up")

      assert_raise ExUnit.AssertionError, ~r/no log line matching "blew up"/, fn ->
        AwaitLog.refute_logged(log, "blew up")
      end

      # The lines stay for an assert after it.
      assert AwaitLog.assert_logged(log, "it blew up") == "it blew up"
    end
  end
end
