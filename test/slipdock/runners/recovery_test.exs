defmodule Slipdock.Runners.RecoveryTest do
  # A `list_top` rule with `requeue_stuck`: a job that ends with its card
  # still in progress has the card put back on the rule's list, N times, and
  # then flagged blocked (`Slipdock.Runners.Recovery`).
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Repo, Runners, Verified}
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

  # The claim moved the card to the doing list (#2633): the job leaves it
  # back on its list.
  defp left_on_list(ctx, job) do
    :ok = Boards.move_card_to_index(Repo.get!(Boards.Card, job.card_id), ctx.todo, :top)
    job
  end

  defp finish(ctx, job, status \\ "failed") do
    {:ok, job} = Runners.finish(ctx.runner, job.id, %{status: status})
    Repo.reload!(job)
  end

  defp card(card), do: Boards.get_card!(card.id)

  defp comments(card),
    do:
      Repo.all(
        from(c in Boards.Comment,
          where: c.card_id == ^card.id,
          order_by: [asc: c.id],
          select: c.body
        )
      )

  describe "a job that ends with its card in progress" do
    for status <- ~w(done failed cancelled timeout) do
      test "ending #{status}, puts it back on top of the list and sends it next", ctx do
        rule = rule_fixture(ctx.board, spec())
        job = take(ctx)
        assert job.card_id == ctx.a.id

        job = finish(ctx, job, unquote(status))

        assert job.recovery == "requeued"
        # Leaving its card in progress is a failure: its log keeps that time (#1872).
        assert job.transcript_failed_at
        assert Slipdock.Runners.TranscriptRetention.failure?(job)
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
      assert job.transcript_failed_at
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
      job = left_on_list(ctx, Runners.claim(ctx.runner))

      job = finish(ctx, job)

      assert job.recovery == nil
      assert card(by_hand).column_id == ctx.doing.id
      assert comments(by_hand) == []
    end

    test "a card the job closed or left on its list", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      {:ok, _} = Boards.update_card(card(ctx.a), %{"completed" => true})
      done = finish(ctx, job, "done")
      assert done.recovery == nil
      refute done.transcript_failed_at

      job = left_on_list(ctx, Runners.claim(ctx.runner))
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

      # Both ends of the range are in it (#2721).
      max = Recovery.max_requeues()
      assert max == 10

      assert {:ok, %{"actions" => [%{"requeue_stuck" => ^max}]}} =
               Spec.validate(spec(%{"requeue_stuck" => max}))

      assert {:ok, %{"actions" => [%{"requeue_stuck" => 0}]}} =
               Spec.validate(spec(%{"requeue_stuck" => 0}))

      assert {:error, "action “runner” requeue_stuck must be a whole number from 0 to 10"} =
               Spec.validate(spec(%{"requeue_stuck" => -1}))

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

  # #1850: on a board that ships by pull request an accepted card stays in
  # progress, merging, until its merge job finishes. A job ending then had
  # its card put back, and a put-back landing after the merge undid Done.
  describe "a card accepted on a board that ships by pull request" do
    setup ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

      agent = fn name ->
        %{Actor.unknown() | kind: "agent", via: "api", user_id: ctx.owner.id, agent: name}
      end

      %{board: board, builder: agent.("builder"), checker: agent.("checker")}
    end

    # The job's agent submits the card with its pull request, and a second
    # agent accepts it: it is merging, still in progress.
    defp accept(ctx, job) do
      {:ok, card} =
        Boards.update_card(
          Repo.get!(Boards.Card, job.card_id),
          %{
            "completed" => true,
            "evidence_pr" => "https://github.com/acme/app/pull/7",
            "evidence_commit" => "abc1234"
          },
          actor: %{ctx.builder | job_id: job.id}
        )

      assert card.verify_state == "pending"
      {:ok, card} = Verified.decide(card, "accept", %{}, ctx.checker, ctx.owner)
      assert card.verify_state == "merging"
      assert card.column_id == ctx.doing.id
      card
    end

    defp merged(ctx, card) do
      {:ok, card} =
        Verified.decide(
          Repo.get!(Boards.Card, card.id),
          "merged",
          %{},
          Actor.web(ctx.owner),
          ctx.owner
        )

      card
    end

    test "a job ending while its card merges leaves it to the merge", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      accept(ctx, job)

      job = finish(ctx, job, "done")

      assert job.recovery == nil
      a = card(ctx.a)
      assert a.column_id == ctx.doing.id
      assert a.verify_state == "merging"
      refute "blocked" in a.flags
      refute Enum.any?(comments(a), &(&1 =~ "Runner job ##{job.id}"))

      # The merge then closes it, as it would have.
      a = merged(ctx, a)
      assert a.completed
      assert a.column_id == ctx.done.id
    end

    test "a merge that finished first keeps the card in Done", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      ctx |> accept(job) |> then(&merged(ctx, &1))

      job = finish(ctx, job, "done")

      assert job.recovery == nil
      a = card(ctx.a)
      assert a.completed
      assert a.column_id == ctx.done.id
      refute Enum.any?(comments(a), &(&1 =~ "Runner job ##{job.id}"))
    end
  end

  # #2354: an epic's job submitted a subcard and ended, so the next subcard
  # waits for that one's verification and merge. The epic was put back on
  # To Do as a retry while it was still being worked, and its retry spent.
  describe "an epic whose subcard waits for its verifier or its merge" do
    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.a, t)
      sub = Boards.get_board!(sub.id)
      first = card_fixture(hd(sub.columns), %{"title" => "first"})
      second = card_fixture(hd(sub.columns), %{"title" => "second"})

      builder = %{
        Actor.unknown()
        | kind: "agent",
          via: "api",
          user_id: ctx.owner.id,
          agent: "builder"
      }

      %{board: board, sub: sub, first: first, second: second, builder: builder}
    end

    defp set_verify_state(card, state, extra \\ []) do
      Repo.update_all(from(c in Boards.Card, where: c.id == ^card.id),
        set: [verify_state: state] ++ extra
      )
    end

    defp left_in_progress(ctx, job) do
      assert job.recovery == nil
      refute job.transcript_failed_at
      a = card(ctx.a)
      assert a.column_id == ctx.doing.id
      refute "blocked" in a.flags
      refute Enum.any?(comments(a), &(&1 =~ "Runner job ##{job.id}"))
      assert Repo.aggregate(from(j in Job, where: j.recovery == "requeued"), :count) == 0
    end

    test "the job that submitted a subcard leaves the epic in progress (#2354)", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      assert job.card_id == ctx.a.id

      # The epic's job submits its first subcard with its pull request.
      {:ok, first} =
        Boards.update_card(
          card(ctx.first),
          %{
            "completed" => true,
            "evidence_pr" => "https://github.com/acme/app/pull/7",
            "evidence_commit" => "abc1234"
          },
          actor: %{ctx.builder | job_id: job.id}
        )

      assert first.verify_state == "pending"
      refute first.completed

      left_in_progress(ctx, finish(ctx, job, "done"))
    end

    for state <- ~w(merging held) do
      test "a subcard #{state} leaves the epic in progress", ctx do
        rule_fixture(ctx.board, spec())
        job = take(ctx)
        set_verify_state(ctx.first, unquote(state))

        left_in_progress(ctx, finish(ctx, job, "done"))
      end
    end

    test "with no subcard waiting, the epic is put back as before", ctx do
      rule_fixture(ctx.board, spec())
      job = take(ctx)
      set_verify_state(ctx.first, "rejected")

      job = finish(ctx, job, "done")

      assert job.recovery == "requeued"
      assert card(ctx.a).column_id == ctx.todo.id
      assert List.last(comments(ctx.a)) =~ "retry 1 of 1"
    end

    for {why, extra} <- [completed: :completed, archived: :archived] do
      test "a waiting subcard that is #{why} doesn't hold it", ctx do
        extra =
          case unquote(extra) do
            :completed -> [completed: true]
            :archived -> [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)]
          end

        rule_fixture(ctx.board, spec())
        job = take(ctx)
        assert job.card_id == ctx.a.id
        set_verify_state(ctx.first, "pending", extra)

        job = finish(ctx, job, "done")

        assert job.recovery == "requeued"
        assert card(ctx.a).column_id == ctx.todo.id
        assert List.last(comments(ctx.a)) =~ "retry 1 of 1"
      end
    end

    test "a waiting card on another epic's sub-board doesn't hold it", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, other} = Boards.create_sub_board(ctx.b, t)
      other = Boards.get_board!(other.id)
      elsewhere = card_fixture(hd(other.columns), %{"title" => "elsewhere"})
      set_verify_state(elsewhere, "pending")

      rule_fixture(ctx.board, spec())
      job = take(ctx)
      assert job.card_id == ctx.a.id

      assert finish(ctx, job, "done").recovery == "requeued"
      assert card(ctx.a).column_id == ctx.todo.id
    end
  end
end
