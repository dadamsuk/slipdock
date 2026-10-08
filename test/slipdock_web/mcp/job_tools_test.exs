defmodule SlipdockWeb.MCP.JobToolsTest do
  @moduledoc """
  `claim_job`, `job_progress` and `finish_job`: a Claude session taking runner
  jobs with its API token, from the same queue — with the same leases and
  cancels — as the runners on people's machines.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo, Runners}
  alias Slipdock.Runners.{Job, Runner}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Agents"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the parser"})
    %{conn: conn, board: board, card: card}
  end

  defp queue(card, pool \\ "default"),
    do: Runners.queue(card, %{pool: pool, kind: "claude", prompt: "Work on it"})

  defp call(conn, name, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ok!(result) do
    assert result["isError"] == false, inspect(result["content"])
    [%{"text" => text}] = result["content"]
    result["structuredContent"] || Jason.decode!(text)
  end

  defp error!(result) do
    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    text
  end

  defp claim!(ctx, conn \\ nil),
    do:
      (conn || ctx.conn) |> call("claim_job", %{board: ctx.board.code, pool: "default"}) |> ok!()

  test "tools/list offers all three as writes that destroy nothing", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1["annotations"]})

    for name <- ~w(claim_job job_progress finish_job) do
      assert tools[name]["readOnlyHint"] == false, name
      assert tools[name]["destructiveHint"] == false, name
    end
  end

  describe "claim_job" do
    test "with nothing queued, says so in as few words as it can", ctx do
      assert ctx |> claim!() == "nothing queued"
    end

    test "takes the job, and the session shows in the runner list", ctx do
      {:ok, job} = queue(ctx.card)

      out = claim!(ctx)
      assert out["job"] == job.id
      assert out["card"] == ctx.card.id
      assert out["kind"] == "claude"
      assert out["prompt"] == "Work on it"
      assert out["card_url"] =~ "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
      # A session works between reports, so its lease is far longer than a
      # shell runner's 90 seconds.
      assert out["lease_seconds"] == 1200
      lease = Repo.get!(Job, job.id).lease_expires_at
      assert DateTime.diff(lease, DateTime.utc_now()) in 1190..1201

      assert [%Runner{name: "test (session)", pool: "default"} = runner] =
               Runners.list_runners(ctx.board)

      assert Runner.session?(runner)
      assert runner.last_seen_at
      assert Repo.get!(Job, job.id).runner_id == runner.id

      # Asking again is the same runner, not another.
      claim!(ctx)
      assert length(Runners.list_runners(ctx.board)) == 1
    end

    test "only its pool", ctx do
      {:ok, _} = queue(ctx.card, "gpu")
      assert claim!(ctx) == "nothing queued"
    end

    test "a shell runner and a session never both get one job", ctx do
      {:ok, job} = queue(ctx.card)
      {:ok, shell, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "default"})

      assert %Job{id: id} = Runners.claim(shell)
      assert id == job.id
      assert claim!(ctx) == "nothing queued"

      {:ok, second} = queue(ctx.card)
      assert claim!(ctx)["job"] == second.id
      assert Runners.claim(shell) == nil
    end

    test "needs write access to the board", ctx do
      reader = user_fixture("reader#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [reader], "read")
      {:ok, _} = queue(ctx.card)

      assert conn_as(reader)
             |> call("claim_job", %{board: ctx.board.code, pool: "default"})
             |> error!() =~
               "edit"

      assert Repo.one(from(j in Job, select: j.status)) == "queued"
    end

    test "a read-only token is told not to retry", ctx do
      {token, _} = Accounts.create_api_token(ctx.user, "ro", scope: "read")
      conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

      assert call(conn, "claim_job", %{board: ctx.board.code, pool: "default"}) |> error!() =~
               "read-only"
    end

    test "a pool that isn't a plain name is refused", ctx do
      assert call(ctx.conn, "claim_job", %{board: ctx.board.code, pool: "a b"}) |> error!() =~
               "pool"
    end
  end

  describe "job_progress and finish_job" do
    setup ctx do
      {:ok, job} = queue(ctx.card)
      claim!(ctx)
      %{job: job}
    end

    test "progress renews the lease, notes go on the card, and finishing ends the job", ctx do
      out = ctx.conn |> call("job_progress", %{job: ctx.job.id, note: "Tests written."}) |> ok!()
      assert out == %{"job" => ctx.job.id, "status" => "ok"}

      job = Repo.get!(Job, ctx.job.id)
      assert job.status == "running"
      assert job.log_tail == "Tests written."

      card = Slipdock.Boards.get_card!(ctx.card.id) |> Repo.preload(:comments)
      assert Enum.any?(card.comments, &(&1.body == "Tests written."))

      out =
        ctx.conn
        |> call("finish_job", %{job: ctx.job.id, outcome: "done", summary: "Fixed in abc1234"})
        |> ok!()

      assert out == %{"job" => ctx.job.id, "status" => "done"}

      assert %Job{status: "done", exit_code: 0, output: "Fixed in abc1234"} =
               Repo.get!(Job, ctx.job.id)
    end

    test "after a cancel, progress says cancel", ctx do
      {:ok, _} = Runners.cancel_job(Repo.get!(Job, ctx.job.id))

      assert %{"status" => "cancel"} =
               ctx.conn |> call("job_progress", %{job: ctx.job.id}) |> ok!()

      assert %{"status" => "cancelled"} =
               ctx.conn |> call("finish_job", %{job: ctx.job.id, outcome: "done"}) |> ok!()
    end

    test "an outcome it doesn't know is refused", ctx do
      assert ctx.conn |> call("finish_job", %{job: ctx.job.id, outcome: "meh"}) |> error!() =~
               "outcome"

      assert Repo.get!(Job, ctx.job.id).status == "claimed"
    end

    test "a job claimed with another token is not this one's", ctx do
      other = conn_as(ctx.user)

      assert other |> call("job_progress", %{job: ctx.job.id}) |> error!() =~
               "wasn't claimed with this token"

      assert other |> call("finish_job", %{job: ctx.job.id, outcome: "done"}) |> error!() =~
               "wasn't claimed"

      assert ctx.conn |> call("job_progress", %{job: 0}) |> error!() =~ "job must be"
      assert ctx.conn |> call("job_progress", %{job: 999_999_999}) |> error!() =~ "no job"
    end

    test "a lease the session let run out goes back to the queue", ctx do
      past = DateTime.utc_now() |> DateTime.add(-5) |> DateTime.truncate(:second)
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id), set: [lease_expires_at: past])
      Runners.sweep()

      assert Repo.get!(Job, ctx.job.id).status == "queued"
      assert ctx.conn |> call("job_progress", %{job: ctx.job.id}) |> error!() =~ "wasn't claimed"
    end
  end
end
