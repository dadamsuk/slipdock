import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kanban start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# The project was renamed from Kanban to Slipdock and its variables went with
# it. Every old `KANBAN_*` name still works: it fills in the `SLIPDOCK_*` one
# if that is unset, so an existing .env keeps a server booting. Run on both
# sides of the .env load, since SLIPDOCK_ENV_FILE is read before it and the
# file itself may hold old names. Warned once, and due for removal a release
# from now.
adopt_legacy_env = fn ->
  for {"KANBAN_" <> rest = old, value} <- System.get_env(),
      new = "SLIPDOCK_" <> rest,
      is_nil(System.get_env(new)) do
    System.put_env(new, value)
    old
  end
end

legacy_from_env = adopt_legacy_env.()

# Secrets may live in a .env file (KEY=value lines) rather than the process
# environment: SLIPDOCK_ENV_FILE, else .env in the project or its parent
# directory. Variables already set in the environment win.
env_files =
  [
    System.get_env("SLIPDOCK_ENV_FILE"),
    Path.expand("../.env", __DIR__),
    Path.expand("../../.env", __DIR__)
  ]
  |> Enum.reject(&is_nil/1)

for path <- env_files, File.regular?(path) do
  path
  |> File.read!()
  |> String.split("\n")
  |> Enum.each(fn line ->
    with line <- String.trim(line),
         false <- line == "" or String.starts_with?(line, "#"),
         [key, value] <- String.split(String.replace_prefix(line, "export ", ""), "=", parts: 2),
         key <- String.trim(key),
         nil <- System.get_env(key) do
      value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
      System.put_env(key, value)
    else
      _ -> :ok
    end
  end)
end

legacy_env = Enum.uniq(legacy_from_env ++ adopt_legacy_env.())

if legacy_env != [] do
  IO.puts(
    :stderr,
    "warning: #{length(legacy_env)} KANBAN_* environment variable(s) are still in use " <>
      "(#{Enum.join(Enum.sort(legacy_env), ", ")}). They have been read as their SLIPDOCK_* " <>
      "equivalents. Rename them in your .env — the fallback goes away in the next release."
  )
end

# Everything below this line may read the environment. Nothing above it may:
# the variables are not all in place until the block above has run.

# Real email delivery over SMTP, when configured. Otherwise sent mail stays in
# the in-memory mailbox at /dev/mailbox and the sign-in link is also logged.
#
# Never in `test`: this block reads a .env, and a developer's .env names a real
# relay, so without the guard a test run would post mail to the internet.
smtp_host =
  if config_env() == :test, do: nil, else: System.get_env("SLIPDOCK_SMTP_HOST")

# The relay's certificate is verified unless this says not to — which a relay
# with a self-signed certificate needs. Applies to mail configured in the admin
# UI as well (see `Slipdock.Mailer.tls_options/1`).
smtp_tls_verify = System.get_env("SLIPDOCK_SMTP_TLS_VERIFY") not in ["0", "false"]

if config_env() != :test do
  config :slipdock, :smtp_tls_verify, smtp_tls_verify
end

if host = smtp_host do
  # Credentials are optional: an IP-authorised relay (e.g. Gmail's
  # smtp-relay.gmail.com) needs none.
  auth =
    case {System.get_env("SLIPDOCK_SMTP_USER"), System.get_env("SLIPDOCK_SMTP_PASSWORD")} do
      {user, pass} when is_binary(user) and is_binary(pass) ->
        [username: user, password: pass, auth: :always]

      _ ->
        [auth: :never]
    end

  config :slipdock,
         Slipdock.Mailer,
         [
           adapter: Swoosh.Adapters.SMTP,
           relay: host,
           port: String.to_integer(System.get_env("SLIPDOCK_SMTP_PORT") || "587"),
           tls: :if_available,
           tls_options:
             if(smtp_tls_verify,
               do: [
                 verify: :verify_peer,
                 cacerts: :public_key.cacerts_get(),
                 server_name_indication: String.to_charlist(host),
                 depth: 10,
                 customize_hostname_check: [
                   match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                 ]
               ],
               else: [verify: :verify_none]
             ),
           retries: 1
         ] ++ auth

  # The same details again, in the shape `Slipdock.Settings.seed/0` wants, so a
  # server configured this way carries its mail settings into the settings row
  # the first time it boots and can then be edited from the admin UI. Seeding
  # happens once: after that the row wins and these are ignored.
  config :slipdock, :seed_smtp,
    host: host,
    port: String.to_integer(System.get_env("SLIPDOCK_SMTP_PORT") || "587"),
    username: System.get_env("SLIPDOCK_SMTP_USER"),
    password: System.get_env("SLIPDOCK_SMTP_PASSWORD"),
    from_email: System.get_env("SLIPDOCK_SMTP_FROM") || System.get_env("SLIPDOCK_MAIL_FROM"),
    from_name: System.get_env("SLIPDOCK_MAIL_FROM_NAME") || "Slipdock",
    tls: :if_available
end

# Keys are per-person now (Account → AI key, stored by `Slipdock.AI.Keys`).
# OPENROUTER_API_KEY still works as a *shared* key for everyone on this
# server, which is rarely what you want — leave it unset unless you mean it.
if key = System.get_env("OPENROUTER_API_KEY") do
  config :slipdock, :ai, api_key: key
end

# Who may spend that shared key. On a server run for other people it is an open
# tab — everybody's AI on the operator's card — and the bill arrives a month
# later. This keeps it for admins; everybody else brings their own key or gets
# no AI features. Off by default: the card limit already bounds how much any one
# account can index, and AI working out of the box is a reason to subscribe.
if System.get_env("SLIPDOCK_SHARED_AI_KEY_ADMINS_ONLY") in ["1", "true"] do
  config :slipdock, :ai, shared_key_for_admins_only: true
end

# Where the per-user keys are kept, and whose key unattended work (the search
# indexer, scheduled automations) spends when there is no shared key.
# Who may sign up. SLIPDOCK_SIGNUP_ALLOW is a comma-separated list of addresses
# and domains ("you@example.com,example.org"); SLIPDOCK_OPEN_SIGNUP=true lets
# anybody in. Without either, only people who already have an account can sign
# in — and the first address to use an empty instance claims it.
if System.get_env("SLIPDOCK_OPEN_SIGNUP") in ["1", "true"] do
  config :slipdock, :signups, open: true
end

# This server's own settings, seeded into the database on first boot (see
# `Slipdock.Settings`). Setting SLIPDOCK_ADMIN_EMAIL is what lets a container be
# configured with no browser: the setup wizard never appears, and that address
# is the admin.
#
# All of these seed *once*. Changing one on a server that has already been set
# up has no effect — edit it in the admin UI instead.

# A limit variable carries a number, or `0`/`off` to turn that limit off. These
# two read the same variable from either end: the number, and the switch.
positive_env = fn name ->
  case System.get_env(name) do
    nil -> nil
    "" -> nil
    value -> with {n, _} when n > 0 <- Integer.parse(value), do: n, else: (_ -> nil)
  end
end

switch_env = fn name ->
  case System.get_env(name) do
    nil -> nil
    "" -> nil
    value when value in ["0", "off", "false", "none"] -> false
    _ -> true
  end
end

settings_env =
  [
    signup_mode:
      case System.get_env("SLIPDOCK_SIGNUP_MODE") do
        mode when mode in ["open", "allowlist", "approval", "closed"] -> String.to_atom(mode)
        _ -> nil
      end,
    free_card_limit:
      case System.get_env("SLIPDOCK_FREE_CARD_LIMIT") do
        nil -> nil
        "" -> nil
        value -> String.to_integer(value)
      end,
    user_directory:
      case System.get_env("SLIPDOCK_USER_DIRECTORY") do
        directory when directory in ["instance", "shared_only"] -> String.to_atom(directory)
        _ -> nil
      end,
    invites_create_accounts:
      case System.get_env("SLIPDOCK_INVITES_CREATE_ACCOUNTS") do
        value when value in ["1", "true"] -> true
        value when value in ["0", "false"] -> false
        _ -> nil
      end,
    admin_email: System.get_env("SLIPDOCK_ADMIN_EMAIL"),
    # The free trial, and the ceilings every install has. A number seeds the
    # limit; `0` or `off` switches that limit off altogether. Leaving one unset
    # keeps the default (1,000 boards / 250,000 items / 10 GB, trial off).
    trial_days: positive_env.("SLIPDOCK_TRIAL_DAYS"),
    trial_enabled: switch_env.("SLIPDOCK_TRIAL_DAYS"),
    board_limit: positive_env.("SLIPDOCK_BOARD_LIMIT"),
    board_limit_enabled: switch_env.("SLIPDOCK_BOARD_LIMIT"),
    item_limit: positive_env.("SLIPDOCK_ITEM_LIMIT"),
    item_limit_enabled: switch_env.("SLIPDOCK_ITEM_LIMIT"),
    storage_limit_mb: positive_env.("SLIPDOCK_STORAGE_LIMIT_MB"),
    storage_limit_enabled: switch_env.("SLIPDOCK_STORAGE_LIMIT_MB")
  ]
  |> Enum.reject(fn {_k, v} -> is_nil(v) end)

if settings_env != [] do
  config :slipdock, :settings, settings_env
end

# Writing sign-in codes to a file is how a server with no working mail lets
# anybody in at all — and a back door for anyone who can read that file. This
# turns it off for good, whatever the admin UI says: set it on a public host.
if System.get_env("SLIPDOCK_LOGIN_FALLBACK") in ["0", "false"] do
  config :slipdock, :login_fallback, false
end

# Where that file goes. The default sits under the application's working
# directory, which in a container is not somewhere you will think to look and
# does not survive a restart — point it at the data volume.
if path = System.get_env("SLIPDOCK_LOGIN_FALLBACK_PATH") do
  config :slipdock, :login_fallback_path, path
end

# Configuration tells an admin when a newer image has been published, by asking
# the registry when they look (never on a timer). Off for a server that should
# not reach the internet; pointed elsewhere for a fork that publishes its own.
# SLIPDOCK_TAG is the same variable compose.yaml pulls by, when .env sets it.
# Only what is set, so the defaults in `Slipdock.Updates` (and test.exs) stand.
config :slipdock,
       :updates,
       [
         enabled: if(System.get_env("SLIPDOCK_UPDATE_CHECK") in ["0", "false"], do: false),
         image: System.get_env("SLIPDOCK_UPDATE_IMAGE"),
         tag: System.get_env("SLIPDOCK_TAG")
       ]
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if allow = System.get_env("SLIPDOCK_SIGNUP_ALLOW") do
  config :slipdock, :signups,
    open: System.get_env("SLIPDOCK_OPEN_SIGNUP") in ["1", "true"],
    allow: allow |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end

# Where this instance's source lives, offered in the UI (AGPL §13). Change it
# if you run a modified copy — that is what the licence asks of you.
if url = System.get_env("SLIPDOCK_SOURCE_URL") do
  config :slipdock, :source_url, url
end

if file = System.get_env("SLIPDOCK_AI_KEY_FILE") do
  config :slipdock, :ai, key_file: file
end

if email = System.get_env("SLIPDOCK_AI_SYSTEM_USER") do
  config :slipdock, :ai, system_user: email
end

# Webhook callbacks and people's own AI endpoints may not reach private,
# loopback, link-local or CGNAT addresses (see `Slipdock.Egress`). "all"
# lifts that; otherwise a comma-separated list of CIDRs reopens just those,
# e.g. the LAN box running LM Studio.
case System.get_env("SLIPDOCK_EGRESS_ALLOW") do
  nil ->
    :ok

  "all" ->
    config :slipdock, :egress, allow: :all

  list ->
    config :slipdock, :egress,
      allow: list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# Which peers may tell us the visitor's address in X-Forwarded-For (see
# `SlipdockWeb.ClientIP`). Unset: loopback and the private ranges, which fits a
# proxy on this host or in the same Docker network. A comma-separated list of
# CIDRs replaces that; "none" believes nobody and uses the peer address as-is.
case System.get_env("SLIPDOCK_TRUSTED_PROXIES") do
  nil ->
    :ok

  "none" ->
    config :slipdock, :trusted_proxies, []

  list ->
    config :slipdock,
           :trusted_proxies,
           list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# The default endpoint everyone falls back to. Point it at a local model
# server to make this instance local-first; anyone can still override it for
# themselves under Account → AI model.
if url = System.get_env("SLIPDOCK_AI_BASE_URL") do
  config :slipdock, :ai, base_url: url
end

if model = System.get_env("SLIPDOCK_AI_MODEL") do
  config :slipdock, :ai, model: model
end

if model = System.get_env("SLIPDOCK_AI_QUICK_MODEL") do
  config :slipdock, :ai, quick_model: model
end

if model = System.get_env("SLIPDOCK_AI_EMBED_MODEL") do
  config :slipdock, :ai, embed_model: model
end

if dims = System.get_env("SLIPDOCK_AI_EMBED_DIMENSIONS") do
  config :slipdock, :ai, embed_dimensions: String.to_integer(dims)
end

if dir = System.get_env("SLIPDOCK_UPLOADS_DIR") do
  config :slipdock, :uploads_dir, dir
end

# The address automation emails link back to, when it isn't derivable from
# the endpoint configuration (behind a proxy, say).
if base_url = System.get_env("SLIPDOCK_BASE_URL") do
  config :slipdock, :base_url, String.trim_trailing(base_url, "/")
end

if from = System.get_env("SLIPDOCK_MAIL_FROM") do
  config :slipdock, :mail_from, {"Slipdock", from}
end

# A first sign-in builds a "Getting Started" board — a tour of the app made of
# the app (see `Slipdock.Onboarding`). SLIPDOCK_WELCOME_BOARD=0 turns that off
# for a server whose people arrive already knowing what they are doing;
# `mix slipdock.welcome` and `slipdock welcome` keep working either way.
if System.get_env("SLIPDOCK_WELCOME_BOARD") in ["0", "false", "no"] do
  config :slipdock, :welcome_board, false
end

# SLIPDOCK_AGENTIC_LOGIN=true adds an "Agentic Login" button to the sign-in page
# that writes the one-time link to a file (in SLIPDOCK_AGENTIC_LOGIN_DIR, default
# a private slipdock-agentic-login directory under the system temp dir, mode
# 0600) instead of emailing it. Anyone who can reach the page can create such
# files, so only enable it on machines used for automated testing.
if System.get_env("SLIPDOCK_AGENTIC_LOGIN") in ["1", "true"] do
  config :slipdock, agentic_login: true
end

if (dir = System.get_env("SLIPDOCK_AGENTIC_LOGIN_DIR")) && config_env() != :test do
  config :slipdock, agentic_login_dir: dir
end

if System.get_env("PHX_SERVER") do
  config :slipdock, SlipdockWeb.Endpoint, server: true
end

config :slipdock, SlipdockWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :slipdock, SlipdockWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/slipdock_web/router\.ex$"E,
        ~r"lib/slipdock_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: postgres://slipdock:secret@postgres:5432/slipdock
      """

  # A managed Postgres almost always wants TLS, and a Postgres on the same
  # Docker network almost never does. DATABASE_SSL=true turns it on;
  # DATABASE_SSL_VERIFY=false then stops it checking the certificate chain,
  # which is what a provider using its own CA needs (Fly, some Supabase
  # configurations) short of giving us a CA bundle to trust.
  maybe_ssl =
    if System.get_env("DATABASE_SSL") in ~w(1 true) do
      verify =
        if System.get_env("DATABASE_SSL_VERIFY") in ~w(0 false),
          do: :verify_none,
          else: :verify_peer

      # The certificate's name is checked against the host in DATABASE_URL —
      # which is what stops somebody in the middle presenting any certificate
      # the CA store happens to trust.
      db_host = URI.parse(database_url).host

      ssl =
        if verify == :verify_peer and is_binary(db_host) do
          [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(db_host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        else
          [verify: :verify_none]
        end

      [ssl: ssl]
    else
      []
    end

  # ECTO_IPV6 for a host that only resolves to an AAAA record — fly.io's
  # internal DNS, for one.
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(1 true), do: [:inet6], else: []

  config :slipdock,
         Slipdock.Repo,
         [
           url: database_url,
           pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
           socket_options: maybe_ipv6
         ] ++ maybe_ssl

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # How the app describes itself in the links it generates — sign-in emails
  # above all, which are useless if they point at a scheme or port nobody is
  # listening on. https on 443 is the default because that is what a server on
  # the internet looks like; a container reached over plain http on its
  # published port sets these (see compose.yaml).
  url_scheme = System.get_env("SLIPDOCK_URL_SCHEME") || "https"

  url_port =
    String.to_integer(
      System.get_env("SLIPDOCK_URL_PORT") || if(url_scheme == "https", do: "443", else: "80")
    )

  config :slipdock, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Phoenix only accepts live-update connections whose Origin matches the host
  # above, which is right until the same server is reached by several names — a
  # tailnet name and an IP, say. List the others here (comma-separated), or set
  # it to "false" to accept any origin, which gives up a CSRF protection on the
  # socket and should be a last resort.
  #
  # The check itself goes through `SlipdockWeb.Origin` rather than Phoenix's
  # built-in list. It does the same thing — compare the host — but when it
  # refuses it says which variable to set and to what, instead of Phoenix's
  # generic advice to edit config files that a container has no copy of.
  config :slipdock,
         :origin_hosts,
         [host | SlipdockWeb.Origin.parse(System.get_env("SLIPDOCK_CHECK_ORIGIN"))]

  check_origin =
    if System.get_env("SLIPDOCK_CHECK_ORIGIN") == "false",
      do: false,
      else: {SlipdockWeb.Origin, :allowed?, []}

  config :slipdock, SlipdockWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :slipdock, SlipdockWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :slipdock, SlipdockWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
