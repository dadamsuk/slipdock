defmodule Slipdock.DeploymentsTest do
  @moduledoc """
  The deployments ledger (#1134): the board switch it hangs off, the
  changeset, a deploy's one-way status (started → succeeded/failed, once),
  and the last succeeded sha per board and environment.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments}
  alias Slipdock.Deployments.Deployment

  @sha "1a2b3c4d5e6f7081"
  @sha2 "2b3c4d5e6f708192"

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Ship"}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    %{user: user, board: board}
  end

  defp start!(board, attrs) do
    {:ok, d} = Deployments.start(board, Map.merge(%{environment: "production", sha: @sha}, attrs))
    d
  end

  test "the switch is off on a new board, and while off nothing is recorded", %{user: user} do
    board = board_fixture(%{"name" => "Quiet"}, owner: user)
    refute board.delivery_metrics
    refute Deployments.enabled?(board)

    assert Deployments.start(board, %{environment: "production", sha: @sha}) == {:error, :off}
    assert Deployments.finish(board, 1, "succeeded") == {:error, :off}
    assert Repo.aggregate(Deployment, :count) == 0
    assert Deployments.off_message(board) =~ "set-board #{board.code} --delivery-metrics"
  end

  test "a deploy starts, then finishes once", %{board: board} do
    d = start!(board, %{})
    assert d.status == "started"
    assert d.finished_at == nil
    assert d.source == "api"

    assert {:ok, done} = Deployments.finish(board, d.id, "succeeded")
    assert done.status == "succeeded"
    assert done.finished_at

    assert {:error, cs} = Deployments.finish(board, d.id, "failed")
    assert "is already succeeded: a deploy finishes once" in errors_on(cs).status
    assert Repo.get!(Deployment, d.id).status == "succeeded"
  end

  test "finishing with something other than succeeded/failed is refused", %{board: board} do
    d = start!(board, %{})
    assert {:error, cs} = Deployments.finish(board, d.id, "started")
    assert "must be succeeded or failed" in errors_on(cs).status
    assert {:error, _} = Deployments.finish(board, d.id, "bogus")
    assert Repo.get!(Deployment, d.id).status == "started"
  end

  test "finishing a deploy that was never started, or is another board's", %{
    board: board,
    user: user
  } do
    assert Deployments.finish(board, 999_999, "succeeded") == {:error, :not_found}
    assert Deployments.finish(board, "nope", "succeeded") == {:error, :not_found}

    {:ok, other} =
      board_fixture(%{"name" => "Other"}, owner: user)
      |> Boards.update_board(%{"delivery_metrics" => true})

    theirs = start!(other, %{})
    assert Deployments.finish(board, theirs.id, "succeeded") == {:error, :not_found}
    assert Repo.get!(Deployment, theirs.id).status == "started"
  end

  test "the changeset checks environment, sha, status and source", %{board: board} do
    assert {:error, cs} = Deployments.start(board, %{environment: "", sha: "xyz"})
    errors = errors_on(cs)
    assert "can't be blank" in errors.environment
    assert "must be a hex commit sha" in errors.sha

    assert {:error, cs} =
             Deployments.start(board, %{
               environment: "prod uction",
               sha: @sha,
               status: "maybe",
               source: "fax"
             })

    errors = errors_on(cs)
    assert errors.environment != []
    assert errors.status != []
    assert errors.source != []
  end

  test "a sha is kept lower-case", %{board: board} do
    assert start!(board, %{sha: String.upcase(@sha)}).sha == @sha
  end

  test "a deploy recorded already finished (a backfill) keeps or takes its finish time", %{
    board: board
  } do
    at = ~U[2026-01-02 03:04:05.000000Z]
    d = start!(board, %{status: "succeeded", started_at: at, source: "backfill"})
    assert d.finished_at == at
    assert d.source == "backfill"
  end

  test "the last succeeded sha is per environment and ignores failed and started", %{
    board: board
  } do
    assert Deployments.last_sha(board, "production") == nil

    first = start!(board, %{})
    {:ok, _} = Deployments.finish(board, first.id, "succeeded")
    assert Deployments.last_sha(board, "production") == @sha
    assert Deployments.last_sha(board, "staging") == nil

    failed = start!(board, %{sha: @sha2})
    assert failed.previous_sha == @sha
    {:ok, _} = Deployments.finish(board, failed.id, "failed")
    _running = start!(board, %{sha: "3c4d5e6f70819203"})
    assert Deployments.last_sha(board, "production") == @sha

    staged = start!(board, %{environment: "staging", sha: @sha2})
    assert staged.previous_sha == nil
    {:ok, _} = Deployments.finish(board, staged.id, "succeeded")
    assert Deployments.last_sha(board, "staging") == @sha2
    assert Deployments.last_sha(board, "production") == @sha
    assert Deployments.environments(board) == ["production", "staging"]
  end

  test "list/2 filters by window, environment and status", %{board: board} do
    old = start!(board, %{started_at: ~U[2026-01-01 00:00:00.000000Z]})
    new = start!(board, %{environment: "staging", sha: @sha2})

    assert Enum.map(Deployments.list(board), & &1.id) == [old.id, new.id]

    assert Enum.map(Deployments.list(board, since: ~U[2026-06-01 00:00:00Z]), & &1.id) == [
             new.id
           ]

    assert Enum.map(Deployments.list(board, until: ~U[2026-06-01 00:00:00Z]), & &1.id) == [
             old.id
           ]

    assert Enum.map(Deployments.list(board, environment: "staging"), & &1.id) == [new.id]
    assert Deployments.list(board, status: "succeeded") == []
  end

  test "a deploy is announced on the board's topic", %{board: board} do
    Phoenix.PubSub.subscribe(Slipdock.PubSub, Deployments.topic(board))
    d = start!(board, %{})
    assert_receive {:deployment, %Deployment{id: id, status: "started"}} when id == d.id
    {:ok, _} = Deployments.finish(board, d.id, "failed")
    assert_receive {:deployment, %Deployment{status: "failed"}}
  end

  test "the switch goes out in an export", %{user: user, board: board} do
    json = user |> Slipdock.Portable.Export.export() |> Jason.encode!()
    assert json =~ ~s("code":"#{board.code}")
    assert json =~ ~s("delivery_metrics":true)
  end
end
