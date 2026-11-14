defmodule Slipdock.Runners.FinishingJobsTest do
  @moduledoc """
  Verify and merge jobs finish a card's work rather than add to it (#1807):
  the WIP limit doesn't hold one, while a work job for the same
  card, held the same way, still waits.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners, Verified}
  alias Slipdock.Boards.Board
  alias Slipdock.Runners.Runner

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Finishing"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    runner = Runners.report_kinds(runner, "claude,verify,merge")

    # Seen just now, so the board page's reasons don't say it's offline.
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id),
      set: [last_seen_at: DateTime.utc_now()]
    )

    %{board: board, todo: todo, doing: doing, runner: runner}
  end

  defp queue(card, kind), do: Runners.queue(card, %{pool: "dev", kind: kind, prompt: "go"})

  defp reasons(jobs), do: jobs |> Enum.map(&Repo.reload!/1) |> Runners.held_reasons()

  test "verify and merge are the finishing kinds" do
    assert Verified.finishing_kinds() == [Verified.verify_kind(), Verified.merge_kind()]
  end

  describe "the WIP limit" do
    setup ctx do
      doing = ctx.doing |> Ecto.Changeset.change(wip_limit: 1) |> Repo.update!()
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [automation_wip: true])
      card_fixture(doing, %{"title" => "In progress"})
      %{doing: doing}
    end

    test "verify and merge jobs for a card in To Do are claimed; a work job waits", ctx do
      epic = card_fixture(ctx.todo, %{"title" => "Accepted epic"})
      {:ok, work} = queue(epic, "claude")
      {:ok, verify} = queue(epic, "verify")
      {:ok, merge} = queue(epic, "merge")
      line = "WIP full: #{ctx.doing.name} 1/1"

      assert Runners.held_reason(Repo.reload!(work), claimant: true) == line
      assert Runners.held_reason(Repo.reload!(verify), claimant: true) == nil
      assert Runners.held_reason(Repo.reload!(merge), claimant: true) == nil
      assert reasons([work, verify, merge]) == %{work.id => line}

      assert %{id: first} = Runners.claim(ctx.runner)
      assert %{id: second} = Runners.claim(ctx.runner)
      assert Runners.claim(ctx.runner) == nil
      assert [first, second] == [verify.id, merge.id]
      assert %{reason: ^line, job: %{id: held_id}} = Runners.held(ctx.board, "dev")
      assert held_id == work.id
    end

    test "a merge job still goes only to a runner that takes merges", ctx do
      {:ok, plain, _} = Runners.create_runner(ctx.board, %{"name" => "plain", "pool" => "dev"})
      plain = Runners.report_kinds(plain, "claude")
      {:ok, merge} = queue(card_fixture(ctx.todo, %{"title" => "Accepted"}), "merge")

      assert Runners.claim(plain) == nil
      assert %{id: id} = Runners.claim(ctx.runner)
      assert id == merge.id
    end
  end
end
