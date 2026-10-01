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
    Supervisor.start_link(children, opts)
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
