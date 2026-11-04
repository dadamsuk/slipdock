defmodule Slipdock.Runners.FinishingJobsTest do
  @moduledoc """
  Verify and merge jobs finish a card's work rather than add to it (#1807):
  neither lanes nor the WIP limit hold one, while a work job for the same
  card, held the same way, still waits.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Lanes, Repo, Runners, Verified}
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

  defp card(column, title, paths) do
    card = card_fixture(column, %{"title" => title})
    {:ok, card} = Boards.update_card(card, %{"paths" => paths})
    card
  end

  defp queue(card, kind), do: Runners.queue(card, %{pool: "dev", kind: kind, prompt: "go"})

  defp reasons(jobs), do: jobs |> Enum.map(&Repo.reload!/1) |> Runners.held_reasons()

  test "verify and merge are the finishing kinds" do
    assert Verified.finishing_kinds() == [Verified.verify_kind(), Verified.merge_kind()]
  end

  describe "lanes" do
    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"lanes" => true})
      %{board: board, running: card(ctx.doing, "Running", "lib/**")}
    end

    for kind <- ["verify", "merge"] do
      test "a #{kind} job is claimed while its card overlaps a card in progress", ctx do
        accepted = card(ctx.todo, "Accepted epic", "lib/a.ex")
        {:ok, job} = queue(accepted, unquote(kind))

        assert Lanes.held_cards(ctx.board.id) == %{}
        assert Runners.held_reason(Repo.reload!(job), claimant: true) == nil
        assert reasons([job]) == %{}
        assert %{id: id} = Runners.claim(ctx.runner)
        assert id == job.id
      end
    end

    test "a work job for the same card still waits, and the merge goes first", ctx do
      epic = card(ctx.todo, "Epic", "lib/a.ex")
      {:ok, work} = queue(epic, "claude")
      {:ok, merge} = queue(epic, "merge")
      line = "Lane: overlaps ##{ctx.running.id}, in progress"

      assert %{} = held = Lanes.held_cards(ctx.board.id)
      assert Map.new(held, fn {id, other} -> {id, other.id} end) == %{epic.id => ctx.running.id}

      assert Runners.held_reason(Repo.reload!(work), claimant: true) == line
      assert Runners.held_reason(Repo.reload!(merge), claimant: true) == nil
      assert reasons([work, merge]) == %{work.id => line}

      assert %{id: id} = Runners.claim(ctx.runner)
      assert id == merge.id
      assert Runners.claim(ctx.runner) == nil
      assert %{reason: ^line, job: %{id: held_id}} = Runners.held(ctx.board, "dev")
      assert held_id == work.id
    end

    test "with lanes off nothing is held, whatever the kind", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => false})
      {:ok, work} = queue(card(ctx.todo, "Epic", "lib/a.ex"), "claude")

      assert Lanes.held_cards(ctx.board.id) == %{}
      assert reasons([work]) == %{}
    end
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
