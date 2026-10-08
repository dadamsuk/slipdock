defmodule SlipdockWeb.API.RunnerController do
  @moduledoc """
  The runner protocol: what a runner on somebody's machine calls to take
  jobs and report on them (see `Slipdock.Runners`).

  Deliberately not JSON. The shell runner is `sh` and `curl` and nothing
  else, so everything it needs comes back as response headers and a plain
  text body, and what it sends is a plain text body too:

      POST /api/runner/claim?wait=30          204, or 200 + X-Job-* headers, prompt as body
      POST /api/runner/jobs/:id/heartbeat     body = log tail → "ok" or "cancel"
      POST /api/runner/jobs/:id/finish?exit=N&status=S   body = last output → "ok"

  Authenticated with a runner token (`Authorization: Bearer sdr_…`), never
  an API token: a runner can take and report on its own pool's jobs and do
  nothing else.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Runners

  plug :fetch_runner

  # Long enough to keep an idle runner's requests rare, short enough to sit
  # under the usual 60-second proxy timeout.
  @default_wait 25
  @max_wait 50
  @max_body 1_000_000

  def claim(conn, params) do
    runner = conn.assigns.runner

    if params["pool"] not in [nil, "", runner.pool] do
      text_reply(conn, 403, "this runner token is for pool #{runner.pool}, not #{params["pool"]}")
    else
      case Runners.claim(runner, wait(params["wait"]) * 1000) do
        nil ->
          send_resp(conn, 204, "")

        job ->
          conn
          |> put_resp_header("x-job-id", to_string(job.id))
          |> put_resp_header("x-job-kind", job.kind)
          |> put_resp_header("x-card-id", to_string(job.card_id))
          |> put_resp_header("x-card-ref", "##{job.card_id}")
          |> put_resp_header("x-card-url", card_url(job))
          |> put_resp_header("x-board-id", to_string(job.board_id))
          |> put_resp_header("x-lease-seconds", to_string(Runners.lease_seconds()))
          |> text_reply(200, job.prompt, newline: false)
      end
    end
  end

  def heartbeat(conn, %{"id" => id}) do
    {log, conn} = body(conn)

    case Runners.heartbeat(conn.assigns.runner, id, log) do
      {:ok, :ok} -> text_reply(conn, 200, "ok")
      {:ok, :cancel} -> text_reply(conn, 200, "cancel")
      {:error, :not_found} -> text_reply(conn, 404, "no such job for this runner")
    end
  end

  def finish(conn, %{"id" => id} = params) do
    {output, conn} = body(conn)
    attrs = %{exit: params["exit"], status: params["status"], output: output}

    case Runners.finish(conn.assigns.runner, id, attrs) do
      {:ok, job} -> text_reply(conn, 200, "ok #{job.status}")
      {:error, :not_found} -> text_reply(conn, 404, "no such job for this runner")
    end
  end

  defp fetch_runner(conn, _opts) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    case Runners.authenticate(token) do
      nil ->
        conn
        |> text_reply(401, "unauthorized: pass a runner token as `Authorization: Bearer sdr_…`")
        |> halt()

      runner ->
        assign(conn, :runner, runner)
    end
  end

  defp wait(nil), do: @default_wait

  defp wait(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n |> max(0) |> min(@max_wait)
      :error -> @default_wait
    end
  end

  # The whole body, up to a limit; logs are tails, so the end is what counts.
  defp body(conn, acc \\ "") do
    case read_body(conn) do
      {:ok, chunk, conn} ->
        {Runners.tail(acc <> chunk, @max_body), conn}

      {:more, chunk, conn} ->
        body(conn, Runners.tail(acc <> chunk, @max_body))

      {:error, _} ->
        {acc, conn}
    end
  end

  defp card_url(job),
    do: "#{Slipdock.Automations.Runner.base_url()}/boards/#{job.board_id}/cards/#{job.card_id}"

  defp text_reply(conn, status, text, opts \\ []) do
    text = if opts[:newline] == false, do: text, else: text <> "\n"

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, text)
  end
end
