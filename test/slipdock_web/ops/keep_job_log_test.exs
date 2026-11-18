defmodule SlipdockWeb.Ops.KeepJobLogTest do
  @moduledoc """
  `keep_job_log` defined once (#3188): REST's `POST /api/jobs/:id/keep` and
  the MCP tool keep an ended job's log alike, answer `{job, page}` (the page
  without its body), and refuse the same calls in the same words.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.{Job, Transcript}

  @said ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}\n)

  setup %{user: user} do
    board = board_fixture(%{"name" => "Keep", "code" => "kjl3188"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the parser"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(runner)
    {:ok, 1} = Transcript.append(runner, job.id, 0, @said)
    %{board: board, card: card, job: job, runner: runner}
  end

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.KeepJobLog
    assert tool.__op__() == SlipdockWeb.Ops.KeepJobLog
    assert tool.input_schema().required == ["job"]
    refute tool.read_only?()
    refute tool.destructive?()
  end

  test "REST and MCP keep it alike and answer the same {job, page}, without the body", ctx do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})

    rest = ctx.conn |> post("/api/jobs/#{ctx.job.id}/keep", %{}) |> json_response(200)
    assert {false, via_mcp} = call_mcp_tool(ctx.conn, "keep_job_log", %{job: ctx.job.id})

    assert rest["page"] == via_mcp["page"]
    assert Map.drop(rest["job"], ["updated_at"]) == Map.drop(via_mcp["job"], ["updated_at"])
    assert rest["page"]["title"] =~ "Pass #{ctx.card.id} ("
    refute Map.has_key?(rest["page"], "body")
    assert rest["job"]["transcript_page_id"] == rest["page"]["id"]
    assert Repo.get!(Job, ctx.job.id).transcript_page_id == rest["page"]["id"]
  end

  test "a running job, a bad id and an unknown job are refused in the same words", ctx do
    for {job, status} <- [{ctx.job.id, 422}, {"x", 400}] do
      %{"error" => rest} =
        ctx.conn |> post("/api/jobs/#{job}/keep", %{}) |> json_response(status)

      assert {true, ^rest} = call_mcp_tool(ctx.conn, "keep_job_log", %{job: job})
    end

    assert ctx.conn |> post("/api/jobs/999999999/keep", %{}) |> json_response(404)
    assert {true, text} = call_mcp_tool(ctx.conn, "keep_job_log", %{job: 999_999_999})
    assert text =~ "no job"
    refute Repo.get!(Job, ctx.job.id).transcript_page_id
  end

  test "a reader of the board is refused on both, and nothing is kept", ctx do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})
    reader = user_fixture("kjl3188.reader@example.com")
    share_fixture(ctx.board, [reader], "read")

    %{"error" => rest} =
      reader |> conn_as() |> post("/api/jobs/#{ctx.job.id}/keep", %{}) |> json_response(403)

    assert {true, ^rest} = call_mcp_tool(conn_as(reader), "keep_job_log", %{job: ctx.job.id})
    refute Repo.get!(Job, ctx.job.id).transcript_page_id
  end
end
