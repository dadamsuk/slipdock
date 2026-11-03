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

  defp reject(card, ctx, reason \\ "The empty list case fails") do
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
      card = card |> submit(ctx.builder) |> reject(ctx, "Empty list fails\nSee the log")

      handoff = Boards.current_handoff(card)
      assert handoff.next_step == "Rework: rejected by agent “checker”, reason under Verification"
      assert handoff.body in [nil, ""]

      refute Enum.any?(Boards.handoff_history(card), fn h ->
               (h.next_step || "") <> (h.body || "") =~ "Empty list fails"
             end)

      # Once as the comment, once on the card (the verification block).
      assert [comment] = Enum.filter(comments(card), &(&1 =~ "Empty list fails"))
      assert comment =~ "**Rejected** by agent “checker”"
      assert Repo.get!(Card, card.id).verify_note == "Empty list fails\nSee the log"
    end

    test "rejection/1 names the reason and who, only for a rejected card", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Who"})
      assert Verified.rejection(card) == nil
      card = submit(card, ctx.builder)
      assert Verified.rejection(card) == nil

      card = reject(card, ctx, "Fix the parser")

      assert %{reason: "Fix the parser", by: "agent “checker”", rejections: 1} =
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

      card = reject(a, ctx, "Handle the empty list")

      assert card.column_id == ctx.todo.id
      assert ids(card) == []
      assert open_jobs(rule) == [a.id]

      again = Runners.claim(ctx.runner)
      assert again.card_id == a.id
      prompt = Runners.claimed_prompt(again)
      assert prompt =~ "rejected by agent “checker”"
      assert prompt =~ "Handle the empty list"
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
end
