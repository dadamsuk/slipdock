defmodule Slipdock.Runners.TroubleTest do
  # A job its agent couldn't run on the machine (a usage limit, a sign-in
  # failure, #2920) goes back to the queue, uncounted, its card untouched,
  # and the board hears once (`Slipdock.Runners.Trouble`).
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners}
  alias Slipdock.Automations.Alert
  alias Slipdock.Runners.{Job, Runner, Trouble}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Trouble"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    {:ok, other, _} = Runners.create_runner(board, %{"name" => "box-2", "pool" => "loop"})
    a = card_fixture(todo, %{"title" => "a"})
    b = card_fixture(todo, %{"title" => "b"})

    # The rule puts back a card its job leaves in progress, once, then
    # flags it blocked: what a limit used to do to every card in the queue.
    rule =
      rule_fixture(board, %{
        "trigger" => %{"type" => "list_top", "column" => "To Do"},
        "actions" => [%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 1}]
      })

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      runner: runner,
      other: other,
      a: a,
      b: b,
      rule: rule
    }
  end

  @limit %{
    status: "requeue",
    exit: "1",
    trouble: "limit",
    until: "2026-11-15T18:00:00Z",
    reason: "You've hit your weekly limit · resets Nov 15, 6pm",
    output: "You've hit your weekly limit · resets Nov 15, 6pm\n"
  }

  defp alerts(board),
    do: Repo.all(from(a in Alert, where: a.board_id == ^board.id, order_by: [asc: a.id]))

  defp card(card), do: Boards.Cards.get_card!(card.id)

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  test "the job goes back to the queue, uncounted, its card untouched", ctx do
    job = Runners.claim(ctx.runner)
    assert job.card_id == ctx.a.id
    assert job.attempts == 1

    assert {:ok, requeued} = Runners.finish(ctx.runner, job.id, @limit)

    assert requeued.status == "queued"
    assert requeued.attempts == 0
    assert requeued.runner_id == nil
    assert requeued.last_runner_id == nil
    assert requeued.lease_expires_at == nil
    assert requeued.finished_at == nil
    assert requeued.recovery == nil
    assert requeued.output =~ "weekly limit"
    assert Repo.get!(Runner, ctx.runner.id).current_job_id == nil

    a = card(ctx.a)
    refute "blocked" in a.flags
    assert comments(ctx.a) == []
    assert Boards.Handoffs.current_handoff(a) == nil

    # No other card was fed in its place: the same job is next.
    assert Repo.aggregate(from(j in Job, where: j.rule_id == ^ctx.rule.id), :count) == 1
    assert Runners.claim(ctx.other).id == job.id
  end

  test "no rule hears a job finished", ctx do
    rule_fixture(ctx.board, %{
      "trigger" => %{"type" => "job_finished"},
      "actions" => [%{"type" => "comment", "body" => "a job ended"}]
    })

    job = Runners.claim(ctx.runner)
    {:ok, _} = Runners.finish(ctx.runner, job.id, @limit)

    assert comments(ctx.a) == []
  end

  test "however many times it happens, the card is never flagged", ctx do
    for runner <- [ctx.runner, ctx.other, ctx.runner, ctx.other] do
      job = Runners.claim(runner)
      assert job.card_id == ctx.a.id
      {:ok, _} = Runners.finish(runner, job.id, @limit)
    end

    a = card(ctx.a)
    refute "blocked" in a.flags
    assert Repo.get_by!(Job, card_id: ctx.a.id).attempts == 0
  end

  test "one alert for the episode, however many jobs and runners on the machine it stopped",
       ctx do
    {:ok, key, _} = Slipdock.Machines.create_enrolment_key(ctx.owner, [ctx.board.id])

    {:ok, {_, machine}} =
      Slipdock.Machines.enrol_with_key(key, %{
        "hostname" => "build-box",
        "os" => "linux",
        "arch" => "amd64"
      })

    Repo.update_all(from(r in Runner, where: r.id in ^[ctx.runner.id, ctx.other.id]),
      set: [machine_id: machine.id]
    )

    for runner <- [ctx.runner, ctx.other, ctx.runner] do
      runner = Repo.get!(Runner, runner.id)
      job = Runners.claim(runner)
      {:ok, _} = Runners.finish(runner, job.id, @limit)
    end

    assert [alert] = alerts(ctx.board)
    assert alert.severity == "warning"
    assert alert.card_id == nil
    assert alert.title == "Runners on #{machine.name} stopped: the agent hit its usage limit"
    assert alert.body =~ "weekly limit"
    assert alert.body =~ "2026-11-15 18:00 UTC"
    assert alert.body =~ "card untouched"
  end

  test "an exit before any work says the agent can't start, with its own alert", ctx do
    job = Runners.claim(ctx.runner)

    {:ok, _} =
      Runners.finish(ctx.runner, job.id, %{
        status: "requeue",
        exit: "1",
        trouble: "quick_exit",
        until: "not a time",
        reason: "the agent exited 1 after 2s, before a tool call"
      })

    assert [alert] = alerts(ctx.board)
    assert alert.title == "Runners on runner box stopped: the agent can't start"
    assert alert.body =~ "hold off and try again"
    assert Repo.get!(Job, job.id).status == "queued"
  end

  test "the activity says what happened", ctx do
    job = Runners.claim(ctx.runner)
    {:ok, _} = Runners.finish(ctx.runner, job.id, @limit)

    assert Repo.exists?(
             from(a in Boards.Activity,
               where:
                 a.card_id == ^ctx.a.id and
                   like(a.message, "%couldn't run job%usage limit%uncounted")
             )
           )
  end

  test "a job asked to cancel ends cancelled", ctx do
    job = Runners.claim(ctx.runner)
    {:ok, _} = Runners.cancel_job(job)

    {:ok, ended} = Runners.finish(ctx.runner, job.id, @limit)

    assert ended.status == "cancelled"
    assert alerts(ctx.board) == []
  end

  test "a job with an open wait ends parked", ctx do
    job = Runners.claim(ctx.runner)

    {:ok, _} =
      Boards.Waits.open_wait(card(ctx.a), Actor.runner(ctx.owner, job.id), %{
        "needs" => "Which region?",
        "job_id" => job.id
      })

    {:ok, ended} = Runners.finish(ctx.runner, job.id, @limit)

    assert ended.status == "parked"
  end

  test "a runner that no longer holds the job changes nothing", ctx do
    job = Runners.claim(ctx.runner)
    assert {:error, :not_found} = Trouble.requeue(ctx.other, job, @limit)
    assert Repo.get!(Job, job.id).status == "claimed"
    assert alerts(ctx.board) == []
  end

  test "a finish sent again after the requeue is not the runner's job any more", ctx do
    job = Runners.claim(ctx.runner)
    {:ok, _} = Runners.finish(ctx.runner, job.id, @limit)

    assert {:error, :not_found} = Runners.finish(ctx.runner, job.id, @limit)
    assert Repo.get!(Job, job.id).status == "queued"
  end

  test "an alert dismissed long ago doesn't silence the next episode", ctx do
    job = Runners.claim(ctx.runner)
    {:ok, _} = Runners.finish(ctx.runner, job.id, @limit)
    [alert] = alerts(ctx.board)
    old = DateTime.add(DateTime.utc_now(), -7 * 3600) |> DateTime.truncate(:second)
    Repo.update_all(from(a in Alert, where: a.id == ^alert.id), set: [inserted_at: old])

    job = Runners.claim(ctx.runner)
    {:ok, _} = Runners.finish(ctx.runner, job.id, @limit)

    assert length(alerts(ctx.board)) == 2
  end
end
