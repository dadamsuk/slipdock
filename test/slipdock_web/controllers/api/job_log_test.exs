defmodule SlipdockWeb.API.JobLogTest do
  # GET /api/jobs/:id/log (#1871): the job's live log as lines, for
  # `slipdock job --log/--follow`, from a line on, with where to read next.
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Runners
  alias Slipdock.Runners.Transcript

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Runner logs"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Watch me"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(runner)
    %{conn: put_req_header(conn, "accept", "application/json"), job: job, runner: runner}
  end

  @lines ~s({"type":"assistant","timestamp":"2026-11-06T12:13:07Z","message":{"content":[{"type":"text","text":"Hello"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}\n) <>
           ~s({"type":"user","timestamp":"2026-11-06T12:13:08Z","message":{"content":[{"type":"tool_result","content":"a\\nb"}]}}\n)

  test "the entries so far, then only what came since", ctx do
    body = json_response(get(ctx.conn, "/api/jobs/#{ctx.job.id}/log"), 200)
    assert body["entries"] == []
    assert body["next"] == 0

    assert body["job"] == %{
             "id" => ctx.job.id,
             "card_id" => ctx.job.card_id,
             "status" => "claimed",
             "open" => true
           }

    {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, @lines)
    body = json_response(get(ctx.conn, "/api/jobs/#{ctx.job.id}/log"), 200)
    assert body["next"] == 2
    assert body["capped"] == false

    assert Enum.map(body["entries"], & &1["line"]) == [
             "12:13:07  💬 Hello",
             "12:13:07  ▶ Bash: ls",
             "12:13:08     ↳ a  (+1 lines)"
           ]

    assert [%{"kind" => "message", "id" => "0-0"}, %{"kind" => "tool", "detail" => detail}, _] =
             body["entries"]

    assert detail =~ ~s("command": "ls")

    body = json_response(get(ctx.conn, "/api/jobs/#{ctx.job.id}/log?from=1"), 200)
    assert [%{"id" => "1-0", "kind" => "result"}] = body["entries"]
    assert body["from"] == 1

    # Past the end, or not a number: nothing new, and next never goes back.
    body = json_response(get(ctx.conn, "/api/jobs/#{ctx.job.id}/log?from=9"), 200)
    assert body["entries"] == [] and body["next"] == 9
    assert json_response(get(ctx.conn, "/api/jobs/#{ctx.job.id}/log?from=x"), 200)["from"] == 0
  end

  test "an ended job says it is no longer open", ctx do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "1"})
    body = json_response(get(ctx.conn, "/api/jobs/#{ctx.job.id}/log"), 200)
    assert body["job"]["open"] == false
    assert body["job"]["status"] == "failed"
  end

  test "someone who can't read the card can't read its log (403), and an unknown job is 404",
       ctx do
    outsider = conn_as(user_fixture("out#{System.unique_integer([:positive])}@example.com"))
    assert get(outsider, "/api/jobs/#{ctx.job.id}/log").status == 403
    assert get(ctx.conn, "/api/jobs/999999999/log").status == 404
  end
end
