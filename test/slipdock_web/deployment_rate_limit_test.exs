defmodule SlipdockWeb.DeploymentRateLimitTest do
  @moduledoc "Deploys are rate-limited per board (#1134). Sync: it turns the limiter on."
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments}

  test "past the limit a board's deploys get a 429 with Retry-After", %{user: user} do
    previous = Application.get_env(:slipdock, :rate_limit)
    Application.put_env(:slipdock, :rate_limit, enabled: true)
    Slipdock.RateLimit.reset()
    on_exit(fn -> Application.put_env(:slipdock, :rate_limit, previous) end)

    board = board_fixture(%{"name" => "Busy"}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    {:ok, token, _} = Deployments.issue_token(board)

    for _ <- 1..120, do: Slipdock.RateLimit.hit("deployments:#{board.id}", 120, 60_000)

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/deployments/last")

    assert json_response(conn, 429)["error"] =~ "too many deploys"
    assert get_resp_header(conn, "retry-after") != []
  end
end
