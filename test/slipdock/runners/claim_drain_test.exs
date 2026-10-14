defmodule Slipdock.Runners.ClaimDrainTest do
  # A deploy stops the app with runners' claims still open. They must be
  # answered "nothing queued" before the endpoint drops them, or the proxy in
  # front turns each one into a 502.
  #
  # Sync: draining is node-wide, and the claims wait on other processes.
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.{ClaimDrain, Job}

  setup %{user: user} do
    on_exit(&ClaimDrain.reset/0)
    board = board_fixture(%{"name" => "Drain"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Queued"})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    %{card: card, runner: runner, token: token}
  end

  defp runner_conn(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "text/plain")
  end

  defp queue(card), do: Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

  # A claim waiting in another process, as on the endpoint's; answers
  # {result, milliseconds taken}.
  defp waiting_claim(runner, wait_ms) do
    task =
      Task.async(fn ->
        started = System.monotonic_time(:millisecond)
        result = Runners.claim(runner, wait_ms)
        {result, System.monotonic_time(:millisecond) - started}
      end)

    # Until it is subscribed, and so really waiting.
    wait_until(fn -> subscribed?(task.pid) end)
    task
  end

  defp subscribed?(pid) do
    Registry.keys(Slipdock.PubSub, pid) |> Enum.member?("runner_claims:drain")
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out waiting")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "stopping it answers a waiting claim with nothing, at once", %{runner: runner} do
    drain = start_supervised!({ClaimDrain, name: nil})
    refute Runners.draining?()

    task = waiting_claim(runner, 25_000)
    :ok = stop_supervised(ClaimDrain)

    assert {nil, took} = Task.await(task)
    assert took < 2_000
    refute Process.alive?(drain)
    assert Runners.draining?()
  end

  test "while draining a claim answers at once and hands out nothing", ctx do
    {:ok, queued} = queue(ctx.card)
    ClaimDrain.drain()

    started = System.monotonic_time(:millisecond)
    assert Runners.claim(ctx.runner, 5_000) == nil
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert Runners.claim(ctx.runner) == nil

    # Still queued, for the app that replaces this one.
    assert Repo.get!(Job, queued.id).status == "queued"

    ClaimDrain.reset()
    assert %Job{id: id} = Runners.claim(ctx.runner)
    assert id == queued.id
  end

  test "a claim still waits for work when nothing is draining", %{runner: runner} = ctx do
    task = waiting_claim(runner, 5_000)
    {:ok, queued} = queue(ctx.card)

    assert {%Job{id: id}, _took} = Task.await(task)
    assert id == queued.id
  end

  describe "POST /api/runner/claim" do
    test "while draining: 204, come back in a second, on a new connection", ctx do
      ClaimDrain.drain()
      conn = post(runner_conn(ctx.token), "/api/runner/claim?wait=25")

      assert conn.status == 204
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert get_resp_header(conn, "connection") == ["close"]
    end

    test "an ordinary empty answer has neither header", ctx do
      conn = post(runner_conn(ctx.token), "/api/runner/claim?wait=0")

      assert conn.status == 204
      assert get_resp_header(conn, "retry-after") == []
      assert get_resp_header(conn, "connection") == []
    end
  end

  test "the app starts it after the endpoint, so it stops first" do
    # Children stop in the reverse of the order they started in.
    started =
      Slipdock.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    drain = Enum.find_index(started, &(&1 == ClaimDrain))
    endpoint = Enum.find_index(started, &(&1 == SlipdockWeb.Endpoint))

    assert is_integer(drain) and is_integer(endpoint)
    assert drain > endpoint
  end
end
