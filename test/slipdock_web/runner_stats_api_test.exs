defmodule SlipdockWeb.RunnerStatsAPITest do
  @moduledoc """
  How a board's runners are doing (#1187) through the doors agents use:
  `GET /api/boards/:board/runner_stats?days=` and MCP `get_board` with
  `runners: true` agree, and a board the caller can't read is refused.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.Job

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Agents"}, owner: user)
    [_backlog, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Built by a runner"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "dev-box", "pool" => "dev"})
    now = DateTime.utc_now(:second)

    Repo.insert!(%Job{
      pool: "dev",
      kind: "claude",
      prompt: "do it",
      status: "done",
      board_id: board.id,
      root_board_id: board.id,
      card_id: card.id,
      runner_id: runner.id,
      claimed_at: DateTime.add(now, -600),
      finished_at: DateTime.add(now, -60)
    })

    conn = put_req_header(conn, "accept", "application/json")
    %{conn: conn, board: board}
  end

  defp rest(conn, board, query \\ ""),
    do: conn |> get("/api/boards/#{board.code}/runner_stats#{query}") |> json_response(200)

  defp mcp(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "get_board", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "REST gives each runner and the recent jobs", %{conn: conn, board: board} do
    body = rest(conn, board, "?days=7")
    assert body["board"] == %{"id" => board.id, "code" => board.code}

    stats = body["runner_stats"]
    assert stats["days"] == 7
    assert [r] = stats["runners"]
    assert %{"name" => "dev-box", "pool" => "dev", "status" => "offline"} = r
    assert r["outcomes"]["done"] == 1
    assert r["success_rate"] == 1.0
    assert r["duration"] == %{"p50" => 540, "p85" => 540}

    assert [%{"title" => "Built by a runner", "outcome" => "done", "duration" => 540}] =
             stats["recent_jobs"]
  end

  test "MCP get_board runners:true agrees", %{conn: conn, board: board} do
    stats = rest(conn, board)["runner_stats"]
    result = mcp(conn, %{board: board.code, runners: true})
    assert result["isError"] == false, inspect(result["content"])
    content = result["structuredContent"]
    refute Map.has_key?(content, "lists")
    # Both read the clock: "at" and "since" may be a second apart.
    assert Map.drop(content["runner_stats"], ~w(at since)) == Map.drop(stats, ~w(at since))
  end

  test "a board with no runners is an empty answer", %{conn: conn, user: user} do
    quiet = board_fixture(%{"name" => "Quiet"}, owner: user)
    assert %{"runners" => [], "recent_jobs" => []} = rest(conn, quiet)["runner_stats"]
  end

  test "a board the caller can't read is refused, on both doors", %{conn: conn} do
    theirs = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("other@example.com"))
    assert conn |> get("/api/boards/#{theirs.code}/runner_stats") |> json_response(404)
    assert mcp(conn, %{board: theirs.code, runners: true})["isError"] == true
  end
end
