defmodule SlipdockWeb.API.RunnersTest do
  # Both HTTP faces of the job queue: the plain-text protocol a runner speaks
  # with its own token, and the JSON endpoints people and agents use to make
  # runners, read jobs and cancel them.
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo, Runners}
  alias Slipdock.Runners.Job

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Runner API"}, owner: user)
    [todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Do the thing"})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      card: card,
      runner: runner,
      token: token
    }
  end

  defp runner_conn(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "text/plain")
  end

  defp queue(card, prompt \\ "Work on it"),
    do: Runners.queue(card, %{pool: "dev", kind: "claude", prompt: prompt})

  describe "POST /api/runner/claim" do
    test "204 and an empty body when there is nothing to do", %{token: token} do
      conn = post(runner_conn(token), "/api/runner/claim?wait=0")
      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "200 with the job in headers and the prompt as the body", ctx do
      {:ok, job} = queue(ctx.card, "Line one\n\"quoted\" $(not run)")
      conn = post(runner_conn(ctx.token), "/api/runner/claim?wait=0")

      assert conn.status == 200
      assert get_resp_header(conn, "x-job-id") == [to_string(job.id)]
      assert get_resp_header(conn, "x-job-kind") == ["claude"]
      assert get_resp_header(conn, "x-card-id") == [to_string(ctx.card.id)]
      assert get_resp_header(conn, "x-card-ref") == ["##{ctx.card.id}"]
      assert [url] = get_resp_header(conn, "x-card-url")
      assert url =~ "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
      assert get_resp_header(conn, "x-lease-seconds") == ["90"]
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
      assert conn.resp_body == "Line one\n\"quoted\" $(not run)"
    end

    test "naming another pool is refused", ctx do
      conn = post(runner_conn(ctx.token), "/api/runner/claim?pool=gpu&wait=0")
      assert conn.status == 403
      assert conn.resp_body =~ "this runner token is for pool dev"

      assert post(runner_conn(ctx.token), "/api/runner/claim?pool=dev&wait=0").status == 204
    end

    test "no token, a wrong one, or an API token is a 401", ctx do
      assert post(build_conn(), "/api/runner/claim").status == 401
      assert post(runner_conn("sdr_nope"), "/api/runner/claim").status == 401

      {api_token, _} = Accounts.create_api_token(ctx.user, "agent")
      conn = post(runner_conn(api_token), "/api/runner/claim")
      assert conn.status == 401
      assert conn.resp_body =~ "runner token"
    end

    test "a revoked runner's token stops working", ctx do
      {:ok, _} = Runners.delete_runner(ctx.runner)
      assert post(runner_conn(ctx.token), "/api/runner/claim?wait=0").status == 401
    end
  end

  describe "heartbeat and finish" do
    setup ctx do
      {:ok, _} = queue(ctx.card)
      %{job: Runners.claim(ctx.runner)}
    end

    test "a heartbeat's body is the log, whatever curl calls it, and the answer is ok", ctx do
      conn =
        runner_conn(ctx.token)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/api/runner/jobs/#{ctx.job.id}/heartbeat", "a=b&c=d\nmore log")

      assert conn.status == 200
      assert conn.resp_body == "ok\n"
      assert Repo.get!(Job, ctx.job.id).log_tail == "a=b&c=d\nmore log"
    end

    test "after a cancel, the heartbeat says cancel", ctx do
      {:ok, _} = Runners.cancel_job(Repo.get!(Job, ctx.job.id))
      conn = post(runner_conn(ctx.token), "/api/runner/jobs/#{ctx.job.id}/heartbeat", "")
      assert conn.resp_body == "cancel\n"
    end

    test "finish records the exit code, status and output", ctx do
      conn =
        runner_conn(ctx.token)
        |> post("/api/runner/jobs/#{ctx.job.id}/finish?exit=124&status=timeout", "ran out")

      assert conn.status == 200
      assert conn.resp_body == "ok timeout\n"

      job = Repo.get!(Job, ctx.job.id)
      assert {job.status, job.exit_code, job.output} == {"timeout", 124, "ran out"}
    end

    test "another runner's job is a 404 for both", ctx do
      {:ok, _, other} = Runners.create_runner(ctx.board, %{"name" => "other", "pool" => "dev"})

      assert post(runner_conn(other), "/api/runner/jobs/#{ctx.job.id}/heartbeat", "x").status ==
               404

      assert post(runner_conn(other), "/api/runner/jobs/#{ctx.job.id}/finish?exit=0", "").status ==
               404

      assert Repo.get!(Job, ctx.job.id).status == "claimed"
    end
  end

  describe "runners, for the board's owner" do
    test "making one returns the token once; listing never does", %{conn: conn, board: board} do
      body =
        conn
        |> post(~p"/api/boards/#{board.id}/runners", %{"name" => "laptop", "pool" => "dev"})
        |> json_response(201)

      assert "sdr_" <> _ = body["token"]
      assert body["runner"]["pool"] == "dev"

      listed = conn |> get(~p"/api/boards/#{board.id}/runners") |> json_response(200)
      assert Enum.any?(listed["runners"], &(&1["name"] == "laptop"))
      refute inspect(listed) =~ body["token"]
      refute Enum.any?(listed["runners"], &Map.has_key?(&1, "token"))

      # The token it gave is one the runner API takes.
      assert post(runner_conn(body["token"]), "/api/runner/claim?wait=0").status == 204
    end

    test "a bad pool is a validation error", %{conn: conn, board: board} do
      conn = post(conn, ~p"/api/boards/#{board.id}/runners", %{"name" => "x", "pool" => "a b"})
      assert %{"details" => %{"pool" => [_]}} = json_response(conn, 422)
    end

    test "revoking one ends its token", %{conn: conn, board: board, runner: runner, token: token} do
      assert %{"ok" => true} =
               conn
               |> delete(~p"/api/boards/#{board.id}/runners/#{runner.id}")
               |> json_response(200)

      assert post(runner_conn(token), "/api/runner/claim?wait=0").status == 401
    end

    test "somebody the board is only shared with can't make or see runners", %{board: board} do
      other = user_fixture("writer#{System.unique_integer([:positive])}@example.com")
      share_fixture(board, [other], "write")
      conn = conn_as(other) |> put_req_header("accept", "application/json")

      assert conn |> get(~p"/api/boards/#{board.id}/runners") |> json_response(403)

      assert conn
             |> post(~p"/api/boards/#{board.id}/runners", %{"name" => "x", "pool" => "dev"})
             |> json_response(403)
    end
  end

  describe "jobs" do
    test "a card's jobs and the board's, newest first", %{conn: conn, board: board, card: card} do
      {:ok, first} = queue(card)
      {:ok, second} = queue(card)

      body = conn |> get(~p"/api/cards/#{card.id}/jobs") |> json_response(200)
      assert Enum.map(body["jobs"], & &1["id"]) == [second.id, first.id]
      assert hd(body["jobs"])["status"] == "queued"

      body = conn |> get(~p"/api/boards/#{board.id}/jobs?status=open") |> json_response(200)
      assert length(body["jobs"]) == 2
      assert hd(body["jobs"])["card"] == "Do the thing"

      body = conn |> get(~p"/api/boards/#{board.id}/jobs?status=done") |> json_response(200)
      assert body["jobs"] == []
    end

    test "cancel: a queued job ends, a finished one is refused", %{conn: conn, card: card} do
      {:ok, job} = queue(card)

      body = conn |> post(~p"/api/jobs/#{job.id}/cancel") |> json_response(200)
      assert body["job"]["status"] == "cancelled"

      body = conn |> post(~p"/api/jobs/#{job.id}/cancel") |> json_response(422)
      assert body["error"] =~ "already finished"
    end

    test "a read-only token can read jobs but not cancel them", ctx do
      {:ok, job} = queue(ctx.card)
      {token, _} = Accounts.create_api_token(ctx.user, "ro", scope: "read")

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)

      assert conn |> get(~p"/api/jobs/#{job.id}") |> json_response(200)
      assert conn |> post(~p"/api/jobs/#{job.id}/cancel") |> json_response(403)
      assert Repo.get!(Job, job.id).status == "queued"
    end

    test "somebody who can't see the card can't see or cancel its jobs", ctx do
      {:ok, job} = queue(ctx.card)
      outsider = conn_as(user_fixture("out#{System.unique_integer([:positive])}@example.com"))
      outsider = put_req_header(outsider, "accept", "application/json")

      assert outsider |> get(~p"/api/jobs/#{job.id}") |> json_response(403)
      assert outsider |> post(~p"/api/jobs/#{job.id}/cancel") |> json_response(403)
      assert outsider |> get(~p"/api/jobs/999999999") |> json_response(404)
    end
  end
end
