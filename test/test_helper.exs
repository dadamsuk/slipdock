# Logs are shown for a failing test only: the ones the suite provokes on
# purpose (refused callbacks, origin banners, AI errors) are not news.
#
# assert_receive (and render_async, which uses its timeout) waits up to five
# seconds rather than 100ms: with the suite really running in parallel, an
# async task in a LiveView can take longer than that to come back. A second
# was not enough on a loaded machine either (#2828: render_async timed out in
# the skill registry, quick note and header quick add tests, each passing
# alone). Only a failing assert waits that long; a passing one returns as soon
# as the message comes. `test/slipdock/test_helper_config_test.exs` holds it.
#
# With TEST_TIMINGS_FILE set (CI does), Slipdock.TestTimings also writes each
# test file's runtime there, which balances CI's partitions (#1858).
formatters =
  Application.get_env(:ex_unit, :formatters, [ExUnit.CLIFormatter]) ++
    if(System.get_env("TEST_TIMINGS_FILE"), do: [Slipdock.TestTimings], else: [])

ExUnit.start(capture_log: true, assert_receive_timeout: 5_000, formatters: formatters)
Slipdock.Config.start_overrides()
Slipdock.BoardKeyClaims.start()
Ecto.Adapters.SQL.Sandbox.mode(Slipdock.Repo, :manual)

# Two runs at once against one database wait on each other's rows (#830).
{:ok, _} = Slipdock.TestRunLock.hold()
