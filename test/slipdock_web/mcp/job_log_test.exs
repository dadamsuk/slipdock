defmodule SlipdockWeb.MCP.JobLogTest do
  @moduledoc """
  `job_log` (#1871): a runner job's live log so far, over MCP, as
  `slipdock job-log` prints it, read on from an earlier call's `next`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Runners
  alias Slipdock.Runners.Transcript

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Agents"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the parser"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(runner)
    %{conn: conn, job: job, runner: runner, card: card}
  end

  defp call(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "job_log", arguments: args}
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

  defp say(n),
    do:
      ~s({"type":"assistant","timestamp":"2026-11-06T12:00:00Z","message":{"content":[{"type":"text","text":"#{n}"}]}}\n)

  test "tools/list offers it as a read", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    assert %{"annotations" => %{"readOnlyHint" => true}} =
             Enum.find(tools, &(&1["name"] == "job_log"))
  end

  test "reads the log so far, then on from next", ctx do
    {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, say("first") <> say("second"))
    out = ctx.conn |> call(%{job: ctx.job.id}) |> ok!()

    assert out["log"] == "12:00:00  💬 first\n12:00:00  💬 second"
    assert out["next"] == 2

    assert out["job"] == %{
             "id" => ctx.job.id,
             "card_id" => ctx.card.id,
             "status" => "claimed",
             "open" => true
           }

    {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 2, say("third"))
    out = ctx.conn |> call(%{job: ctx.job.id, from: 2}) |> ok!()
    assert out["log"] == "12:00:00  💬 third"
    assert out["next"] == 3

    assert ctx.conn |> call(%{job: ctx.job.id, from: 3}) |> ok!() |> Map.get("log") == ""

    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})

    assert %{"job" => %{"open" => false, "status" => "done"}} =
             ctx.conn |> call(%{job: ctx.job.id}) |> ok!()
  end

  test "a log too big for one answer stops at a whole line, and next carries on", ctx do
    word = String.duplicate("x", 150)
    # Each line formats to about 170 characters; job_log answers up to 100k.
    count = div(100_000, 170) + 20
    body = Enum.map_join(1..count, "", fn n -> say("#{n} #{word}") end)
    {:ok, ^count} = Transcript.append(ctx.runner, ctx.job.id, 0, body)

    first = ctx.conn |> call(%{job: ctx.job.id}) |> ok!()
    assert String.length(first["log"]) <= 100_000
    assert first["next"] < count
    shown = first["log"] |> String.split("\n") |> length()
    assert first["next"] == shown

    rest = ctx.conn |> call(%{job: ctx.job.id, from: first["next"]}) |> ok!()
    assert rest["next"] == count
    assert rest["log"] =~ ~r/\A12:00:00  💬 #{shown + 1} x/
  end

  test "a job you can't see, a bad id and a bad from are refused", ctx do
    outsider = conn_as(user_fixture("out#{System.unique_integer([:positive])}@example.com"))
    assert outsider |> call(%{job: ctx.job.id}) |> error!() =~ "don't read this card"

    assert ctx.conn |> call(%{job: 999_999_999}) |> error!() =~ "no job you can see"
    assert ctx.conn |> call(%{job: "x"}) |> error!() =~ "job must be"
    assert ctx.conn |> call(%{job: ctx.job.id, from: -1}) |> error!() =~ "from must be"
    assert ctx.conn |> call(%{job: ctx.job.id, from: "2"}) |> error!() =~ "from must be"
  end
end
