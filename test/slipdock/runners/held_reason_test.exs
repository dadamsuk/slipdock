defmodule Slipdock.Runners.HeldReasonTest do
  @moduledoc """
  One held reason (#1116, KTD12): a queued job says the first of paused,
  WIP full, waiting on a card in progress, and no runner online — the last
  never to the runner asking.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Boards.Board
  alias Slipdock.Runners.{Job, Runner}

  setup do
    owner = user_fixture() |> Ecto.Changeset.change(name: "David") |> Repo.update!()
    board = board_fixture(%{"name" => "Held"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    %{owner: owner, board: board, todo: todo, doing: doing, runner: runner}
  end

  defp seen(runner, seconds_ago) do
    at = DateTime.utc_now() |> DateTime.add(-seconds_ago) |> DateTime.truncate(:second)
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [last_seen_at: at])
  end

  defp queue(card, wait \\ false),
    do: Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go", wait_while_doing: wait})

  describe "no runner online" do
    test "shows when the pool's only runner was last seen over three leases ago", ctx do
      seen(ctx.runner, 3 * Runners.lease_seconds() + 30)
      {:ok, job} = queue(card_fixture(ctx.todo))

      assert Runners.held_reason(job) == "No runner online for pool dev"
      assert SlipdockWeb.API.JSON.job(job).waiting_on == "No runner online for pool dev"
    end

    test "not for a runner seen within three leases", ctx do
      seen(ctx.runner, 2 * Runners.lease_seconds())
      {:ok, job} = queue(card_fixture(ctx.todo))
      assert Runners.held_reason(job) == nil
    end

    test "never in the claimant's own answer: the stale runner just takes the job", ctx do
      seen(ctx.runner, 10 * Runners.lease_seconds())
      {:ok, job} = queue(card_fixture(ctx.todo))

      assert Runners.held_reason(job, claimant: true) == nil
      assert Runners.held(ctx.board, "dev") == nil
      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == job.id
    end

    test "a job that isn't queued is held by nothing", ctx do
      {:ok, job} = queue(card_fixture(ctx.todo))
      claimed = Runners.claim(ctx.runner)
      assert claimed.id == job.id
      assert Runners.held_reason(claimed) == nil
    end
  end

  test "with several reasons at once, the first in order is shown", ctx do
    Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [automation_wip: true])
    ctx.doing |> Ecto.Changeset.change(wip_limit: 1) |> Repo.update!()
    busy = card_fixture(ctx.doing, %{"title" => "Busy"})
    {:ok, job} = queue(card_fixture(ctx.todo), true)

    {:ok, _} = Runners.pause(ctx.board, %{"pool" => "dev", "reason" => "bad deploy"}, ctx.owner)
    assert Runners.held_reason(job) == "paused by David: bad deploy"

    {:ok, _} = Runners.resume(ctx.board, "dev", ctx.owner, Slipdock.Actor.web(ctx.owner))
    assert Runners.held_reason(job) == "WIP full: #{ctx.doing.name} 1/1"

    Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [automation_wip: false])
    assert Runners.held_reason(job) == "##{busy.id} is in progress"

    {:ok, _} = Slipdock.Boards.toggle_completed(busy)
    # Never seen at all: no runner online.
    assert Runners.held_reason(job) == "No runner online for pool dev"
  end
end
