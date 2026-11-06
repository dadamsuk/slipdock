defmodule Slipdock.Runners.AnswerRequeueTest do
  @moduledoc """
  Re-queue on answer (#1115, KTD7): answering a wait a runner job asked
  sends the card to that job's rule again, with the question, the answer,
  who answered and the handoff on top of its prompt — at once, in place of
  a still-queued job's prompt, in the slot of another card's job nobody has
  taken yet (#1750), or once the rule's job a runner has closed — and says
  on the card why when it can't.
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
      # Handed out, it isn't withdrawn: the answer waits for it.
      assert Repo.reload!(b_job).status == "claimed"

      assert Enum.any?(
               comments(ctx.a),
               &(&1 =~
                   "once job ##{b_job.id} (claimed on ##{b.id}) has closed: " <>
                     "it is already with a runner.")
             )

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

  describe "an answer while another card's job is still queued (#1750)" do
    # The rule sent the next card after the parked one, and nobody has taken
    # its job yet.
    defp queued_behind(ctx, title, paths \\ []) do
      next = card_fixture(ctx.todo, %{"title" => title})
      {:ok, next} = Boards.update_card(next, %{"paths" => paths})
      park(ctx)
      job = Repo.one!(from(j in Job, where: j.card_id == ^next.id and j.status == "queued"))
      {next, job}
    end

    test "the answered epic's own subcard lane-holds it: the answer takes its slot", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"lanes" => true})
      {:ok, a} = Boards.update_card(ctx.a, %{"paths" => ["docs/design/**"]})
      rule = rule_fixture(board, spec())

      # The epic's subcard sits in progress, holding docs/design/**.
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(a, t)
      sub = Boards.get_board!(sub.id)

      sub_doing =
        sub.columns
        |> Enum.find(&(&1.name == "Doing"))
        |> Ecto.Changeset.change(category: "doing")
        |> Repo.update!()

      child = card_fixture(sub_doing, %{"title" => "child"})
      {:ok, child} = Boards.update_card(child, %{"paths" => ["docs/design/**"]})

      {next, held} = queued_behind(ctx, "next", ["docs/**"])

      # While the epic's job is parked nothing works its subcard, so the
      # subcard holds no lane (#1922): the next card's job is free to go.
      assert Runners.held_reason(Repo.reload!(held), claimant: true) == nil
      assert child.paths == ["docs/design/**"]

      wait = answer(ctx, a)

      # Sent at once, not held behind a job that can't go until it does.
      assert wait.requeue_state == "queued"
      assert [fresh] = open_jobs(rule)
      assert fresh.card_id == a.id
      assert fresh.prompt =~ "Question on card ##{a.id}: Which region?"
      assert wait.requeue_job_id == fresh.id
      assert wait.requeue_note =~ "job ##{held.id} on ##{next.id} gave way"

      # The withdrawn job: cancelled, marked, and its card told it goes next.
      held = Repo.reload!(held)
      assert held.status == "cancelled"
      assert held.recovery == "withdrawn"
      assert held.error =~ "gave way to the answer on ##{a.id}"

      assert Enum.any?(
               comments(next),
               &(&1 =~ "Job ##{held.id} gave way to the answer on ##{a.id}" and
                   &1 =~ "goes next")
             )

      # Its card keeps its place.
      assert Repo.reload!(next).column_id == ctx.todo.id
      refute Enum.any?(comments(a), &(&1 =~ "once job"))

      # A runner can take the answer, the epic's own lane not counting against it.
      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == fresh.id
    end

    test "the withdrawn card is the next one the feed sends", ctx do
      rule = rule_fixture(ctx.board, spec())
      {next, held} = queued_behind(ctx, "next")
      # Below "next" in the list, so only the feed's order picks between them.
      later = card_fixture(ctx.todo, %{"title" => "later"})

      answer(ctx, ctx.a)
      assert [%Job{card_id: a_id} = fresh] = open_jobs(rule)
      assert a_id == ctx.a.id

      claimed = Runners.claim(ctx.runner)
      assert claimed.id == fresh.id
      {:ok, _} = Runners.finish(ctx.runner, fresh.id, %{exit: "0"})

      # The withdrawn job's own ending doesn't cool its card down.
      assert [again] = open_jobs(rule)
      assert again.card_id == next.id
      assert again.id != held.id
      refute Enum.any?(jobs(rule), &(&1.card_id == later.id))
    end

    test "a second answer racing it pends behind the first: one job per card", ctx do
      b = card_fixture(ctx.todo, %{"title" => "b"})
      c = card_fixture(ctx.todo, %{"title" => "c"})
      rule = rule_fixture(ctx.board, spec())
      # a parks, then b is sent and parks too; then c is sent and stays queued.
      a_job = park(ctx)
      b_job = take(ctx)
      assert b_job.card_id == b.id
      ask(ctx, b_job)
      {:ok, %Job{status: "parked"}} = Runners.finish(ctx.runner, b_job.id, %{exit: "0"})
      assert [%Job{status: "queued"} = c_job] = open_jobs(rule)
      assert c_job.card_id == c.id

      wait_a = answer(ctx, ctx.a)
      wait_b = answer(ctx, b)

      # The first takes c's slot; the second doesn't take the first's.
      assert wait_a.requeue_state == "queued"
      assert wait_b.requeue_state == "pending"

      assert Enum.any?(
               comments(b),
               &(&1 =~ "it carries another answer, which goes first.")
             )

      assert [a_fresh] = open_jobs(rule)
      assert a_fresh.card_id == ctx.a.id
      assert a_fresh.id != a_job.id
      assert Repo.reload!(c_job).status == "cancelled"

      # The first answer acted on again (two effects racing): still one job.
      assert Requeue.after_answer(Repo.get!(Wait, wait_a.id)) == :queued

      assert Repo.aggregate(
               from(j in Job, where: j.card_id == ^ctx.a.id and j.status == "queued"),
               :count
             ) == 1

      # a done: b's answer goes, then c.
      Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, a_fresh.id, %{exit: "0"})
      assert [b_fresh] = open_jobs(rule)
      assert b_fresh.card_id == b.id
      assert b_fresh.prompt =~ "Question on card ##{b.id}"
      assert Repo.get!(Wait, wait_b.id).requeue_state == "queued"

      Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, b_fresh.id, %{exit: "0"})
      assert [c_again] = open_jobs(rule)
      assert c_again.card_id == c.id
    end

    test "running, not queued: the job keeps its slot and holds the answer", ctx do
      rule = rule_fixture(ctx.board, spec())
      {_next, held} = queued_behind(ctx, "next")
      Repo.update_all(from(j in Job, where: j.id == ^held.id), set: [status: "running"])

      wait = answer(ctx, ctx.a)

      assert wait.requeue_state == "pending"
      assert [%Job{status: "running"} = still] = open_jobs(rule)
      assert still.id == held.id
      assert is_nil(still.recovery)
    end

    test "an answer held behind a job that went back to the queue goes on the next feed",
         ctx do
      rule = rule_fixture(ctx.board, spec())
      {_next, held} = queued_behind(ctx, "next")
      # Handed out when the answer came, so the answer was held...
      Repo.update_all(from(j in Job, where: j.id == ^held.id), set: [status: "claimed"])
      wait = answer(ctx, ctx.a)
      assert wait.requeue_state == "pending"
      # ...then back in the queue (its lease lapsed, say) without closing.
      Repo.update_all(from(j in Job, where: j.id == ^held.id), set: [status: "queued"])

      assert {:ok, card} = Automations.feed(Repo.get!(Automations.Rule, rule.id))
      assert card.id == ctx.a.id
      assert [fresh] = open_jobs(rule)
      assert fresh.card_id == ctx.a.id
      assert Repo.reload!(held).recovery == "withdrawn"
      assert Repo.get!(Wait, wait.id).requeue_state == "queued"
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

  describe "a wait on a subcard, asked from the epic's job (#1755)" do
    setup ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, board} = sub_board(ctx.a, t)
      sub = card_fixture(hd(Boards.get_board!(board.id).columns), %{"title" => "Pick region"})
      {:ok, deeper} = sub_board(sub, t)
      subsub = card_fixture(hd(Boards.get_board!(deeper.id).columns), %{"title" => "Size"})
      %{sub: sub, subsub: subsub}
    end

    # The epic's job asks on `card`, beneath it, and parks.
    defp park_on(ctx, card) do
      job = take(ctx)
      assert job.card_id == ctx.a.id

      {:ok, wait} =
        Boards.open_wait(Boards.get_card!(card.id), Actor.runner(ctx.owner, job.id), %{
          "needs" => "Which region?",
          "choices" => ["eu", "us"],
          "job_id" => job.id
        })

      {:ok, %Job{status: "parked"} = job} = Runners.finish(ctx.runner, job.id, %{exit: "0"})
      {job, wait}
    end

    test "the answer re-queues the epic's job, its prompt naming the subcard and answer", ctx do
      rule = rule_fixture(ctx.board, spec())
      {parked, asked} = park_on(ctx, ctx.sub)
      assert asked.card_id == ctx.sub.id

      wait = answer(ctx, ctx.sub)

      assert [fresh] = open_jobs(rule)
      assert fresh.card_id == ctx.a.id
      assert fresh.id != parked.id
      assert {wait.requeue_state, wait.requeue_job_id} == {"queued", fresh.id}

      assert String.starts_with?(
               fresh.prompt,
               "Question on subcard ##{ctx.sub.id} “Pick region” (beneath ##{ctx.a.id}): " <>
                 "Which region?\nAnswer: eu — eu, and soon\nAnswered by: Dana"
             )

      assert fresh.prompt =~ "Work on Slipdock card ##{ctx.a.id}: a"
      refute "waiting" in Boards.get_card!(ctx.sub.id).flags

      claimed = Runners.claim(ctx.runner)
      assert claimed.id == fresh.id
      assert Runners.claim_context(claimed).wait.id == wait.id
    end

    test "a subcard's subcard re-queues the epic's job too", ctx do
      rule = rule_fixture(ctx.board, spec())
      park_on(ctx, ctx.subsub)

      answer(ctx, ctx.subsub, %{"answer" => "large"})

      assert [fresh] = open_jobs(rule)
      assert fresh.card_id == ctx.a.id

      assert fresh.prompt =~
               "Question on subcard ##{ctx.subsub.id} “Size” (beneath ##{ctx.a.id}): " <>
                 "Which region?\nAnswer: large\n"
    end

    test "answered while the epic's job still runs: held, and the subcard says so", ctx do
      rule = rule_fixture(ctx.board, spec())
      job = take(ctx)

      {:ok, _} =
        Boards.open_wait(Boards.get_card!(ctx.sub.id), Actor.runner(ctx.owner, job.id), %{
          "needs" => "Which region?",
          "job_id" => job.id
        })

      wait = answer(ctx, ctx.sub, %{"answer" => "eu"})

      assert wait.requeue_state == "pending"
      assert Enum.map(open_jobs(rule), & &1.id) == [job.id]

      assert Enum.any?(
               comments(ctx.sub),
               &(&1 =~ "once job ##{job.id} (claimed on ##{ctx.a.id})")
             )
    end

    test "the epic closed meanwhile: skipped, and the subcard says why", ctx do
      rule = rule_fixture(ctx.board, spec())
      park_on(ctx, ctx.sub)
      Repo.update_all(from(c in Boards.Card, where: c.id == ^ctx.a.id), set: [completed: true])

      wait = answer(ctx, ctx.sub)

      assert wait.requeue_state == "skipped"
      assert open_jobs(rule) == []

      assert Enum.any?(
               comments(ctx.sub),
               &(&1 =~ "card ##{ctx.a.id}, whose job asked it, is closed; nothing was sent")
             )
    end
  end
end
