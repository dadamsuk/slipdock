defmodule Slipdock.CardLoopTest do
  @moduledoc """
  The runner loop holding a card (#2027, `Slipdock.CardState.loop/1`): shown
  beside its assignees while its job is claimed or running, worked out from
  the job with nothing stored, gone however the job ends, and never an
  assignee, so every assignee filter still means people.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, CardState, Repo, Runners}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Loops"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns

    {:ok, runner, _} =
      Runners.create_runner(board, %{"name" => "Mac Studio", "pool" => "dev"})

    %{owner: owner, board: board, todo: todo, doing: doing, runner: runner}
  end

  defp queue(card, kind \\ "claude"),
    do: Runners.queue(card, %{pool: "dev", kind: kind, prompt: "go"})

  defp claimed(ctx, card, kind \\ "claude") do
    {:ok, _} = queue(card, kind)
    %Job{} = job = Runners.claim(ctx.runner)
    job
  end

  defp running(ctx, card, kind \\ "claude") do
    job = claimed(ctx, card, kind)
    {:ok, :ok} = Runners.heartbeat(ctx.runner, job.id)
    job
  end

  defp listed(ctx, card, filters \\ %{}) do
    ctx.board |> Boards.Cards.list_cards(filters) |> Enum.find(&(&1.id == card.id))
  end

  defp loop_of(ctx, card), do: ctx |> listed(card) |> CardState.loop()

  describe "while a job holds the card" do
    test "a claimed job: the runner, build, and the job", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Build it"})
      job = claimed(ctx, card)

      assert %{runner: "Mac Studio", kind: "build", job_id: job_id} = loop_of(ctx, card)
      assert job_id == job.id

      assert Boards.with_state(Boards.Cards.get_card!(card.id))
             |> CardState.loop()
             |> Map.get(:job_id) ==
               job.id
    end

    test "a running job, and a verify job says verify", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Build it"})
      job = running(ctx, card)
      assert %{kind: "build", job_id: id} = loop_of(ctx, card)
      assert id == job.id

      other = card_fixture(ctx.doing, %{"title" => "Check it"})
      running(ctx, other, "verify")
      assert %{runner: "Mac Studio", kind: "verify"} = loop_of(ctx, other)
      assert CardState.loop_label(loop_of(ctx, other)) == "Mac Studio · verify"
    end

    test "a queued job holds nothing yet", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Waiting"})
      {:ok, _} = queue(card)
      assert loop_of(ctx, card) == nil
      assert ctx |> listed(card) |> Map.get(:state) |> Map.get(:loop) == nil
    end

    test "loop_of/1 reads it from the card's jobs as the panel has them", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Panel"})
      job = running(ctx, card)
      jobs = Runners.list_card_jobs(card.id, 5)

      assert %{runner: "Mac Studio", kind: "build", job_id: id} = CardState.loop_of(jobs)
      assert id == job.id
      assert CardState.loop_of([]) == nil
    end

    test "nothing is stored: the card's assignees stay empty", ctx do
      card = card_fixture(ctx.doing, %{"title" => "No row"})
      running(ctx, card)

      assert Card.assignees(Boards.Cards.get_card!(card.id)) == []

      assert Repo.aggregate(from(a in "card_assignees", where: a.card_id == ^card.id), :count) ==
               0
    end
  end

  describe "the loop goes when the job ends" do
    test "done", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Done"})
      job = running(ctx, card)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: 0})
      assert loop_of(ctx, card) == nil
    end

    test "failed and timed out", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Failed"})
      job = running(ctx, card)
      {:ok, %Job{status: "failed"}} = Runners.finish(ctx.runner, job.id, %{exit: 1})
      assert loop_of(ctx, card) == nil

      other = card_fixture(ctx.doing, %{"title" => "Timed out"})
      job = running(ctx, other)
      {:ok, %Job{status: "timeout"}} = Runners.finish(ctx.runner, job.id, %{status: "timeout"})
      assert loop_of(ctx, other) == nil
    end

    test "cancelled", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Cancelled"})
      job = running(ctx, card)
      {:ok, _} = Runners.cancel_job(Repo.get!(Job, job.id))
      # Asked to stop, it holds the card until its runner stops it.
      assert %{job_id: _} = loop_of(ctx, card)
      {:ok, %Job{status: "cancelled"}} = Runners.finish(ctx.runner, job.id, %{exit: 0})
      assert loop_of(ctx, card) == nil
    end

    test "parked on a question", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Parked"})
      job = running(ctx, card)

      {:ok, %Job{status: "parked"}, _wait} =
        Runners.finish_waiting(ctx.runner, job.id, fn job ->
          agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.owner.id}

          Boards.Waits.open_wait(card, agent, %{
            "question" => "other",
            "needs" => "Which one?",
            "job_id" => job.id
          })
        end)

      assert loop_of(ctx, card) == nil
    end

    test "requeued when its lease runs out", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Requeued"})
      job = running(ctx, card)
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [lease_expires_at: past])

      assert Runners.sweep() >= 1
      assert %Job{status: "queued"} = Repo.get!(Job, job.id)
      assert loop_of(ctx, card) == nil
    end
  end

  describe "people stay the assignees" do
    test "a person assignee and a loop: both", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Both"})
      {:ok, _} = Boards.Cards.update_card(card, %{"assignee_ids" => [ctx.owner.id]})
      running(ctx, card)

      listed = listed(ctx, card)
      assert [%{id: id}] = Card.assignees(listed)
      assert id == ctx.owner.id
      assert %{runner: "Mac Studio"} = CardState.loop(listed)
    end

    test "assignee filters ignore the loop", ctx do
      held = card_fixture(ctx.doing, %{"title" => "Held, nobody's"})
      running(ctx, held)
      mine = card_fixture(ctx.doing, %{"title" => "Mine"})
      {:ok, _} = Boards.Cards.update_card(mine, %{"assignee_ids" => [ctx.owner.id]})

      nobodys = Enum.map(Boards.Cards.list_cards(ctx.board, %{"assignee" => "none"}), & &1.id)
      assert held.id in nobodys
      refute mine.id in nobodys

      owners =
        Enum.map(Boards.Cards.list_cards(ctx.board, %{"assignee" => ctx.owner.email}), & &1.id)

      assert owners == [mine.id]
    end
  end
end
