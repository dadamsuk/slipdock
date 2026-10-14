defmodule SlipdockWeb.RunnerStubQueue do
  @moduledoc """
  A stand-in for the runner queue, served on a loopback port, that answers
  claims from a script: what a runner sees through a deploy (a proxy's 502,
  a draining server's Retry-After) without stopping a real app. Every claim
  past the script is refused with a 401, which ends the runner's loop.
  """
  @behaviour Plug

  import Plug.Conn

  @doc """
  Serves `answers` (each `{status, headers}`) and answers `{url, stub}`;
  `claims/1` says when each claim arrived.
  """
  def start(answers) do
    {:ok, stub} = Agent.start(fn -> %{answers: answers, claims: []} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, stub},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {"http://127.0.0.1:#{port}", stub, server}
  end

  @doc "The monotonic millisecond each claim arrived at, oldest first."
  def claims(stub), do: stub |> Agent.get(& &1.claims) |> Enum.reverse()

  @impl true
  def init(stub), do: stub

  @impl true
  def call(%{request_path: "/api/runner/claim"} = conn, stub) do
    now = System.monotonic_time(:millisecond)

    {status, headers} =
      Agent.get_and_update(stub, fn
        %{answers: [next | rest]} = state ->
          {next, %{state | answers: rest, claims: [now | state.claims]}}

        state ->
          {{401, []}, %{state | claims: [now | state.claims]}}
      end)

    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_resp_header(conn, k, v) end)
    send_resp(conn, status, if(status == 401, do: "unauthorized: stub", else: ""))
  end

  def call(conn, _stub), do: send_resp(conn, 404, "")
end
