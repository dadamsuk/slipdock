defmodule Slipdock.Runners.RecoveryTest do
  # A `list_top` rule with `requeue_stuck`: a job that ends with its card
  # still in progress has the card put back on the rule's list, N times, and
  # then flagged blocked (`Slipdock.Runners.Recovery`).
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Repo, Runners}
  alias Slipdock.Automations.{Presets, Spec}
  alias Slipdock.Runners.{Job, Recovery, Setup}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Recover"}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    a = card_fixture(todo, %{"title" => "a"})
    b = card_fixture(todo, %{"title" => "b"})

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      done: done,
      runner: runner,
      a: a,
      b: b
    }
  end

  defp spec(action \\ %{}, trigger \\ %{}) do
    %{
      "trigger" => Map.merge(%{"type" => "list_top", "column" => "To Do"}, trigger),
      "actions" => [
        Map.merge(%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 1}, action)
      ]
    }
  end

  defp jobs(rule),
    do: Repo.all(from(j in Job, where: j.rule_id == ^rule.id, order_by: [asc: j.id]))

  defp open_cards(rule), do: rule |> jobs() |> Enum.filter(&Job.open?/1) |> Enum.map(& &1.card_id)

  # The runner takes the job and, as an agent would, moves its card along.
  defp take(ctx) do
    job = Runners.claim(ctx.runner)
    :ok = Boards.move_card_to_index(Repo.get!(Boards.Card, job.card_id), ctx.doing, :top)
    job
  end

  defp finish(ctx, job, status \\ "failed") do
    {:ok, job} = Runners.finish(ctx.runner, job.id, %{status: status})
    Repo.reload!(job)
  end

  defp card(card), do: Boards.get_card!(card.id)

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  describe "a job that ends with its card in progress" do
    for status <- ~w(done failed cancelled timeout) do
      test "ending #{status}, puts it back on top of the list and sends it next", ctx do
        rule = rule_fixture(ctx.board, spec())
        job = take(ctx)
        assert job.card_id == ctx.a.id

        job = finish(ctx, job, unquote(status))

        assert job.recovery == "requeued"
        a = card(ctx.a)
        assert a.column_id == ctx.todo.id
        assert Enum.at(Boards.get_board!(ctx.board.id).columns, 1).id == ctx.todo.id

        assert [first | _] =
                 Repo.all(
                   from(c in Boards.Card,
                     where: c.column_id == ^ctx.todo.id,
                     order_by: [asc: c.position],
                     select: c.id
                   )
                 )

        assert first == ctx.a.id
        assert [comment] = comments(ctx.a)
        assert comment =~ "Runner job ##{job.id} ended"
        assert comment =~ "retry 1 of 1"
        refute "blocked" in a.flags

        # Not cooling: the retry goes before the next card.
        assert open_cards(rule) == [ctx.a.id]
      end
    end

    test "says why, with the exit code", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: "3"})

      assert [comment] = comments(ctx.a)
      assert comment =~ "(failed, exit 3)"
    end

    test "after N retries flags it blocked and leaves it in progress", ctx do
      rule = rule_fixture(ctx.board, spec(%{"requeue_stuck" => 2}))

      for n <- 1..2 do
        job = take(ctx)
        assert job.card_id == ctx.a.id
        assert finish(ctx, job).recovery == "requeued"
        assert List.last(comments(ctx.a)) =~ "retry #{n} of 2"
      end

      job = take(ctx)
      job = finish(ctx, job, "timeout")

      assert job.recovery == "gave_up"
      a = card(ctx.a)
      assert a.column_id == ctx.doing.id
      assert "blocked" in a.flags
      assert List.last(comments(ctx.a)) =~ "after 2 retries. Flagged blocked"

      # Blocked and in progress: nothing more goes out for it.
      refute ctx.a.id in open_cards(rule)
    end

    test "the count starts again once the card has been completed", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      assert finish(ctx, job).recovery == "requeued"

      # Finished since, then reopened.
      {:ok, _} = Boards.update_card(card(ctx.a), %{"completed" => true})
      {:ok, _} = Boards.update_card(card(ctx.a), %{"completed" => false})
      assert Repo.reload!(job).recovery == "requeued_before_done"

      job = take(ctx)
      assert job.card_id == ctx.a.id
      assert finish(ctx, job).recovery == "requeued"
      refute "blocked" in card(ctx.a).flags
    end

    test "unassigns it when the rule only sends cards nobody has taken", ctx do
      rule_fixture(ctx.board, spec(%{}, %{"unassigned" => true}))
      job = take(ctx)
      {:ok, _} = Boards.update_card(card(ctx.a), %{"assignee_ids" => [ctx.owner.id]})

      finish(ctx, job)

      a = card(ctx.a) |> Repo.preload(:assignees)
      assert a.assignee_id == nil
      assert a.assignees == []
      assert hd(comments(ctx.a)) =~ "unassigned,"
    end

    test "a job whose lease lapsed and was handed out again counts when it ends", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      later = DateTime.add(DateTime.utc_now(), Runners.lease_seconds() + 5, :second)
      assert Runners.sweep(later) == 1
      assert Repo.reload!(job).status == "queued"

      again = Runners.claim(ctx.runner)
      assert again.id == job.id
      assert finish(ctx, again).recovery == "requeued"
      assert card(ctx.a).column_id == ctx.todo.id
    end

    test "a job the sweep gives up on is dealt with the same way", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)

      Repo.update_all(from(j in Job, where: j.id == ^job.id),
        set: [attempts: Runners.max_attempts()]
      )

      later = DateTime.add(DateTime.utc_now(), Runners.lease_seconds() + 5, :second)

      Runners.sweep(later)

      job = Repo.reload!(job)
      assert job.status == "failed"
      assert job.recovery == "requeued"
      assert card(ctx.a).column_id == ctx.todo.id
    end
  end

  describe "leaves alone" do
    test "a card somebody else is working by hand", ctx do
      rule_fixture(ctx.board, spec())
      by_hand = card_fixture(ctx.doing, %{"title" => "by hand"})
      job = Runners.claim(ctx.runner)

      job = finish(ctx, job)

      assert job.recovery == nil
      assert card(by_hand).column_id == ctx.doing.id
      assert comments(by_hand) == []
    end

    test "a card the job closed or left on its list", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      {:ok, _} = Boards.update_card(card(ctx.a), %{"completed" => true})
      assert finish(ctx, job, "done").recovery == nil

      job = Runners.claim(ctx.runner)
      assert finish(ctx, job).recovery == nil
      assert comments(ctx.b) == []
    end

    test "a job cancelled before anybody took it", ctx do
      rule_fixture(ctx.board, spec())
      [job] = Repo.all(from(j in Job, where: j.card_id == ^ctx.a.id))
      :ok = Boards.move_card_to_index(card(ctx.a), ctx.doing, :top)

      {:ok, job} = Runners.cancel_job(job)

      assert Repo.reload!(job).recovery == nil
      assert card(ctx.a).column_id == ctx.doing.id
    end

    test "a rule without the option, or with 0", ctx do
      for action <- [%{"requeue_stuck" => 0}, %{"requeue_stuck" => nil}] do
        rule = rule_fixture(ctx.board, spec(action))
        job = take(ctx)
        assert finish(ctx, job).recovery == nil
        assert card(Repo.get!(Boards.Card, job.card_id)).column_id == ctx.doing.id
        Automations.delete_rule(rule)
      end
    end

    test "nothing twice for one job", ctx do
      rule_fixture(ctx.board, spec(%{"requeue_stuck" => 3}))
      job = take(ctx)
      finish(ctx, job)
      :ok = Boards.move_card_to_index(card(ctx.a), ctx.doing, :top)

      assert Recovery.recover(job) == :ok
      assert length(comments(ctx.a)) == 1
    end
  end

  describe "the rule" do
    test "takes requeue_stuck as a whole number, from a form's string too" do
      assert {:ok, %{"actions" => [%{"requeue_stuck" => 2}]}} =
               Spec.validate(spec(%{"requeue_stuck" => "2"}))

      assert {:error, "action “runner” requeue_stuck must be a whole number from 0 to 10"} =
               Spec.validate(spec(%{"requeue_stuck" => 11}))

      assert {:error, "action “runner” requeue_stuck must be a whole number from 0 to 10"} =
               Spec.validate(spec(%{"requeue_stuck" => "lots"}))

      assert Spec.summary(spec(%{"requeue_stuck" => 2})) =~
               "putting back a card its job leaves in progress up to 2 times"

      runner = Enum.find(Spec.vocabulary().actions, &(&1.type == "runner"))
      assert "requeue_stuck" in runner.optional
    end

    test "is only for a list_top rule" do
      arrival = %{spec() | "trigger" => %{"type" => "card_entered", "column" => "To Do"}}
      assert {:error, "requeue_stuck is only for a list_top rule"} = Spec.validate(arrival)

      assert {:ok, _} =
               Spec.validate(%{
                 arrival
                 | "actions" => [%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 0}]
               })
    end

    test "is refused on a board with no in-progress list", ctx do
      {:ok, plain} =
        Boards.create_board(%{"name" => "No doing", "code" => "rq#{rem(ctx.owner.id, 100_000)}"},
          columns: [
            %{"name" => "To Do", "category" => "todo"},
            %{"name" => "Done", "category" => "done"}
          ],
          owner_id: ctx.owner.id
        )

      assert {:error, changeset} =
               Automations.create_rule(%{"name" => "R", "spec" => spec(), "board_id" => plain.id})

      assert {"requeue_stuck needs an in-progress list" <> _, _} = changeset.errors[:spec]
    end

    test "the top-card preset puts a card back once by default", ctx do
      {:ok, feed} =
        Automations.create_rule_from_preset(ctx.board, "feed_runner", %{
          "column" => "Backlog",
          "pool" => "loop"
        })

      assert [%{"requeue_stuck" => 1}] = feed.spec["actions"]
      assert Recovery.requeue_limit(feed) == 1

      assert {:ok, %{"spec" => %{"actions" => [%{"requeue_stuck" => 0}]}}} =
               Presets.build("feed_runner", %{
                 "column" => "To Do",
                 "pool" => "x",
                 "requeue" => "0"
               })
    end

    test "the wizard passes the number on", ctx do
      params = %{
        "scenario" => "loop",
        "pool" => "loop",
        "column" => "To Do",
        "feed" => "top",
        "requeue" => "3"
      }

      {:ok, %{rule: rule}} = Setup.connect(ctx.board, params, ctx.owner, "https://slipdock.test")
      assert [%{"requeue_stuck" => 3}] = rule.spec["actions"]
      assert Recovery.requeue_limit(rule) == 3
    end
  end
end
