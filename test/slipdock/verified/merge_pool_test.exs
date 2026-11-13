defmodule Slipdock.Verified.MergePoolTest do
  @moduledoc """
  Where a merge goes when no runner is idle and none decided the card
  (#2842): the last two choices of `Slipdock.Verified.merge_pool/2`, the
  builder's pool wherever it comes among the runners, else the pool seen
  most recently, and nil with no runner that merges.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners, Verified}
  alias Slipdock.Runners.Runner

  @day 86_400

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Pools", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

    [_backlog, todo, doing, _done] = board.columns

    %{board: board, built: card_fixture(doing, %{"title" => "Built"}), todo: todo}
  end

  # A runner in `pool` that takes work and merge jobs.
  defp merger(board, pool) do
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "runner-#{pool}", "pool" => pool})
    Runners.report_kinds(runner, "claude,merge")
  end

  # Last seen `days` days ago: far too long ago to be idle.
  defp away(%Runner{id: id}, days) do
    seen = DateTime.utc_now() |> DateTime.add(-days * @day) |> DateTime.truncate(:second)
    Repo.update_all(from(r in Runner, where: r.id == ^id), set: [last_seen_at: seen])
    runner = Repo.get!(Runner, id)
    refute Runners.idle?(runner)
    runner
  end

  test "no runner that merges: no pool", ctx do
    assert Verified.merge_pool(ctx.built) == nil

    {:ok, _only_works, _} = Runners.create_runner(ctx.board, %{"name" => "w", "pool" => "work"})
    assert Verified.merge_pool(ctx.built) == nil
  end

  test "none idle, nobody decided: the builder's pool, though another was seen since", ctx do
    builder = merger(ctx.board, "builder")
    other = merger(ctx.board, "other")

    {:ok, job} = Runners.queue(ctx.built, %{pool: "builder", kind: "claude", prompt: "go"})
    assert Runners.claim(builder).id == job.id

    away(builder, 2)
    away(other, 1)

    # The other pool heads the runners, as the one seen more recently.
    assert Verified.merge_pool(ctx.built) == "builder"

    # A card nobody built goes to the pool seen most recently.
    unbuilt = card_fixture(ctx.todo, %{"title" => "Nobody built this"})
    assert Verified.merge_pool(unbuilt) == "other"

    # With the builder's runner left out, its pool is no longer a choice.
    assert Verified.merge_pool(ctx.built, exclude: builder.id) == "other"
  end
end
