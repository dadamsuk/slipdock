defmodule Slipdock.AwaitLog do
  @moduledoc """
  Assert a log line another process writes, without racing it (#3163).

  `ExUnit.CaptureLog.capture_log/2` and `with_log/2` keep only what is logged
  before their function returns. A line written by another process (a
  LiveView's async task that crashes, a GenServer, a `Task`) can arrive after
  that, and the capture comes back empty while the page already shows the
  error: #3154 and #3155 in `ai_key_live_test.exs`, the coverage and
  error-tracking races before them. So a test of such a line watches for it
  and waits:

      log = AwaitLog.watch()
      render_click(button)
      AwaitLog.assert_logged(log, "the lookup blew up")

  `watch/0` adds a `:logger` handler for this test alone, removed when it
  ends. It keeps the lines logged by the test's own process and by the
  processes it started (anything with the test in its `$callers`: a
  LiveView's tasks, `Task.async`, `start_supervised!`), so another async
  test logging the same words can't satisfy it. `assert_logged/3` waits up to
  `assert_receive_timeout` (5 s here) for a line that matches, and returns as
  soon as one does. `refute_logged/3` checks nothing matched so far.

  A log line is only seen if it gets past the primary level (`:warning` in
  `config/test.exs`).
  """
  import ExUnit.Assertions

  @doc """
  Starts keeping this test's log lines; returns the handle the asserts take.
  """
  def watch do
    id = :"await_log_#{System.unique_integer([:positive])}"

    config = %{
      test: self(),
      formatter: Logger.Formatter.new(format: "$message", colors: [enabled: false])
    }

    :ok = :logger.add_handler(id, __MODULE__, %{level: :all, config: config})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
    id
  end

  @doc """
  Waits for a line matching `pattern` (a string it contains, or a regex), and
  returns that line. Fails with every line seen if none comes in time.
  """
  def assert_logged(id, pattern, timeout \\ nil) do
    timeout = timeout || ExUnit.configuration()[:assert_receive_timeout] || 100
    deadline = System.monotonic_time(:millisecond) + timeout
    await(id, pattern, deadline, [])
  end

  @doc """
  Fails if a line matching `pattern` has been logged so far. Lines already
  received stay in the mailbox for a later `assert_logged/3`.
  """
  def refute_logged(id, pattern) do
    seen = seen(id)
    hits = Enum.filter(seen, &matches?(&1, pattern))
    assert hits == [], "expected no log line matching #{inspect(pattern)}, got: #{inspect(hits)}"
    :ok
  end

  defp seen(id) do
    {:messages, messages} = Process.info(self(), :messages)
    for {^id, line} <- messages, do: line
  end

  defp await(id, pattern, deadline, seen) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^id, line} ->
        if matches?(line, pattern), do: line, else: await(id, pattern, deadline, [line | seen])
    after
      left ->
        flunk(
          "no log line matching #{inspect(pattern)} came in time. Lines seen:\n" <>
            Enum.map_join(Enum.reverse(seen), "\n", &("  " <> &1))
        )
    end
  end

  defp matches?(line, %Regex{} = regex), do: Regex.match?(regex, line)
  defp matches?(line, text) when is_binary(text), do: String.contains?(line, text)

  @doc false
  # The `:logger` handler: runs in the process that logs.
  def log(event, %{id: id, config: %{test: test, formatter: {module, formatter}}}) do
    if test == self() or test in List.wrap(Process.get(:"$callers")) do
      line = event |> module.format(formatter) |> IO.chardata_to_string()
      send(test, {id, line})
    end

    :ok
  end

  @doc false
  def adding_handler(config), do: {:ok, config}
end
