defmodule SlipdockWeb.FlakyTranscripts do
  @moduledoc false
  # For the runner script tests (#1870), in front of the app: answers the first `fail` transcript sends with a
  # 503, as a server that is down for a moment would, and passes the rest.
  @behaviour Plug

  def start(fail: n) do
    :persistent_term.put({__MODULE__, :left}, :counters.new(1, []))
    :counters.put(:persistent_term.get({__MODULE__, :left}), 1, n)
    :persistent_term.put({__MODULE__, :failed}, :counters.new(1, []))

    {:ok, server} =
      Bandit.start_link(plug: __MODULE__, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    ExUnit.Callbacks.on_exit(fn -> Process.exit(server, :normal) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  def failed, do: :counters.get(:persistent_term.get({__MODULE__, :failed}), 1)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_info: ["api", "runner", "jobs", _, "transcript"]} = conn, opts) do
    left = :persistent_term.get({__MODULE__, :left})

    if :counters.get(left, 1) > 0 do
      :counters.sub(left, 1, 1)
      :counters.add(:persistent_term.get({__MODULE__, :failed}), 1, 1)
      Plug.Conn.send_resp(conn, 503, "down for a moment\n")
    else
      SlipdockWeb.Endpoint.call(conn, opts)
    end
  end

  def call(conn, opts), do: SlipdockWeb.Endpoint.call(conn, SlipdockWeb.Endpoint.init(opts))
end
