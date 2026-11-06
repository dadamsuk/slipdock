defmodule SlipdockWeb.MCP.KeepJobLogTest do
  @moduledoc """
  `keep_job_log` (#1872): Keep this log over MCP, and `update_board`
  setting how long a board's job logs stay.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Runners.{Job, Transcript}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Agents"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the parser"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(runner)

    {:ok, 1} =
      Transcript.append(
        runner,
        job.id,
        0,
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}\n)
      )

    %{conn: conn, job: job, runner: runner, card: card, board: board}
  end

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

  test "is offered as a write that destroys nothing", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    tool = Enum.find(tools, &(&1["name"] == "keep_job_log"))
    assert tool["annotations"]["readOnlyHint"] == false
    assert tool["annotations"]["destructiveHint"] == false
  end

  test "keeps an ended job's log as a page, and again gives the same page", ctx do
    assert ctx.conn |> call("keep_job_log", %{job: ctx.job.id}) |> error!() =~ "still running"

    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})
    out = ctx.conn |> call("keep_job_log", %{job: ctx.job.id}) |> ok!()

    assert out["page"]["title"] =~ "Pass #{ctx.card.id} ("
    assert out["page"]["code"]
    assert out["job"]["id"] == ctx.job.id
    assert Repo.get!(Job, ctx.job.id).transcript_page_id == out["page"]["id"]

    again = ctx.conn |> call("keep_job_log", %{job: ctx.job.id}) |> ok!()
    assert again["page"]["id"] == out["page"]["id"]
  end

  test "a reader, an unknown job and a bad id are refused", ctx do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})
    reader = user_fixture("reader#{System.unique_integer([:positive])}@example.com")
    share_fixture(ctx.board, [reader], "read")

    assert conn_as(reader) |> call("keep_job_log", %{job: ctx.job.id}) |> error!() =~ "don't"
    assert ctx.conn |> call("keep_job_log", %{job: 999_999_999}) |> error!() =~ "no job"
    assert ctx.conn |> call("keep_job_log", %{job: "x"}) |> error!() =~ "job must be"
    refute Repo.get!(Job, ctx.job.id).transcript_page_id
  end

  test "update_board sets how long job logs stay", ctx do
    ctx.conn
    |> call("update_board", %{board: ctx.board.id, job_log_hours: 12, failure_log_hours: 72})
    |> ok!()

    board = Boards.get_board!(ctx.board.id)
    assert {board.job_log_hours, board.failure_log_hours} == {12, 72}

    assert ctx.conn |> call("update_board", %{board: ctx.board.id, job_log_hours: 0}) |> error!() =~
             "job_log_hours"
  end
end
