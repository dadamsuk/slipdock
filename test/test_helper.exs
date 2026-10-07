# Logs are shown for a failing test only: the ones the suite provokes on
# purpose (refused callbacks, origin banners, AI errors) are not news.
#
# assert_receive (and render_async, which uses its timeout) waits a second
# rather than 100ms: with the suite really running in parallel, an async task
# in a LiveView can take longer than that to come back.
ExUnit.start(capture_log: true, assert_receive_timeout: 1_000)
Slipdock.Config.start_overrides()
Slipdock.Fixtures.start_shortcuts()
Ecto.Adapters.SQL.Sandbox.mode(Slipdock.Repo, :manual)
