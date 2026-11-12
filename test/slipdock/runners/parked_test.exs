defmodule Slipdock.Runners.ParkedTest do
  @moduledoc """
  Parked jobs (#1115, KTD5–KTD6): a job whose agent opened a wait ends
  `parked`, whatever it exits with; a list_top rule's parked card goes back
  on top of its list, flagged waiting, without spending a retry, so the next
  card goes; and a lapsed lease never puts a parked job back in the queue.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Parked"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    a = card_fixture(todo, %{"title" => "a"})
    b = card_fixture(todo, %{"title" => "b"})
    %{owner: owner, board: board, todo: todo, doing: doing, runner: runner, a: a, b: b}
  end

  defp spec(action \\ %{}) do
    %{
      "trigger" => %{"type" => "list_top", "column" => "To Do"},
      "actions" => [Map.merge(%{"type" => "runner", "pool" => "loop"}, action)]
    }
  end

  defp jobs(rule),
    do: Repo.all(from(j in Job, where: j.rule_id == ^rule.id, order_by: [asc: j.id]))

  defp open_cards(rule), do: rule |> jobs() |> Enum.filter(&Job.open?/1) |> Enum.map(& &1.card_id)

  # The runner takes the job and, as an agent would, moves its card along.
  defp take(ctx) do
    job = Runners.claim(ctx.runner)
    :ok = Boards.Cards.move_card_to_index(Repo.get!(Boards.Card, job.card_id), ctx.doing, :top)
    job
  end

  # What `slipdock wait <card> "…" --job <id>` does from inside the job.
  defp ask(ctx, job, needs \\ "Which region?") do
    {:ok, wait} =
      Boards.Waits.open_wait(
        Repo.get!(Boards.Card, job.card_id),
        Actor.runner(ctx.owner, job.id),
        %{
          "needs" => needs,
          "choices" => ["eu", "us"],
          "job_id" => job.id
        }
      )

    wait
  end

  defp card(card), do: Boards.Cards.get_card!(card.id)

  defp top_of(column) do
    Repo.one(
      from(c in Boards.Card,
        where: c.column_id == ^column.id and is_nil(c.archived_at),
        order_by: [asc: c.position, asc: c.id],
        limit: 1,
        select: c.id
      )
    )
  end

  describe "a shell runner's job whose agent opened a wait (AE1)" do
    test "exits 0 and ends parked; the card goes back on top, waiting, and the next one goes",
         ctx do
      rule = rule_fixture(ctx.board, spec(%{"wait_while_doing" => true}))
      job = take(ctx)
      assert job.card_id == ctx.a.id
      ask(ctx, job)

      {:ok, job} = Runners.finish(ctx.runner, job.id, %{exit: "0", output: "Asked about it"})

      assert job.status == "parked"
      assert Repo.reload!(job).recovery == "parked"
      a = card(ctx.a)
      assert a.column_id == ctx.todo.id
      assert top_of(ctx.todo) == ctx.a.id
      assert "waiting" in a.flags
      assert Enum.any?(a.comments, &(&1.body =~ "parked on a question: “Which region?”"))

      # The next card is sent, and taken.
      assert open_cards(rule) == [ctx.b.id]
      assert Runners.claim(ctx.runner).card_id == ctx.b.id
    end

    test "a card that has lost its waiting flag gets it back, once", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      ask(ctx, job)

      # The wait is still open, but the flag it set has been taken off.
      {:ok, _} = Boards.Cards.update_card(card(ctx.a), %{"flags" => []}, wait_hook: false)
      assert card(ctx.a).flags == []
      assert Boards.Waits.current_wait(ctx.a)

      assert {:ok, %Job{status: "parked"}} = Runners.finish(ctx.runner, job.id, %{exit: "0"})
      assert card(ctx.a).flags == ["waiting"]
    end

    test "a card already flagged waiting isn't flagged twice", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      ask(ctx, job)
      assert card(ctx.a).flags == ["waiting"]

      assert {:ok, %Job{status: "parked"}} = Runners.finish(ctx.runner, job.id, %{exit: "0"})
      assert card(ctx.a).flags == ["waiting"]
    end

    test "parks whatever the exit code", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      ask(ctx, job)

      assert {:ok, %Job{status: "parked"}} = Runners.finish(ctx.runner, job.id, %{exit: "3"})
    end

    test "a cancel still wins over the wait", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      ask(ctx, job)
      {:ok, _} = Runners.cancel_job(Repo.reload!(job))

      assert {:ok, %Job{status: "cancelled"}} = Runners.finish(ctx.runner, job.id, %{exit: "0"})
    end
  end

  describe "finish(status: \"parked\")" do
    test "is refused when the job has no open wait, and the job keeps running", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)

      assert {:error, message} = Runners.finish(ctx.runner, job.id, %{status: "parked"})
      assert message =~ "no open wait to park on"
      assert Repo.reload!(job).status == "claimed"
    end

    test "is refused once the wait has been withdrawn", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      ask(ctx, job)
      {:ok, _} = Boards.Waits.withdraw_wait(card(ctx.a), Actor.web(ctx.owner))

      assert {:error, _} = Runners.finish(ctx.runner, job.id, %{status: "parked"})
      assert {:ok, %Job{status: "done"}} = Runners.finish(ctx.runner, job.id, %{exit: "0"})
    end
  end

  describe "finish_waiting/4" do
    test "opens the wait and parks the job together", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)

      assert {:ok, %Job{status: "parked"}, wait} =
               Runners.finish_waiting(ctx.runner, job.id, fn job ->
                 Boards.Waits.open_wait(card(ctx.a), Actor.runner(ctx.owner, job.id), %{
                   "needs" => "Which region?",
                   "job_id" => job.id
                 })
               end)

      assert wait.job_id == job.id
      assert Boards.Waits.current_wait(ctx.a).id == wait.id
      assert "waiting" in card(ctx.a).flags
    end

    test "a refused wait leaves the job running", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)

      assert {:error, "nope"} =
               Runners.finish_waiting(ctx.runner, job.id, fn _ -> {:error, "nope"} end)

      assert Repo.reload!(job).status == "claimed"
    end

    test "after the lease has lapsed and another runner took the job, opens no wait", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      Runners.sweep(DateTime.add(DateTime.utc_now(), 3600))
      assert Repo.reload!(job).status == "queued"
      {:ok, other, _} = Runners.create_runner(ctx.board, %{"name" => "other", "pool" => "loop"})
      assert %Job{} = Runners.claim(other)

      assert {:error, :not_found} =
               Runners.finish_waiting(ctx.runner, job.id, fn _ -> flunk("opened a wait") end)


      assert Boards.current_wait(ctx.a) == nil
      assert Repo.reload!(job).runner_id == other.id
    end

    # The runner that held it may still take it back (#2817).
    test "after the lease has lapsed with nobody else on the job, takes it back and parks it",
         ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      Runners.sweep(DateTime.add(DateTime.utc_now(), 3600))
      assert Repo.reload!(job).status == "queued"

      assert {:ok, %Job{status: "parked"}, wait} =
               Runners.finish_waiting(ctx.runner, job.id, fn job ->
                 Boards.open_wait(card(ctx.a), Actor.runner(ctx.owner, job.id), %{
                   "needs" => "Which region?",
                   "job_id" => job.id
                 })
               end)

      assert wait.job_id == job.id
      job = Repo.reload!(job)
      assert {job.status, job.runner_id, job.attempts} == {"parked", ctx.runner.id, 1}
    end

    test "a refused wait after a lapsed lease leaves the job in the queue", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      Runners.sweep(DateTime.add(DateTime.utc_now(), 3600))

      assert {:error, "nope"} =
               Runners.finish_waiting(ctx.runner, job.id, fn _ -> {:error, "nope"} end)

      job = Repo.reload!(job)
      assert {job.status, job.runner_id, job.last_runner_id} == {"queued", nil, ctx.runner.id}

    end
  end

  describe "recovery of a parked card (KTD6)" do
    test "three parks in a row spend no retry and never flag the card blocked", ctx do
      Boards.Cards.archive_card(ctx.b)
      rule = rule_fixture(ctx.board, spec(%{"requeue_stuck" => 1}))

      for _ <- 1..3 do
        job = take(ctx)
        assert job.card_id == ctx.a.id
        ask(ctx, job)
        {:ok, %Job{status: "parked"}} = Runners.finish(ctx.runner, job.id, %{exit: "0"})
        {:ok, _} = Boards.Waits.answer_wait(card(ctx.a), Actor.web(ctx.owner), %{"choice" => 1})
      end

      assert rule |> jobs() |> Enum.take(3) |> Enum.map(& &1.recovery) == ~w(parked parked parked)
      refute "blocked" in card(ctx.a).flags
      assert open_cards(rule) == [ctx.a.id]
    end

    test "with requeue_stuck 0 and wait_while_doing, still puts the card back so the next goes",
         ctx do
      rule = rule_fixture(ctx.board, spec(%{"requeue_stuck" => 0, "wait_while_doing" => true}))
      job = take(ctx)
      ask(ctx, job)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: "0"})

      assert card(ctx.a).column_id == ctx.todo.id
      assert open_cards(rule) == [ctx.b.id]
      assert Runners.claim(ctx.runner).card_id == ctx.b.id
    end

    test "an event-triggered rule's parked card stays where it is", ctx do
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "flag_added", "flag" => "starred"},
        "actions" => [%{"type" => "runner", "pool" => "loop"}]
      })

      {:ok, _} = Boards.Cards.update_card(ctx.a, %{"flags" => ["starred"]})
      job = take(ctx)
      ask(ctx, job)
      {:ok, job} = Runners.finish(ctx.runner, job.id, %{exit: "0"})

      assert job.status == "parked"
      assert Repo.reload!(job).recovery == nil
      assert card(ctx.a).column_id == ctx.doing.id
    end
  end

  describe "a lapsed lease (KTD5)" do
    test "parks a job whose wait is still open, rather than queueing it again", ctx do
      rule = rule_fixture(ctx.board, spec())
      job = take(ctx)
      ask(ctx, job)

      Runners.sweep(DateTime.add(DateTime.utc_now(), 3600))

      job = Repo.reload!(job)
      assert job.status == "parked"
      assert job.recovery == "parked"
      assert card(ctx.a).column_id == ctx.todo.id
      assert open_cards(rule) == [ctx.b.id]
    end
  end

  describe "job_finished rules" do
    test "a rule on outcome parked fires for a parked job", ctx do
      rule_fixture(ctx.board, spec())

      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "job_finished", "outcome" => ["parked"]},
        "actions" => [%{"type" => "comment", "body" => "Parked: job {{job.id}} {{job.status}}"}]
      })

      job = take(ctx)
      ask(ctx, job)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: "0"})

      assert Enum.any?(card(ctx.a).comments, &(&1.body == "Parked: job #{job.id} parked"))
    end

    test "parked is an outcome a rule may name", _ctx do
      assert "parked" in Slipdock.Automations.Spec.job_outcomes()
    end
  end
end
