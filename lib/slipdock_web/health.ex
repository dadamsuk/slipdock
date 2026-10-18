defmodule SlipdockWeb.Health do
  @moduledoc """
  `GET /healthz`: whether this server is answering and can reach its database,
  and which commit it was built from.

      {"status": "ok", "sha": "1a2b3c…"}             200
      {"status": "unavailable", "sha": "1a2b3c…"}    503, the database did not answer

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

    {status, word} =
      case check.() do
        :ok -> {200, "ok"}
        _ -> {503, "unavailable"}
      end

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(%{status: word, sha: Build.sha()}))
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
