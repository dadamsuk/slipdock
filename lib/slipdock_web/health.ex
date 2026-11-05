defmodule SlipdockWeb.Health do
  @moduledoc """
  `GET /healthz`: whether this server is answering and can reach its database,
  which commit it was built from, and the pulse of the clocks behind the
  health monitor (#1765): when the scheduler last ticked and the monitor last
  ran (see `Slipdock.Health.pulse/1`).

      {"status": "ok", "sha": "1a2b3c…", "scheduler": {…}, "monitor": {…}}   200
      {"status": "stale", "reason": "the scheduler last ran 12 minutes ago", …}  503
      {"status": "unavailable", "sha": "1a2b3c…"}    503, the database did not answer

  A clock is stale when it hasn't beaten for a few of its intervals, but not
  in the first ten minutes after boot, so the deploy's wait still passes
  before the first tick. An outside uptime check on `/healthz` therefore
  catches the clock itself stopping, which the monitor can't report.

  The deploy job in the release workflow polls it after a restart and fails
  unless it is `ok` *and* the sha is the commit it deployed — an old container
  still answering is not a successful deploy. The sha is the public commit from
  the public repository, the same one Configuration shows.

  It sits in the endpoint ahead of the session, the router and the request
  log, so a probe costs one `SELECT 1` and leaves no cookie behind.
  """

  @behaviour Plug

  import Plug.Conn

  alias Slipdock.Build

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["healthz"], method: method} = conn, opts)
      when method in ["GET", "HEAD"] do
    check = Keyword.get(opts, :check, &database/0)
    pulse = Keyword.get(opts, :pulse, &Slipdock.Health.pulse/0)

    {status, body} =
      case check.() do
        :ok ->
          clocks = pulse.()

          case Slipdock.Health.stale_reason(clocks) do
            nil -> {200, Map.merge(%{status: "ok"}, clocks)}
            reason -> {503, Map.merge(%{status: "stale", reason: reason}, clocks)}
          end

        _ ->
          {503, %{status: "unavailable"}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(Map.put(body, :sha, Build.sha())))
    |> halt()
  end

  def call(conn, _opts), do: conn

  @doc "`:ok` when the database answers a trivial query within two seconds."
  def database do
    case Slipdock.Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    # No pool to check a connection out of — the repo is down or restarting.
    e -> {:error, e}
  end
end
