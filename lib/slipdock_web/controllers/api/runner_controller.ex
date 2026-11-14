defmodule SlipdockWeb.API.RunnerController do
  @moduledoc """
  The runner protocol: what a runner on somebody's machine calls to take
  jobs and report on them (see `Slipdock.Runners`).

  Deliberately not JSON: it was written for a shell runner that was `sh`
  and `curl` and nothing else (retired for the runner daemon, #2582), so
  everything a runner needs comes back as response headers and a plain text
  body, and what it sends is a plain text body too:

      POST /api/runner/claim?wait=30          204, or 200 + X-Job-* headers, prompt as body
      POST /api/runner/jobs/:id/heartbeat     body = log tail → "ok" or "cancel"
      POST /api/runner/jobs/:id/finish?exit=N&status=S   body = last output → "ok"
      POST /api/runner/jobs/:id/transcript?from=N   body = transcript lines from N → "ok L"

  The transcript (#1870) is the job's live log: whole lines of its agent's
  Claude Code transcript from line `N`, about once a minute and once more as
  the job ends. The answer is the lines the server now holds, `ok L` (or
  `capped L` once the log is full, and nothing more is kept), and the next
  send starts at `L`. A `from` past what is held answers 409 `from L`: send
  again from `L`. See `Slipdock.Runners.Transcript`.

  A claim may say which job kinds the runner takes (`X-Runner-Kinds:
  claude,merge`, #1656): kept on the runner, and a `merge` job goes only to
  a runner that lists it. A merge job comes with `X-Merge-PR` and
  `X-Merge-Commit`, and its finish may say `merged=<sha>`. An
  `X-Runner-Version` on a claim is ignored: the scripts that said which
  one they ran, and were answered with `X-Runner-Latest` to update
  themselves (#1658), were retired (#2582).

  A probe (`X-Job-Kind: probe`, #2580) has no card, so no `X-Card-*`
  headers: its body is what the server knows of the runner, one `name:
  value` line each (`Slipdock.Runners.Probe.prompt/1`).

  A job that asked a person something (a wait opened with its id) finishes
  `ok parked`, whatever its exit code. A job sent again after its question
  was answered says so in `X-Wait-Id`, and `X-Handoff-Id` names the card's
  handoff; both are in the prompt already, so a runner that only reads the
  body loses nothing.

  A job its agent couldn't run on the machine at all (#2920) finishes
  `status=requeue&trouble=limit|quick_exit&until=<ISO 8601>&reason=<line>`
  and answers `ok queued`: it goes back to the queue uncounted, its card
  untouched, and the board gets one alert for the machine
  (`Slipdock.Runners.Trouble`). Cancelled or waiting, it ends as ever.

  An empty claim says why work is held, when it is, in `X-Held`
  ("paused by David: bad deploy", "WIP full: In Progress 3/3").

  A server on its way down (see `Slipdock.Runners.ClaimDrain`) answers
  claims with a 204 and `Retry-After: 1`.

  Authenticated with a runner token (`Authorization: Bearer sdr_…`), never
  an API token: a runner can take and report on its own pool's jobs and do
  nothing else. A machine's daemon (#2571) passes its machine key
  (`Bearer sdm_…`) and names the runner in `X-Runner-Id`: it claims and
  reports only for its own machine's runners.
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
    runner =
      conn.assigns.runner
      |> Runners.report_kinds(conn |> get_req_header("x-runner-kinds") |> List.first())
      |> Slipdock.Runners.Drift.report(
        conn |> get_req_header("x-runner-skills") |> List.first(),
        conn |> get_req_header("x-runner-cli") |> List.first()
      )

    if Enum.member?([nil, "", runner.pool], params["pool"]) do
      case Runners.claim(runner, wait(params["wait"]) * 1000) do
        nil ->
          conn |> draining() |> held(runner) |> send_resp(204, "")

        job ->
          conn
          |> put_resp_header("x-job-id", to_string(job.id))
          |> put_resp_header("x-job-kind", job.kind)
          |> card_headers(job)
          |> put_resp_header("x-board-id", to_string(job.board_id))
          |> put_resp_header("x-lease-seconds", to_string(Runners.lease_for(conn.assigns.runner)))
          |> context_headers(job)
          |> text_reply(200, Runners.claimed_prompt(job), newline: false)
      end
    else
      text_reply(conn, 403, "this runner token is for pool #{runner.pool}, not #{params["pool"]}")
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

    attrs = %{
      exit: params["exit"],
      status: params["status"],
      output: output,
      merged: params["merged"],
      # A job its agent couldn't run (status=requeue, #2920).
      trouble: params["trouble"],
      until: params["until"],
      reason: params["reason"]
    }

    case Runners.finish(conn.assigns.runner, id, attrs) do
      {:ok, job} ->
        text_reply(conn, 200, "ok #{job.status}")

      {:error, :not_found} ->
        text_reply(conn, 404, "no such job for this runner")

      {:error, message} ->
        text_reply(conn, 422, message)
    end
  end

  def transcript(conn, %{"id" => id} = params) do
    {text, conn} = head_body(conn, Slipdock.Runners.Transcript.max_send())
    secrets = [conn.assigns.runner_token]

    case Slipdock.Runners.Transcript.append(
           conn.assigns.runner,
           id,
           params["from"] || "0",
           text,
           secrets: secrets
         ) do
      {:ok, lines} -> text_reply(conn, 200, "ok #{lines}")
      {:capped, lines} -> text_reply(conn, 200, "capped #{lines}")
      {:gap, lines} -> text_reply(conn, 409, "from #{lines}")
      {:error, :ended} -> text_reply(conn, 409, "the job has ended")
      {:error, :not_found} -> text_reply(conn, 404, "no such job for this runner")
    end
  end

  # A probe (#2580) has no card, and so no card headers.
  defp card_headers(conn, %{card_id: nil}), do: conn

  defp card_headers(conn, job) do
    conn
    |> put_resp_header("x-card-id", to_string(job.card_id))
    |> put_resp_header("x-card-ref", "##{job.card_id}")
    |> put_resp_header("x-card-url", card_url(job))
  end

  defp context_headers(conn, job) do
    %{wait: wait, handoff: handoff, profile: profile} = Runners.claim_context(job)

    conn
    |> merge_headers(Runners.merge_target(job))
    # The card's profile (#1953): a word the runner's own config may pick a
    # model by (`MODEL_<profile>`); the server never says what to run.
    |> then(&if(profile, do: put_resp_header(&1, "x-card-profile", profile), else: &1))
    |> then(&if(wait, do: put_resp_header(&1, "x-wait-id", to_string(wait.id)), else: &1))
    |> then(
      &if(handoff, do: put_resp_header(&1, "x-handoff-id", to_string(handoff.id)), else: &1)
    )
  end

  # A merge job (#1656): the pull request and the accepted commit, for the
  # runner's built-in merge to check before it merges anything.
  defp merge_headers(conn, %{pr: pr, commit: commit}) do
    conn
    |> then(&if(pr, do: put_resp_header(&1, "x-merge-pr", header_text(pr)), else: &1))
    |> then(&if(commit, do: put_resp_header(&1, "x-merge-commit", header_text(commit)), else: &1))
  end

  defp merge_headers(conn, nil), do: conn

  defp fetch_runner(conn, _opts) do
    token = SlipdockWeb.UserAuth.bearer_token(conn)

    if is_binary(token) and String.starts_with?(token, "sdm_"),
      do: fetch_machine_runner(conn, token),
      else: fetch_token_runner(conn, token)
  end

  # A machine's daemon (#2571): its machine key, and which of its runners
  # is asking, in `X-Runner-Id` (or `?runner=`). Only its own runners.
  defp fetch_machine_runner(conn, key) do
    ref = conn |> get_req_header("x-runner-id") |> List.first() || conn.params["runner"]

    case Runners.authenticate_machine(key, ref, SlipdockWeb.ClientIP.from_conn(conn)) do
      {:ok, runner} ->
        conn |> assign(:runner, runner) |> assign(:runner_token, key)

      {:error, :unauthorized} ->
        conn
        |> text_reply(401, "unauthorized: the machine key is unknown or the machine is revoked")
        |> halt()

      {:error, :no_runner} ->
        conn
        |> text_reply(400, "a machine key says which of its runners is asking: X-Runner-Id")
        |> halt()

      {:error, :not_this_machine} ->
        conn |> text_reply(403, "that runner is not one of this machine's") |> halt()
    end
  end

  defp fetch_token_runner(conn, token) do
    case Runners.authenticate(token) do
      nil ->
        conn
        |> text_reply(401, "unauthorized: pass a runner token as `Authorization: Bearer sdr_…`")
        |> halt()

      runner ->
        conn |> assign(:runner, runner) |> assign(:runner_token, token)
    end
  end

  # Stopping for a deploy: ask the runner to wait a moment before asking
  # again, on a new connection, which reaches the app that replaces this one.
  defp draining(conn) do
    if Runners.draining?() do
      conn
      |> put_resp_header("retry-after", "1")
      |> put_resp_header("connection", "close")
    else
      conn
    end
  end

  # Why nothing was handed out, when something holds work (#1116). Header
  # values are one line of ASCII-safe text; a reason is a person's words.
  defp held(conn, runner) do
    with %Slipdock.Boards.Board{} = board <- Slipdock.Boards.get_board_record(runner.board_id),
         %{reason: reason} <- Runners.held(board, runner.pool) do
      put_resp_header(conn, "x-held", header_text(reason))
    else
      _ -> conn
    end
  end

  defp header_text(text) do
    text |> String.replace(~r/[\r\n]+/, " ") |> String.slice(0, 300)
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

  # The body from its start, up to `max` bytes: a transcript send's whole
  # lines count from the front, and what is past the limit is sent again.
  defp head_body(conn, max, acc \\ "") do
    case read_body(conn, length: max, read_length: min(max, 1_000_000)) do
      {:ok, chunk, conn} ->
        {cap(acc <> chunk, max), conn}

      {:more, chunk, conn} when byte_size(acc) + byte_size(chunk) >= max ->
        {cap(acc <> chunk, max), conn}

      {:more, chunk, conn} ->
        head_body(conn, max, acc <> chunk)

      {:error, _} ->
        {acc, conn}
    end
  end

  defp cap(text, max) when byte_size(text) > max, do: binary_part(text, 0, max)
  defp cap(text, _max), do: text

  defp card_url(job),
    do: "#{Slipdock.Automations.Runner.base_url()}/boards/#{job.board_id}/cards/#{job.card_id}"

  defp text_reply(conn, status, text, opts \\ []) do
    text = if opts[:newline] == false, do: text, else: text <> "\n"

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, text)
  end
end
