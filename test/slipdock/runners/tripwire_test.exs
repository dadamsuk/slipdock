defmodule Slipdock.Runners.TripwireTest do
  # A job whose proxy saw its fake credentials leaving (#3524): the runner
  # daemon stops it and says so in its finish; the server pauses the
  # runner's pool and raises an urgent alert (`Slipdock.Runners.Tripwire`).
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Automations.Alert
  alias Slipdock.Runners.{Job, Pause}

  @seen "the AWS access key id, in the request line, going to x.evil.example.net:80"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Tripwire"}, owner: user)
    [todo | _] = board.columns
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, other, _} = Runners.create_runner(board, %{"name" => "box-2", "pool" => "dev"})
    {:ok, elsewhere, _} = Runners.create_runner(board, %{"name" => "box-3", "pool" => "ops"})
    a = card_fixture(todo, %{"title" => "a"})
    b = card_fixture(todo, %{"title" => "b"})
    c = card_fixture(todo, %{"title" => "c"})
    {:ok, _} = Runners.queue(a, %{pool: "dev", kind: "claude", prompt: "a"})
    {:ok, _} = Runners.queue(b, %{pool: "dev", kind: "claude", prompt: "b"})
    {:ok, _} = Runners.queue(c, %{pool: "ops", kind: "claude", prompt: "c"})

    %{
      board: board,
      runner: runner,
      token: token,
      other: other,
      elsewhere: elsewhere,
      a: a,
      job: Runners.claim(runner)
    }
  end

  defp alerts(board),
    do: Repo.all(from(a in Alert, where: a.board_id == ^board.id, order_by: [asc: a.id]))

  defp finish(ctx, query) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "text/plain")
    |> post("/api/runner/jobs/#{ctx.job.id}/finish?" <> URI.encode_query(query), "the log")
  end

  test "a tripped job ends failed, its pool is paused and the board alerted", ctx do
    assert ctx.job.card_id == ctx.a.id
    conn = finish(ctx, %{"exit" => "137", "status" => "failed", "tripwire" => @seen})
    assert conn.resp_body == "ok failed\n"

    job = Repo.get!(Job, ctx.job.id)
    assert {job.status, job.exit_code} == {"failed", 137}

    pause = Runners.pause_for(ctx.board.id, "dev")
    assert %Pause{pool: "dev", paused_by_id: nil, agent: "tripwire"} = pause

    assert Pause.line(Repo.preload(pause, :paused_by)) ==
             "paused by tripwire: job ##{job.id} on box sent its fake credentials out"

    assert [alert] = alerts(ctx.board)
    assert alert.severity == "urgent"
    assert alert.card_id == ctx.a.id
    assert alert.title == "Tripwire: job ##{job.id} on box sent its fake credentials out"
    assert alert.body =~ "its network proxy saw #{@seen}."
    assert alert.body =~ "Pool dev is paused until a person resumes it."

    # Nothing more from the pool, for any of its runners; another pool runs.
    assert Runners.claim(ctx.other) == nil
    assert Runners.claim(ctx.runner) == nil
    assert %Job{pool: "ops"} = Runners.claim(ctx.elsewhere)
  end

  test "a tripped job never ends done, whatever it says", ctx do
    finish(ctx, %{"exit" => "0", "tripwire" => @seen})
    assert Repo.get!(Job, ctx.job.id).status == "failed"
    assert Runners.pause_for(ctx.board.id, "dev")
  end

  test "it never goes back to the queue as a machine's trouble", ctx do
    finish(ctx, %{
      "exit" => "1",
      "status" => "requeue",
      "trouble" => "quick_exit",
      "until" => "2026-11-15T18:00:00Z",
      "tripwire" => @seen
    })

    assert Repo.get!(Job, ctx.job.id).status == "failed"
    assert Runners.pause_for(ctx.board.id, "dev")
  end

  test "a pool paused already stays as it was, and the board still hears", ctx do
    {:ok, before} =
      Runners.pause(ctx.board, %{"pool" => "dev", "reason" => "bad deploy"}, nil)

    finish(ctx, %{"exit" => "137", "status" => "failed", "tripwire" => @seen})

    assert Runners.pause_for(ctx.board.id, "dev").id == before.id
    assert Repo.get!(Job, ctx.job.id).status == "failed"
    assert [%Alert{severity: "urgent"}] = alerts(ctx.board)
  end

  test "a finish without one, or with a blank one, trips nothing", ctx do
    finish(ctx, %{"exit" => "1", "status" => "failed", "tripwire" => " \n "})
    assert Repo.get!(Job, ctx.job.id).status == "failed"
    assert Runners.pause_for(ctx.board.id, "dev") == nil
    assert alerts(ctx.board) == []
  end

  test "what the runner says is cut to a line and kept short", ctx do
    long = "x\u0007\ny" <> String.duplicate("z", 500)
    finish(ctx, %{"exit" => "137", "status" => "failed", "tripwire" => long})
    [alert] = alerts(ctx.board)
    refute alert.body =~ "\u0007"
    refute alert.body =~ "x\ny"
    refute alert.body =~ String.duplicate("z", 200)
  end

  test "another runner's job trips nothing", ctx do
    {:ok, _, stranger} = Runners.create_runner(ctx.board, %{"name" => "box-4", "pool" => "dev"})

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> stranger)
      |> put_req_header("content-type", "text/plain")
      |> post(
        "/api/runner/jobs/#{ctx.job.id}/finish?" <>
          URI.encode_query(%{"exit" => "137", "tripwire" => @seen}),
        ""
      )

    assert conn.status == 404
    assert Runners.pause_for(ctx.board.id, "dev") == nil
    assert alerts(ctx.board) == []
  end
end
