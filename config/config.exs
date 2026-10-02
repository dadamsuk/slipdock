# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :slipdock,
  ecto_repos: [Slipdock.Repo],
  generators: [timestamp_type: :utc_datetime]

# Where files attached to cards are stored. Overridden in test.exs; set
# SLIPDOCK_UPLOADS_DIR at runtime to move it (see runtime.exs).
config :slipdock, :uploads_dir, Path.expand("../priv/uploads", __DIR__)

# LLM features (chat, narrative generator, AI edits, quick add) go through
# OpenRouter. The API key comes from OPENROUTER_API_KEY (or a .env file, see
# runtime.exs). Without a key the features stay hidden.
# SLIPDOCK_AI_MODEL picks another model, SLIPDOCK_AI_QUICK_MODEL the one the
# header's quick add uses (it wants latency over depth).
# This app is AGPL-3.0: anyone using it over a network is entitled to its
# source, so the UI links to it. Point this at your own fork if you run one
# (SLIPDOCK_SOURCE_URL).
config :slipdock, :source_url, "https://github.com/dadamsuk/slipdock"

config :slipdock, :ai,
  base_url: "https://openrouter.ai/api/v1",
  model: "google/gemini-2.5-flash-lite",
  quick_model: nil,
  # Semantic search (see Slipdock.Search): the embedding model, and how many
  # dimensions to ask it for. text-embedding-3-* are Matryoshka models, so
  # 768 is the full 1536-dimension vector truncated — half the storage for
  # almost none of the quality. SLIPDOCK_AI_EMBED_MODEL / _DIMENSIONS override.
  # Changing either means a full `mix slipdock.reindex --all`.
  embed_model: "openai/text-embedding-3-small",
  embed_dimensions: 768,
  # A key here is shared by everyone on the server; normally there is none
  # and each person brings their own (see `Slipdock.AI.Keys`).
  api_key: nil,
  # Where those per-user keys live: one JSON file, 0600, outside the
  # database. SLIPDOCK_AI_KEY_FILE moves it.
  key_file: "ai_keys.json",
  system_user: nil

# Who may get an account (see `Slipdock.Accounts.signup_allowed?/1`). The
# default is closed: the first address to sign in claims an empty instance,
# after which only people already here, addresses in `:allow`, or anyone at a
# domain in `:allow`, can sign in. SLIPDOCK_OPEN_SIGNUP=true opens it to all
# comers, which only makes sense behind a network boundary of your own.
# Read only by `Slipdock.Settings.seed/0`, to carry an existing install's
# registration policy into the settings row on first boot. Nothing else looks
# at it; `signup_mode` in `:settings` below is the live setting.
config :slipdock, :signups, open: false, allow: []

# Defaults for this server's own settings (`Slipdock.Settings`) *before* the
# setup wizard has been filled in, and the values the row is seeded from on
# first boot. The database wins once anything has been saved: changing these on
# a server that has already been set up does nothing.
#
#   signup_mode             :open | :allowlist | :approval | :closed
#   free_card_limit         non-archived cards allowed on one person's own
#                           boards; nil for no limit, which is what a
#                           self-hosted install wants
#   user_directory          :instance (everyone here shows up in pickers) or
#                           :shared_only (only people you share something with)
#   invites_create_accounts whether sharing with an unknown address makes an
#                           account for it
#   setup_completed         skip the wizard entirely (the test environment)
config :slipdock, :settings, []

# The sign-in form's counters (see `Slipdock.RateLimit`). `enabled: false` turns
# the limit off everywhere.
config :slipdock, :rate_limit, enabled: true

# Automation rules (see Slipdock.Automations). `enabled: false` turns every
# rule off; `interval` is how often the time-based triggers are checked;
# `async: false` sends the emails and webhooks inline (the test env does).
config :slipdock, :automations,
  enabled: true,
  interval: :timer.minutes(1),
  async: true

# Configure the endpoint
config :slipdock, SlipdockWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SlipdockWeb.ErrorHTML, json: SlipdockWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Slipdock.PubSub,
  live_view: [signing_salt: "HvSivEhn"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  slipdock: [
    args:
      ~w(js/app.js js/theme.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  slipdock: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Mail: the Local adapter keeps sent mail in memory and shows it at /dev/mailbox.
# runtime.exs switches to SMTP when SLIPDOCK_SMTP_HOST is set.
config :slipdock, Slipdock.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false
config :slipdock, :mail_from, {"Slipdock", "slipdock@localhost"}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
