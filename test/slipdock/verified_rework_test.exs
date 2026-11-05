defmodule Slipdock.VerifiedReworkTest do
  @moduledoc """
  Rework (#1659): a card a verifier rejects goes back to the runners. A job
  that ends with its card awaiting verification leaves it alone; a
  rejection takes off the assignment the building agent made (a person's
  stays), isn't held by the feed's cool-down and feeds the board; and the
  reason is on the comment and the card, not copied into the handoff, and
  reaches the next agent through its claimed prompt.
  """
  use Slipdock.DataCase, async: false

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Actor, Boards, Repo, Runners, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("rework-owner@example.com")
    helper = user_fixture("rework-helper@example.com")

    board =
      board_fixture(%{"name" => "Rework", "code" => unique_code()}, owner: owner)

    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    {:ok, _} = Access.grant(board, helper, "write", owner)
    [_backlog, todo, doing, _done] = board.columns

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    %{
      owner: owner,
      helper: helper,
      board: board,
      todo: todo,
      doing: doing,
      builder: agent.("builder"),
      checker: agent.("checker"),
      person: Actor.web(owner)
    }
  end

  defp assign(card, ids, actor),
    do: {:ok, _} = Boards.update_card(card, %{"assignee_ids" => ids}, actor: actor)

  defp submit(card, actor) do
    {:ok, card} =
      Boards.update_card(Repo.get!(Card, card.id), %{"completed" => true}, actor: actor)

    assert card.verify_state == "pending"
    card
  end

  defp reject(card, ctx, reason \\ "bar 1: The empty list case fails") do
    {:ok, card} =
      Verified.decide(
        Repo.get!(Card, card.id),
        "reject",
        %{"reason" => reason},
        ctx.checker,
        ctx.owner
      )

    card
  end

  defp comments(card),
    do:
      Repo.all(
        from(c in Boards.Comment,
          where: c.card_id == ^card.id,
          order_by: [asc: c.id],
          select: c.body
        )
      )

  defp ids(card), do: Boards.assignee_ids(Repo.get!(Card, card.id))

  describe "who an agent assigned" do
    test "an agent's self-assignment comes off on a rejection", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Self"})
      assign(card, [ctx.owner.id], ctx.builder)
      assert Repo.get!(Card, card.id).agent_assignee_ids == [ctx.owner.id]

      card |> submit(ctx.builder) |> reject(ctx)

      assert ids(card) == []
      assert Repo.get!(Card, card.id).agent_assignee_ids == []
    end

    test "a person's assignment survives a rejection, beside an agent's that doesn't", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Mixed"})
      assign(card, [ctx.helper.id], ctx.person)
      assign(Repo.get!(Card, card.id), [ctx.helper.id, ctx.owner.id], ctx.builder)
      assert Repo.get!(Card, card.id).agent_assignee_ids == [ctx.owner.id]

      card |> submit(ctx.builder) |> reject(ctx)

      assert ids(card) == [ctx.helper.id]
    end

    test "the same person assigned by a person survives, even if it is the token's user", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Mine"})
      assign(card, [ctx.owner.id], ctx.person)

      card |> submit(ctx.builder) |> reject(ctx)

      assert ids(card) == [ctx.owner.id]
    end

    test "the in-app assistant assigns on a person's say: that stays", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Assistant"})
      assign(card, [ctx.owner.id], Actor.assistant(ctx.owner))
      assert Repo.get!(Card, card.id).agent_assignee_ids == []

      card |> submit(ctx.builder) |> reject(ctx)

      assert ids(card) == [ctx.owner.id]
    end

    test "a person taking the agent's assignee off and on again makes it theirs", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Taken over"})
      assign(card, [ctx.owner.id], ctx.builder)
      assign(Repo.get!(Card, card.id), [], ctx.person)
      assert Repo.get!(Card, card.id).agent_assignee_ids == []
      assign(Repo.get!(Card, card.id), [ctx.owner.id], ctx.person)

      card |> submit(ctx.builder) |> reject(ctx)

      assert ids(card) == [ctx.owner.id]
    end

    test "a person adding someone the agent had put on keeps them", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Re-added"})
      assign(card, [ctx.owner.id], ctx.builder)

      {:ok, _} =
        Boards.update_card(Repo.get!(Card, card.id), %{"add_assignee_ids" => [ctx.helper.id]},
          actor: ctx.person
        )

      card |> submit(ctx.builder) |> reject(ctx)

      assert ids(card) == [ctx.helper.id]
    end

    test "an acceptance leaves every assignee on", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Accepted"})
      assign(card, [ctx.owner.id], ctx.builder)
      card = submit(card, ctx.builder)

      {:ok, card} = Verified.decide(card, "accept", %{}, ctx.checker, nil)

      assert card.completed
      assert ids(card) == [ctx.owner.id]
    end
  end

  describe "the reason, once" do
    test "the handoff points at the verification block and doesn't copy the reason", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Reason"})
      card = card |> submit(ctx.builder) |> reject(ctx, "bar 1: Empty list fails\nSee the log")

      handoff = Boards.current_handoff(card)
      assert handoff.next_step == "Rework: rejected by agent “checker”, reason under Verification"
      assert handoff.body in [nil, ""]

      refute Enum.any?(Boards.handoff_history(card), fn h ->
               (h.next_step || "") <> (h.body || "") =~ "Empty list fails"
             end)

      # Once as the comment, once on the card (the verification block).
      assert [comment] = Enum.filter(comments(card), &(&1 =~ "Empty list fails"))
      assert comment =~ "**Rejected** by agent “checker”"
      assert Repo.get!(Card, card.id).verify_note == "bar 1: Empty list fails\nSee the log"
    end

    test "rejection/1 names the reason and who, only for a rejected card", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Who"})
      assert Verified.rejection(card) == nil
      card = submit(card, ctx.builder)
      assert Verified.rejection(card) == nil

      card = reject(card, ctx, "bar 1: Fix the parser")

      assert %{reason: "bar 1: Fix the parser", by: "agent “checker”", rejections: 1} =
               Verified.rejection(card)
    end
  end

  describe "with a runner rule" do
    setup ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})

      spec = %{
        "trigger" => %{"type" => "list_top", "column" => "To Do", "unassigned" => true},
        "actions" => [%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 2}]
      }

      %{runner: runner, spec: spec}
    end

    defp open_jobs(rule),
      do:
        Repo.all(
          from(j in Job,
            where: j.rule_id == ^rule.id and j.status in ^Job.open_statuses(),
            select: j.card_id
          )
        )

    # The runner takes the job; its agent moves the card along, assigns
    # itself and submits the work.
    defp build(ctx, job) do
      card = Repo.get!(Card, job.card_id)
      builder = %{ctx.builder | via: "runner", job_id: job.id}
      :ok = Boards.move_card_to_index(card, ctx.doing, :top, actor: builder)
      assign(Repo.get!(Card, card.id), [ctx.owner.id], builder)
      submit(card, builder)
    end

    test "a job ending with its card awaiting verification leaves it alone", ctx do
      a = card_fixture(ctx.todo, %{"title" => "a"})
      rule = rule_fixture(ctx.board, ctx.spec)
      job = Runners.claim(ctx.runner)
      assert job.card_id == a.id
      build(ctx, job)

      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})

      assert Repo.reload!(job).recovery == nil
      card = Repo.get!(Card, a.id)
      assert card.column_id == ctx.doing.id
      assert card.verify_state == "pending"
      refute "blocked" in card.flags
      refute Enum.any?(comments(card), &(&1 =~ "Runner job ##{job.id}"))
      assert open_jobs(rule) == []
    end

    test "a card not awaiting verification is still put back", ctx do
      a = card_fixture(ctx.todo, %{"title" => "a"})
      rule_fixture(ctx.board, ctx.spec)
      job = Runners.claim(ctx.runner)
      :ok = Boards.move_card_to_index(Repo.get!(Card, a.id), ctx.doing, :top)

      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})

      assert Repo.reload!(job).recovery == "requeued"
    end

    test "a rejection skips the cool-down and sends the card next, its reason in the prompt",
         ctx do
      a = card_fixture(ctx.todo, %{"title" => "a"})
      rule = rule_fixture(ctx.board, ctx.spec)
      job = Runners.claim(ctx.runner)
      assert job.card_id == a.id
      build(ctx, job)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})

      # A newer card goes meanwhile, and its job ends with it left in To Do
      # (cooling).
      c = card_fixture(ctx.todo, %{"title" => "c"})
      assert open_jobs(rule) == [c.id]
      other = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, other.id, %{status: "failed"})
      assert open_jobs(rule) == []

      # The job on `a` ended seconds ago: without the rejection it would cool.
      assert Slipdock.Automations.next_card(rule) == nil

      card = reject(a, ctx, "bar 1: Handle the empty list")

      assert card.column_id == ctx.todo.id
      assert ids(card) == []
      assert open_jobs(rule) == [a.id]

      again = Runners.claim(ctx.runner)
      assert again.card_id == a.id
      prompt = Runners.claimed_prompt(again)
      assert prompt =~ "rejected by agent “checker”"
      assert prompt =~ "bar 1: Handle the empty list"
    end

    test "a rejection older than the card's last job doesn't lift its cool-down", ctx do
      a = card_fixture(ctx.todo, %{"title" => "a"})
      rule = rule_fixture(ctx.board, ctx.spec)
      job = Runners.claim(ctx.runner)
      build(ctx, job)

      # Rejected before the job ended (an hour ago, say), then the job ends.
      long_ago = DateTime.add(DateTime.utc_now(:second), -3600)

      Repo.update_all(from(c in Card, where: c.id == ^a.id),
        set: [verify_state: "rejected", verify_at: long_ago, flags: [], assignee_id: nil]
      )

      Repo.delete_all(from(x in "card_assignees", where: x.card_id == ^a.id))
      :ok = Boards.move_card_to_index(Repo.get!(Card, a.id), ctx.todo, :top)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "failed"})

      assert Slipdock.Automations.next_card(rule) == nil
    end

    test "a pending card's claimed prompt carries no rejection", ctx do
      a = card_fixture(ctx.todo, %{"title" => "a"})
      rule_fixture(ctx.board, ctx.spec)
      job = Runners.claim(ctx.runner)
      assert job.card_id == a.id
      refute Runners.claimed_prompt(job) =~ "rejected"
    end
  end

  describe "repeated rejections go to a person (#1779)" do
    defp submit_with_evidence(card, actor) do
      {:ok, card} =
        Boards.update_card(
          Repo.get!(Card, card.id),
          %{"completed" => true, "evidence" => "ran it", "evidence_commit" => "abc1234"},
          actor: actor
        )

      assert card.verify_state == "pending"
      card
    end

    defp round(card, ctx, n),
      do: card |> submit_with_evidence(ctx.builder) |> reject(ctx, "bar #{n}: try #{n}")

    defp wait_of(card), do: Repo.get_by(Boards.Wait, card_id: card.id)

    defp bodies(card),
      do:
        Repo.all(
          from(c in Boards.Comment,
            where: c.card_id == ^card.id,
            order_by: [asc: c.id],
            select: c.body
          )
        )

    test "the default limit is 2: the third rejection opens a wait on the owner", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Bounce"})
      assert Verified.rejection_limit(card) == 2

      card = round(card, ctx, 1)
      card = round(card, ctx, 2)
      assert wait_of(card) == nil
      refute "waiting" in card.flags
      assert card.evidence == nil

      card = round(card, ctx, 3)
      card = Repo.get!(Card, card.id)
      wait = wait_of(card)

      assert wait.purpose == "verify_limit"
      assert wait.on_user_id == ctx.owner.id
      assert wait.choices == ["Rework as rejected", "Accept as is"]
      assert wait.needs =~ "was rejected 3 times (the board allows 2)"
      assert wait.needs =~ "you can edit the bar before you answer"
      assert String.length(wait.needs) <= 1000
      assert "waiting" in card.flags
      assert card.verify_rejections == 3
      # Kept, for an acceptance as is.
      assert card.evidence == "ran it"

      reasons = Enum.find(bodies(card), &(&1 =~ "**Rejected 3 times**"))
      assert reasons =~ "past the board's limit of 2"
      assert reasons =~ "1. bar 1: try 1\n2. bar 2: try 2\n3. bar 3: try 3"
    end

    test "at 0 no rejection opens a wait; at 1 the second does", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"verify_rejection_limit" => 0})
      card = card_fixture(ctx.doing, %{"title" => "Free"})
      card = Enum.reduce(1..4, card, &round(&2, ctx, &1))
      assert wait_of(card) == nil
      refute "waiting" in Repo.get!(Card, card.id).flags

      {:ok, _} = Boards.update_board(ctx.board, %{"verify_rejection_limit" => 1})
      other = card_fixture(ctx.doing, %{"title" => "Tight"})
      other = round(other, ctx, 1)
      assert wait_of(other) == nil
      other = round(other, ctx, 2)
      assert wait_of(other).needs =~ "rejected 2 times (the board allows 1)"
    end

    test "a sub-board's card takes its root board's limit", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"verify_rejection_limit" => 0})
      epic = card_fixture(ctx.doing, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      [column | _] = Boards.get_board!(sub.id).columns
      child = card_fixture(column, %{"title" => "Child"})
      assert Verified.rejection_limit(child) == 0
    end

    test "Accept as is accepts it for the person who answered", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Judgement call"})
      card = Enum.reduce(1..3, card, &round(&2, ctx, &1))

      {:ok, _} = Boards.answer_wait(Repo.get!(Card, card.id), ctx.person, %{"choice" => 2})

      card = Repo.get!(Card, card.id)
      assert card.completed
      assert card.verify_state == "accepted"
      assert card.verify_by["kind"] != "agent"
      refute "waiting" in card.flags
      assert Enum.any?(bodies(card), &(&1 =~ "Accepted as is by" and &1 =~ "after 3 rejections"))
      done = Enum.find(ctx.board.columns, &(&1.category == "done"))
      assert card.column_id == done.id
    end

    test "on a pull request board, Accept as is queues the merge of the kept pull request",
         ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"ship_via" => "pull_request"})
      card = card_fixture(ctx.doing, %{"title" => "PR bounce"})

      card =
        Enum.reduce(1..3, card, fn n, c ->
          {:ok, c} =
            Boards.update_card(
              Repo.get!(Card, c.id),
              %{
                "completed" => true,
                "evidence_pr" => "https://github.com/acme/app/pull/7",
                "evidence_commit" => "abc1234"
              },
              actor: ctx.builder
            )

          reject(c, ctx, "bar #{n}: no")
        end)

      assert Repo.get!(Card, card.id).evidence_pr == "https://github.com/acme/app/pull/7"
      {:ok, _} = Boards.answer_wait(Repo.get!(Card, card.id), ctx.person, %{"choice" => 2})

      card = Repo.get!(Card, card.id)
      assert card.verify_state == "merging"
      refute card.completed
    end

    test "Rework as rejected, a free answer or a skip clears the evidence and sends it back",
         ctx do
      for answer <- [%{"choice" => 1}, %{"answer" => "Do the footer too"}, %{"skip" => true}] do
        card = card_fixture(ctx.doing, %{"title" => "Again #{inspect(answer)}"})
        card = Enum.reduce(1..3, card, &round(&2, ctx, &1))
        assert Repo.get!(Card, card.id).evidence == "ran it"

        {:ok, _} = Boards.answer_wait(Repo.get!(Card, card.id), ctx.person, answer)

        card = Repo.get!(Card, card.id)
        assert card.verify_state == "rejected"
        refute card.completed
        assert card.evidence == nil
        assert card.evidence_commit == nil
        refute "waiting" in card.flags
        assert card.column_id == ctx.todo.id
      end
    end

    test "a wait not opened for the limit is left alone when answered", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Plain"})
      card = round(card, ctx, 1)
      {:ok, _} = Boards.open_wait(Repo.get!(Card, card.id), ctx.person, %{needs: "Which?"})
      {:ok, _} = Boards.answer_wait(Repo.get!(Card, card.id), ctx.checker, %{"answer" => "This"})

      card = Repo.get!(Card, card.id)
      assert card.verify_state == "rejected"
      refute card.completed
      assert :ok = Verified.wait_closed(%Boards.Wait{purpose: nil}, ctx.person)
    end
  end

  describe "repeated rejections and the feed (#1779)" do
    setup ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})

      spec = %{
        "trigger" => %{"type" => "list_top", "column" => "To Do", "unassigned" => true},
        "actions" => [%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 2}]
      }

      {:ok, _} = Boards.update_board(ctx.board, %{"verify_rejection_limit" => 1})
      %{runner: runner, rule: rule_fixture(ctx.board, spec)}
    end

    defp queued(rule),
      do:
        Repo.all(
          from(j in Job,
            where: j.rule_id == ^rule.id and j.status in ^Job.open_statuses(),
            select: j.card_id
          )
        )

    defp build_and_reject(ctx, n) do
      job = Runners.claim(ctx.runner)
      card = Repo.get!(Card, job.card_id)
      builder = %{ctx.builder | via: "runner", job_id: job.id}
      :ok = Boards.move_card_to_index(card, ctx.doing, :top, actor: builder)
      submit(card, builder)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})
      reject(card, ctx, "bar 1: round #{n}")
    end

    test "the waiting card isn't sent; Rework sends it again", ctx do
      a = card_fixture(ctx.todo, %{"title" => "a"})

      build_and_reject(ctx, 1)
      assert queued(ctx.rule) == [a.id]

      build_and_reject(ctx, 2)
      card = Repo.get!(Card, a.id)
      assert "waiting" in card.flags
      assert card.column_id == ctx.todo.id
      assert queued(ctx.rule) == []

      {:ok, _} = Boards.answer_wait(card, ctx.person, %{"choice" => 1})
      assert queued(ctx.rule) == [a.id]
    end
  end
end
