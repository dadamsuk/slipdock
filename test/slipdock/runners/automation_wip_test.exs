defmodule Slipdock.Runners.AutomationWipTest do
  @moduledoc """
  WIP limits holding automated work (#1116, KTD11), on the board owner's
  opt-in: while the first doing list is at its limit, a list_top send and a
  claim for a card not already in progress wait; a card in progress still
  goes, and people's drags are never stopped. Off, nothing changes.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Repo, Runners}
  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Limits"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    doing = doing |> Ecto.Changeset.change(wip_limit: 3) |> Repo.update!()
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    in_progress = for n <- 1..3, do: card_fixture(doing, %{"title" => "Doing #{n}"})

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      runner: runner,
      in_progress: in_progress
    }
  end

  defp wip_on(board, on \\ true),
    do: Repo.update_all(from(b in Board, where: b.id == ^board.id), set: [automation_wip: on])

  defp queue(card), do: Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

  defp list_top(board) do
    rule_fixture(board, %{
      "trigger" => %{"type" => "list_top", "column" => "To Do"},
      "actions" => [%{"type" => "runner", "pool" => "dev"}]
    })
  end

  defp jobs(rule), do: Repo.all(from(j in Job, where: j.rule_id == ^rule.id))

  describe "with automation WIP on and In Progress at 3/3 (AE6)" do
    setup ctx do
      wip_on(ctx.board)
      :ok
    end

    test "a list_top send is held, with the WIP line", ctx do
      card_fixture(ctx.todo, %{"title" => "Next"})
      rule = list_top(ctx.board)

      assert Automations.feed(rule) == {:idle, :wip_full}
      assert jobs(rule) == []
      assert {column, 3} = Runners.wip_full(ctx.board.id)
      assert Runners.wip_line(column, 3) == "WIP full: #{ctx.doing.name} 3/3"
    end

    test "a claim for a card in To Do is held; one for a card in progress isn't", ctx do
      {:ok, waiting} = queue(card_fixture(ctx.todo, %{"title" => "Next"}))

      assert Runners.claim(ctx.runner) == nil
      assert Runners.held_reason(Repo.reload!(waiting)) == "WIP full: #{ctx.doing.name} 3/3"
      assert Runners.held(ctx.board, "dev").reason == "WIP full: #{ctx.doing.name} 3/3"

      {:ok, going} = queue(hd(ctx.in_progress))
      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == going.id
      assert Repo.reload!(waiting).status == "queued"
    end

    test "a person can still drag a fourth card in", ctx do
      card = card_fixture(ctx.todo, %{"title" => "By hand"})
      assert :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      assert Repo.reload!(card).column_id == ctx.doing.id
    end

    test "once a card leaves the list, held work goes again", ctx do
      {:ok, job} = queue(card_fixture(ctx.todo))
      assert Runners.claim(ctx.runner) == nil

      {:ok, _} = Boards.toggle_completed(hd(ctx.in_progress))
      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == job.id
    end
  end

  describe "with automation WIP off" do
    test "nothing changes: the send and the claim go, the limit only shows", ctx do
      card_fixture(ctx.todo, %{"title" => "Next"})
      # Saving a list_top rule feeds it.
      rule = list_top(ctx.board)

      assert [job] = jobs(rule)
      assert Automations.feed(rule) == {:idle, :job_open}
      assert Runners.wip_full(ctx.board.id) == nil
      assert Runners.held_reason(job, claimant: true) == nil
      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == job.id
    end
  end

  describe "what counts toward the limit" do
    setup ctx do
      wip_on(ctx.board)
      :ok
    end

    test "stand-ins don't", ctx do
      stand_in = List.last(ctx.in_progress)
      original = card_fixture(ctx.todo, %{"title" => "The real one"})

      Repo.update_all(from(c in Card, where: c.id == ^stand_in.id),
        set: [stand_in_for_id: original.id]
      )

      assert Runners.wip_full(ctx.board.id) == nil
    end

    test "a card with an open wait does", ctx do
      asking = List.last(ctx.in_progress)
      {:ok, _} = Boards.open_wait(asking, Actor.web(ctx.owner), %{"needs" => "Which region?"})

      assert {_column, 3} = Runners.wip_full(ctx.board.id)
    end

    test "only the first doing list's limit, and only when it has one", ctx do
      Repo.update_all(from(c in Column, where: c.id == ^ctx.doing.id), set: [wip_limit: nil])
      assert Runners.wip_full(ctx.board.id) == nil
    end
  end
end
