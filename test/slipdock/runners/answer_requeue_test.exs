defmodule Slipdock.Runners.AnswerRequeueTest do
  @moduledoc """
  Re-queue on answer (#1115, KTD7): answering a wait a runner job asked
  sends the card to that job's rule again, with the question, the answer,
  who answered and the handoff on top of its prompt — at once, in place of
  a still-queued job's prompt, or once the rule's open job has closed — and
  says on the card why when it can't.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Repo, Runners}
  alias Slipdock.Boards.Wait
  alias Slipdock.Runners.{Job, Requeue}

  setup do
    owner = user_fixture()

    dana =
      "dana@example.com"
      |> user_fixture()
      |> Ecto.Changeset.change(name: "Dana")
      |> Repo.update!()

    board = board_fixture(%{"name" => "Answers"}, owner: owner)
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    [_backlog, todo, doing, done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    a = card_fixture(todo, %{"title" => "a"})

    %{
      owner: owner,
      dana: dana,
      board: board,
      todo: todo,
      doing: doing,
      done: done,
      runner: runner,
      a: a
    }
  end

  defp spec(action \\ %{}) do
    %{
      "trigger" => %{"type" => "list_top", "column" => "To Do"},
      "actions" => [Map.merge(%{"type" => "runner", "pool" => "loop"}, action)]
    }
  end

  defp jobs(rule),
    do: Repo.all(from(j in Job, where: j.rule_id == ^rule.id, order_by: [asc: j.id]))

  defp open_jobs(rule), do: rule |> jobs() |> Enum.filter(&Job.open?/1)

  defp take(ctx) do
    job = Runners.claim(ctx.runner)
    :ok = Boards.move_card_to_index(Repo.get!(Boards.Card, job.card_id), ctx.doing, :top)
    job
  end

  defp ask(ctx, job) do
    {:ok, wait} =
      Boards.open_wait(Repo.get!(Boards.Card, job.card_id), Actor.runner(ctx.owner, job.id), %{
        "needs" => "Which region?",
        "choices" => ["eu", "us"],
        "job_id" => job.id
      })

    wait
  end

  # The job asks, and parks.
  defp park(ctx) do
    job = take(ctx)
    ask(ctx, job)

    {:ok, %Job{status: "parked"} = job} =
      Runners.finish(ctx.runner, job.id, %{exit: "0", output: "Asked which region\nThe rest."})

    job
  end

  defp answer(ctx, card, attrs \\ %{"choice" => 1, "answer" => "eu, and soon"}) do
    {:ok, wait} = Boards.answer_wait(Boards.get_card!(card.id), Actor.web(ctx.dana), attrs)
    wait
  end

  defp comments(card), do: Enum.map(Boards.get_card!(card.id).comments, & &1.body)

  describe "answering a parked wait" do
    test "queues exactly one job for the same rule and pool, with the answer on top", ctx do
      rule = rule_fixture(ctx.board, spec())
      parked = park(ctx)
      assert open_jobs(rule) == []
      # Long enough ago that the card is past the feed's cool-down: only the
      # guard keeps the feed from sending it with its plain prompt.
      Repo.update_all(from(j in Job, where: j.id == ^parked.id),
        set: [finished_at: DateTime.add(DateTime.utc_now(:second), -7200)]
      )

      wait = answer(ctx, ctx.a)

      assert [fresh] = open_jobs(rule)
      assert fresh.card_id == ctx.a.id
      assert fresh.pool == "loop"
      assert fresh.id != parked.id
      assert wait.requeue_state == "queued"
      assert wait.requeue_job_id == fresh.id
      # The flag coming off didn't feed the card first with its plain prompt.
      assert wait.requeue_note == "job ##{fresh.id}"
      assert length(jobs(rule)) == 2

      assert String.starts_with?(
               fresh.prompt,
               "Question on card ##{ctx.a.id}: Which region?\n" <>
                 "Answer: eu — eu, and soon\n" <>
                 "Answered by: Dana\n" <>
                 "Handoff: Asked which region"
             )

      # The rule's own prompt follows, rendered again.
      assert fresh.prompt =~ "Work on Slipdock card ##{ctx.a.id}: a"
      assert String.ends_with?(fresh.prompt, Automations.Runner.unattended())
    end

    test "a claim then carries the wait and the handoff", ctx do
      rule_fixture(ctx.board, spec())
      park(ctx)
      wait = answer(ctx, ctx.a)

      job = Runners.claim(ctx.runner)
      assert %{wait: %Wait{} = carried, handoff: handoff} = Runners.claim_context(job)
      assert carried.id == wait.id
      assert handoff.next_step == "Asked which region"
    end

    test "a wait not asked from a job just closes", ctx do
      rule = rule_fixture(ctx.board, spec())
      job = take(ctx)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: "0"})

      {:ok, _} =
        Boards.open_wait(Boards.get_card!(ctx.a.id), Actor.web(ctx.owner), %{"needs" => "Why?"})

      wait = answer(ctx, ctx.a, %{"answer" => "because"})

      assert wait.requeue_state == "none"
      assert open_jobs(rule) == []
    end
  end

  describe "an answer while the job is still open" do
    test "running, then its lease lapses: it fails pointing at the one fresh job (AE2)", ctx do
      rule = rule_fixture(ctx.board, spec())
      job = take(ctx)
      ask(ctx, job)

      wait = answer(ctx, ctx.a)
      assert wait.requeue_state == "pending"
      assert Enum.any?(comments(ctx.a), &(&1 =~ "once job ##{job.id} (claimed on this card)"))

      Runners.sweep(DateTime.add(DateTime.utc_now(), 3600))

      job = Repo.reload!(job)
      assert job.status == "failed"
      assert [fresh] = open_jobs(rule)
      assert fresh.id != job.id
      assert fresh.status == "queued"
      assert fresh.prompt =~ "Question on card ##{ctx.a.id}: Which region?"
      assert job.error =~ "job ##{fresh.id} with the answer takes over"
      assert Repo.get!(Wait, wait.id).requeue_state == "queued"
    end

    test "still queued: its prompt is rewritten in place, and no second job is made", ctx do
      rule = rule_fixture(ctx.board, spec())
      job = take(ctx)
      ask(ctx, job)
      # Handed back before it was worked, the wait still open.
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [status: "queued"])

      wait = answer(ctx, ctx.a)

      assert [same] = jobs(rule)
      assert same.id == job.id
      assert same.status == "queued"
      assert same.prompt =~ "Question on card ##{ctx.a.id}: Which region?"
      assert wait.requeue_state == "queued"
      assert wait.requeue_job_id == job.id
    end

    test "another card's job from the same list_top rule: this one goes when it closes, first",
         ctx do
      b = card_fixture(ctx.todo, %{"title" => "b"})
      c = card_fixture(ctx.todo, %{"title" => "c"})
      rule = rule_fixture(ctx.board, spec())
      park(ctx)
      b_job = take(ctx)
      assert b_job.card_id == b.id

      wait = answer(ctx, ctx.a)
      assert wait.requeue_state == "pending"
      assert Enum.map(open_jobs(rule), & &1.card_id) == [b.id]

      {:ok, _} = Runners.finish(ctx.runner, b_job.id, %{exit: "0"})

      assert [next] = open_jobs(rule)
      assert next.card_id == ctx.a.id
      assert next.prompt =~ "Question on card ##{ctx.a.id}"
      refute Enum.any?(jobs(rule), &(&1.card_id == c.id))
      assert Repo.get!(Wait, wait.id).requeue_state == "queued"
    end

    test "an event rule's own job still open on the card: it goes once that closes", ctx do
      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "flag_added", "flag" => "starred"},
          "actions" => [%{"type" => "runner", "pool" => "loop"}]
        })

      {:ok, _} = Boards.update_card(ctx.a, %{"flags" => ["starred"]})
      job = take(ctx)
      ask(ctx, job)

      assert answer(ctx, ctx.a).requeue_state == "pending"

      {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: "0"})
      assert [fresh] = open_jobs(rule)
      assert fresh.prompt =~ "Question on card ##{ctx.a.id}"
    end
  end

  describe "a prompt that would be too long" do
    test "cuts the handoff first, and still names the card", ctx do
      rule_fixture(ctx.board, spec(%{"prompt" => String.duplicate("x", 18_000)}))
      park(ctx)

      {:ok, _} =
        Boards.leave_handoff(Boards.get_card!(ctx.a.id), ctx.owner, %{
          next_step: "Pick a region",
          body: String.duplicate("é", 4_000),
          via: "ui"
        })

      answer(ctx, ctx.a, %{"answer" => "eu"})

      [fresh] = Repo.all(from(j in Job, where: j.status == "queued"))
      assert byte_size(fresh.prompt) <= Runners.limits().max_prompt
      assert String.valid?(fresh.prompt)
      assert String.starts_with?(fresh.prompt, "Question on card ##{ctx.a.id}: Which region?")
      assert fresh.prompt =~ "Answer: eu\n"
      assert fresh.prompt =~ "(cut short: the whole text is on card ##{ctx.a.id})"
    end

    test "cuts the answer too when the handoff alone isn't enough" do
      card = %Boards.Card{id: 7}

      wait = %Wait{
        needs: "Which?",
        choices: [],
        answer: String.duplicate("a", 30_000),
        closed_by: nil,
        closed_by_id: nil,
        card_id: 7
      }

      prompt = Requeue.prompt(wait, card, "body")
      assert byte_size(prompt) <= Runners.limits().max_prompt
      assert String.starts_with?(prompt, "Question on card #7: Which?")
      assert prompt =~ "(cut short: the whole text is on card #7)"
      assert String.ends_with?(prompt, "body")
    end
  end

  describe "when the answer can't start a job (AE3)" do
    test "the rule is off: skipped, and the card says so", ctx do
      rule = rule_fixture(ctx.board, spec())
      park(ctx)
      {:ok, rule} = Automations.update_rule(rule, %{"enabled" => false})

      wait = answer(ctx, ctx.a)

      assert wait.requeue_state == "skipped"
      assert open_jobs(rule) == []
      assert Enum.any?(comments(ctx.a), &(&1 =~ "rule “#{rule.name}” is off; nothing was sent"))
      assert Enum.any?(comments(ctx.a), &(&1 =~ "Answered “Which region?”"))
    end

    test "the rule was deleted: skipped, and nothing made from the old prompt", ctx do
      rule = rule_fixture(ctx.board, spec())
      park(ctx)
      {:ok, _} = Automations.delete_rule(rule)

      wait = answer(ctx, ctx.a)

      assert wait.requeue_state == "skipped"
      assert Repo.all(from(j in Job, where: j.status in ^Job.open_statuses())) == []
      assert Enum.any?(comments(ctx.a), &(&1 =~ "deleted; nothing was sent"))
    end

    test "the card moved to another tree: skipped, with a comment", ctx do
      rule = rule_fixture(ctx.board, spec())
      park(ctx)
      other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
      {:ok, _} = Boards.move_card_to_board(Boards.get_card!(ctx.a.id), hd(other.columns))

      wait = answer(ctx, ctx.a)

      assert wait.requeue_state == "skipped"
      assert open_jobs(rule) == []
      assert Enum.any?(comments(ctx.a), &(&1 =~ "moved to another board tree"))
    end

    test "moved to another board in the same tree: queued there", ctx do
      rule = rule_fixture(ctx.board, spec())
      park(ctx)
      epic = card_fixture(ctx.done, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      {:ok, _} = Boards.move_card_to_board(Boards.get_card!(ctx.a.id), hd(sub.columns))

      wait = answer(ctx, ctx.a)

      assert wait.requeue_state == "queued"
      assert [fresh] = open_jobs(rule)
      assert fresh.board_id == sub.id
    end

    test "the card was completed: the wait closed with it, and nothing is sent", ctx do
      rule = rule_fixture(ctx.board, spec())
      park(ctx)
      {:ok, _} = Boards.update_card(Boards.get_card!(ctx.a.id), %{"completed" => true})

      assert {:error, _} =
               Boards.answer_wait(Boards.get_card!(ctx.a.id), Actor.web(ctx.dana), %{
                 "choice" => 1
               })

      assert open_jobs(rule) == []
    end

    test "the queue is full: failed, with the error on the card", ctx do
      rule = rule_fixture(ctx.board, spec())
      park(ctx)
      filler = card_fixture(ctx.done, %{"title" => "filler"})
      now = DateTime.utc_now(:second)

      Repo.insert_all(
        Job,
        for _ <- 1..Runners.limits().max_open_per_tree do
          %{
            board_id: ctx.board.id,
            root_board_id: ctx.board.id,
            card_id: filler.id,
            pool: "other",
            kind: "claude",
            prompt: "x",
            status: "queued",
            inserted_at: now,
            updated_at: now
          }
        end
      )

      wait = answer(ctx, ctx.a)

      assert wait.requeue_state == "failed"
      assert wait.requeue_note =~ "the queue is full"
      assert open_jobs(rule) == []

      assert Enum.any?(
               comments(ctx.a),
               &(&1 =~ "couldn't be sent to the runners again: the queue is full")
             )
    end
  end
end
