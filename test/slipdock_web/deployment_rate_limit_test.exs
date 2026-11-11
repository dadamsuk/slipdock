defmodule SlipdockWeb.DeploymentRateLimitTest do
  @moduledoc "Deploys are rate-limited per board (#1134). Sync: it turns the limiter on."
  # Sync: it turns the rate limiter on with Application.put_env and resets
  # its counts, which are one table for the node.
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments}

  # Half a minute into one of the limiter's one-minute windows. The clock is
  # pinned there (TEST-13), so the burst and the requests after it count in
  # one window whatever second the test starts at (#2773).
  @mid_window 500 * 3_600_000 + 30_000

  test "past the limit a board's deploys get a 429 with Retry-After", %{user: user} do
    previous = Application.get_env(:slipdock, :rate_limit)
    Application.put_env(:slipdock, :rate_limit, enabled: true, now: @mid_window)
    Slipdock.RateLimit.reset()

    on_exit(fn ->
      Application.put_env(:slipdock, :rate_limit, previous)
      Slipdock.RateLimit.reset()
    end)

    board = board_fixture(%{"name" => "Busy"}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    {:ok, token, _} = Deployments.issue_token(board)

    last = fn ->
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/deployments/last")
    end

    # One short of the limit: the next request is the last one allowed, so
    # the 429 after it is the limit's doing, not the endpoint's.
    for _ <- 1..119 do
      assert Slipdock.RateLimit.hit("deployments:#{board.id}", 120, 60_000) == :ok
    end

    assert json_response(last.(), 200)

    conn = last.()

    assert json_response(conn, 429)["error"] =~ "too many deploys"
    # The window has 30 s left; the limiter rounds up.
    assert get_resp_header(conn, "retry-after") == ["31"]
  end
end
