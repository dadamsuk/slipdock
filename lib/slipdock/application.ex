defmodule Slipdock.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    warn_about_agentic_login()

    children = [
      SlipdockWeb.Telemetry,
      Slipdock.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:slipdock, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:slipdock, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Slipdock.PubSub},
      # Counters behind the sign-in form's rate limit.
      Slipdock.RateLimit,
      # Emails and webhooks sent by automation rules, off the caller's back.
      {Task.Supervisor, name: Slipdock.TaskSupervisor},
      # The clock behind the time-based automation triggers.
      Slipdock.Automations.Scheduler,
      # Embeds changed cards for semantic search, off the saver's back.
      Slipdock.Search.Indexer,
      # Start to serve requests, typically the last entry
      SlipdockWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Slipdock.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      prepare_settings()
      {:ok, pid}
    end
  end

  # The settings row, once, from the environment — and on a server nobody has
  # claimed yet, the token that `/setup` will ask for. Both need the Repo and
  # the migrator, so this runs after the supervisor is up rather than before it.
  defp prepare_settings do
    # The test environment opts out: this runs before any sandbox is checked
    # out, so a row written here would escape the rollback and outlive the test
    # run. `Slipdock.SettingsTest` calls `seed/0` directly instead.
    if Application.get_env(:slipdock, :seed_settings, true) do
      Slipdock.Settings.seed()
      announce_setup(Slipdock.Settings.ensure_setup_token())
    end
  end

  defp announce_setup(nil), do: :ok

  defp announce_setup(token) do
    require Logger

    Logger.info("""
    This Slipdock server has not been set up yet. Open

        #{Slipdock.Settings.setup_url(token)}

    to choose who may register here, set up email, and name the admin. The
    token above is what stops whoever reaches that page first from claiming
    this server; it is in this log only.
    """)
  end

  # "Agentic Login" writes a working sign-in link for *any* email to a file on
  # this machine, which is an authentication bypass for anyone who can reach
  # the sign-in page or read that directory. It is meant for automated testing
  # only, so a server that has it on says so on every boot rather than letting
  # it pass unnoticed.
  defp warn_about_agentic_login do
    if Slipdock.Accounts.agentic_login_enabled?() do
      require Logger

      Logger.warning(
        "Agentic Login is ENABLED: anyone who can reach /login can mint a sign-in " <>
          "link for any address, written to #{Application.get_env(:slipdock, :agentic_login_dir, "/tmp")}. " <>
          "Use it only on a machine for automated testing (unset SLIPDOCK_AGENTIC_LOGIN to turn it off)."
      )
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SlipdockWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
