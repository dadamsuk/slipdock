import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
#
# Postgres lets the sandbox give every async test its own connection and its
# own transaction, so `async: true` is free here — which is the whole reason
# the suite can run in parallel at all. `pool_size` therefore wants to be at
# least as large as `System.schedulers_online()`.
config :slipdock, Slipdock.Repo,
  url:
    System.get_env("TEST_DATABASE_URL") ||
      "postgres://postgres:postgres@localhost:5434/slipdock_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool_size: System.schedulers_online() * 2,
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

# Mail settings are editable in the app now, and `Slipdock.Mailer` builds its
# adapter from them per delivery. Not here: a test that saved an SMTP host
# would otherwise post mail to the internet.
config :slipdock, :mailer_from_settings, false

# Automations: no background clock, and deliveries run inline so tests can
# assert on them (and stay inside the SQL sandbox). Callbacks go to a
# `Req.Test` stub rather than out of the machine.
config :slipdock, :automations,
  enabled: true,
  interval: :manual,
  async: false,
  req_options: [plug: {Req.Test, Slipdock.Automations.Notifier}]

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

# ...and they sign in brand-new addresses constantly, so sign-up is open here,
# and this instance counts as already set up so the wizard does not intercept
# every request. Tests about registration or the wizard override these per test.

config :slipdock, :settings, signup_mode: :open, setup_completed: true

# Boot does not seed the settings row here: it would run before the first
# sandbox checkout and so write a row that survives every rollback. The seeding
# tests call `Slipdock.Settings.seed/0` themselves.
config :slipdock, :seed_settings, false

# The settings row is cached in :persistent_term, which outlives the sandbox
# transaction a test writes it in — so one test's settings would leak into the
# next. Read it from the database every time here instead.
config :slipdock, :settings_cache, false

# The "Getting Started" tour board (see `Slipdock.Onboarding`) is built on a
# first sign-in, which would otherwise land on 19 cards and a filled embedding
# queue in every test that signs somebody in by magic link. The tests that are
# about it switch it on for themselves.
config :slipdock, :welcome_board, false

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
