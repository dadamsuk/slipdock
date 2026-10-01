import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :slipdock, Slipdock.Repo,
  database: Path.expand("../slipdock_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :slipdock, SlipdockWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "2pev9Y+GxQmWYQIqfyR3xwH9SAMJcpY2qXaLTUKn5z3yZdlv5Xfji6cLLnjrtkue",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :slipdock, Slipdock.Mailer, adapter: Swoosh.Adapters.Test

# Automations: no background clock, and deliveries run inline so tests can
# assert on them (and stay inside the SQL sandbox).
config :slipdock, :automations, enabled: true, interval: :manual, async: false

config :slipdock, :base_url, "http://localhost:4002"

config :slipdock, :uploads_dir, Path.expand("../tmp/test_uploads", __DIR__)

# The search indexer never flushes on its own in tests; they call
# `Slipdock.Search.Indexer.flush/0` when they want the index brought up to date.
config :slipdock, :search, interval: :manual

# AI calls are answered by a Req.Test stub (see test/support/ai_stub.ex).
config :slipdock, :ai,
  api_key: "test-key",
  model: "test/model",
  key_file: Path.expand("../tmp/test_ai_keys.json", __DIR__),
  req_options: [plug: {Req.Test, Slipdock.AI}]

# Tests sign in as whoever they like, and a few of them post the form more
# than five times; the limiter has its own test, which turns it on.
config :slipdock, :rate_limit, enabled: false

# ...and they sign in brand-new addresses constantly, so sign-up is open here.
config :slipdock, :signups, open: true

config :slipdock,
  agentic_login: true,
  agentic_login_dir: Path.expand("../tmp/test_agentic_login", __DIR__)

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
