defmodule SlipdockWeb.API.JobKeepTest do
  # Keep this log over HTTP (#1872), what a job says of its log's fate, and
  # the board's two retention settings through PATCH /api/boards/:board.
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.Runners
  alias Slipdock.Runners.{Transcript, TranscriptRetention}

  @said ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Done it."}]}}\n)

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Keep logs"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Keep me"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(runner)
    {:ok, 1} = Transcript.append(runner, job.id, 0, @said)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      card: card,
      job: job,
      runner: runner
    }
  end

  defp keep(conn, job), do: post(conn, "/api/jobs/#{job.id}/keep", %{})

  test "keeps an ended job's log as a page, once", ctx do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})

    before = json_response(get(ctx.conn, "/api/jobs/#{ctx.job.id}"), 200)["job"]
    assert before["transcript_expires_at"]
    assert before["transcript_failure"] == false
    assert before["transcript_page_id"] == nil

    body = json_response(keep(ctx.conn, ctx.job), 200)
    assert body["page"]["title"] =~ ~r/\APass #{ctx.card.id} \(\d{4}-\d\d-\d\d \d\d\.\d\d\)\z/
    assert body["page"]["url"] =~ "/wiki/"
    assert body["job"]["transcript_page_id"] == body["page"]["id"]
    assert body["job"]["transcript_expires_at"] == nil

    again = json_response(keep(ctx.conn, ctx.job), 200)
    assert again["page"]["id"] == body["page"]["id"]
  end

  test "refuses a running job, a job with no log left, and a reader", ctx do
    assert json_response(keep(ctx.conn, ctx.job), 422)["error"] =~ "still running"

    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "1"})

    reader = user_fixture("reader#{System.unique_integer([:positive])}@example.com")
    share_fixture(ctx.board, [reader], "read")
    assert keep(conn_as(reader), ctx.job).status == 403

    Slipdock.Repo.update_all(
      from(j in Slipdock.Runners.Job, where: j.id == ^ctx.job.id),
      set: [finished_at: ~U[2020-01-01 00:00:00Z]]
    )

    assert TranscriptRetention.sweep() == 1
    gone = json_response(get(ctx.conn, "/api/jobs/#{ctx.job.id}"), 200)["job"]
    assert gone["transcript_deleted_at"]
    assert gone["transcript_failure"] == true
    assert json_response(keep(ctx.conn, ctx.job), 422)["error"] =~ "no log to keep"
    assert keep(ctx.conn, %{id: 999_999_999}).status == 404
  end

  test "the board's two times are set and read through the API, and checked", ctx do
    url = "/api/boards/#{ctx.board.id}"
    board = json_response(get(ctx.conn, url), 200)["board"]
    assert board["job_log_hours"] == 24
    assert board["failure_log_hours"] == 168

    body =
      json_response(patch(ctx.conn, url, %{"job_log_hours" => 6, "failure_log_hours" => 48}), 200)

    assert body["board"]["job_log_hours"] == 6
    assert body["board"]["failure_log_hours"] == 48

    assert json_response(patch(ctx.conn, url, %{"job_log_hours" => 0}), 422)
  end
end
