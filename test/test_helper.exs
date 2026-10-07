# Logs are shown for a failing test only: the ones the suite provokes on
# purpose (refused callbacks, origin banners, AI errors) are not news.
ExUnit.start(capture_log: true)
Slipdock.Config.start_overrides()
Ecto.Adapters.SQL.Sandbox.mode(Slipdock.Repo, :manual)
