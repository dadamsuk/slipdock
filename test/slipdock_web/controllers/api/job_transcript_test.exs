defmodule SlipdockWeb.API.JobTranscriptTest do
  # A job's live log over HTTP (#1870): the runner's plain-text send, with
  # its own token, and reading it back with an API token.
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Runners

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Runner logs"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Watch me"})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(runner)

    %{conn: put_req_header(conn, "accept", "application/json"), job: job, token: token}
  end

  defp runner_conn(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "text/plain")
  end

  defp send_lines(ctx, from, body),
    do:
      post(runner_conn(ctx.token), "/api/runner/jobs/#{ctx.job.id}/transcript?from=#{from}", body)

  test "a send answers the lines held, and the job's endpoints read them back", ctx do
    conn = send_lines(ctx, 0, ~s({"a":1}\n{"b":2}\n))
    assert conn.status == 200
    assert conn.resp_body == "ok 2\n"

    assert send_lines(ctx, 2, ~s({"c":3}\n)).resp_body == "ok 3\n"

    read = get(ctx.conn, "/api/jobs/#{ctx.job.id}/transcript")
    assert read.status == 200
    assert read.resp_body == ~s({"a":1}\n{"b":2}\n{"c":3}\n)
    assert get_resp_header(read, "x-transcript-lines") == ["3"]
    assert get_resp_header(read, "x-transcript-capped") == ["false"]
    assert [type] = get_resp_header(read, "content-type")
    assert type =~ "application/x-ndjson"

    assert get(ctx.conn, "/api/jobs/#{ctx.job.id}/transcript?from=2").resp_body == ~s({"c":3}\n)
    # A from that isn't a number reads from the start.
    assert get(ctx.conn, "/api/jobs/#{ctx.job.id}/transcript?from=x").resp_body =~ ~s({"a":1})

    job = json_response(get(ctx.conn, "/api/jobs/#{ctx.job.id}"), 200)["job"]
    assert job["transcript_lines"] == 3
    assert job["transcript_capped"] == false
    assert job["transcript_at"]
  end

  test "the runner's own token is taken out of what it sends", ctx do
    assert send_lines(ctx, 0, ~s({"t":"#{ctx.token}"}\n)).status == 200
    body = get(ctx.conn, "/api/jobs/#{ctx.job.id}/transcript").resp_body
    refute body =~ ctx.token
    assert body == ~s({"t":"[redacted]"}\n)
  end

  test "a gap is a 409 naming where to send from", ctx do
    assert send_lines(ctx, 0, ~s({"a":1}\n)).resp_body == "ok 1\n"
    conn = send_lines(ctx, 4, ~s({"e":5}\n))
    assert conn.status == 409
    assert conn.resp_body == "from 1\n"
  end

  test "a send over the size read keeps its whole lines, and the rest comes again", ctx do
    line = ~s({"pad":") <> String.duplicate("p", 30_000) <> ~s("}\n)
    count = div(Slipdock.Runners.Transcript.max_send(), byte_size(line)) + 5
    conn = send_lines(ctx, 0, String.duplicate(line, count))

    assert conn.status == 200
    "ok " <> held = String.trim(conn.resp_body)
    held = String.to_integer(held)
    assert held == div(Slipdock.Runners.Transcript.max_send(), byte_size(line))
    assert held < count
  end

  test "a finished job, another runner's token and a stranger are refused", ctx do
    board = board_fixture(%{"name" => "Elsewhere"})
    {:ok, _, other_token} = Runners.create_runner(board, %{"name" => "x", "pool" => "dev"})

    assert post(runner_conn(other_token), "/api/runner/jobs/#{ctx.job.id}/transcript", "{}\n").status ==
             404

    assert post(runner_conn("sdr_nope"), "/api/runner/jobs/#{ctx.job.id}/transcript", "{}\n").status ==
             401

    outsider = conn_as(user_fixture("out#{System.unique_integer([:positive])}@example.com"))
    assert get(outsider, "/api/jobs/#{ctx.job.id}/transcript").status == 403

    post(runner_conn(ctx.token), "/api/runner/jobs/#{ctx.job.id}/finish?exit=0", "")
    conn = send_lines(ctx, 0, ~s({"late":1}\n))
    assert conn.status == 409
    assert conn.resp_body =~ "ended"
  end
end
