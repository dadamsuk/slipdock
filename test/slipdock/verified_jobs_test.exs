defmodule Slipdock.VerifiedJobsTest do
  @moduledoc """
  Verified work 4 (#1634): a board that verifies work and names a runner
  pool queues each submitted card for it as a `verify` job, whose prompt
  carries the bar, the evidence and how to decide; a decision stops the
  other verify jobs on the card. No pool, or verification off, queues none.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Portable, Verified}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Jobs", "code" => unique_code()}, owner: owner)
    [_backlog, _todo, doing, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})

    builder = %{
      Actor.unknown()
      | kind: "agent",
        via: "runner",
        user_id: owner.id,
        agent: "r",
        job_id: 1
    }

    %{owner: owner, board: board, card: card, builder: builder}
  end

  defp set(ctx, attrs) do
    {:ok, board} = Boards.update_board(ctx.board, attrs)
    board
  end

  defp submit(ctx, attrs \\ %{}) do
    {:ok, card} =
      Boards.update_card(ctx.card, Map.merge(%{"completed" => true}, attrs),
        actor: ctx.builder,
        by: ctx.owner
      )

    card
  end

  defp jobs(card), do: Repo.all(from(j in Job, where: j.card_id == ^card.id, order_by: j.id))

  test "a pool on a board that doesn't verify queues nothing", ctx do
    set(ctx, %{"verify_pool" => "checkers"})
    submit(ctx)
    assert jobs(ctx.card) == []
  end

  test "verifying with no pool queues nothing; the card waits", ctx do
    set(ctx, %{"verify_work" => true})
    card = submit(ctx)
    assert card.verify_state == "pending"
    assert jobs(card) == []
  end

  test "the pool name is tidied and checked", ctx do
    assert set(ctx, %{"verify_pool" => "  Checkers "}).verify_pool == "checkers"
    assert set(ctx, %{"verify_pool" => ""}).verify_pool == nil
    assert {:error, cs} = Boards.update_board(ctx.board, %{"verify_pool" => "no spaces"})
    assert %{verify_pool: [_]} = errors_on(cs)
  end

  describe "with a pool" do
    setup ctx, do: %{board: set(ctx, %{"verify_work" => true, "verify_pool" => "checkers"})}

    test "a submission queues a verify job for the pool, with what to check", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"bar" => "The export has a header row"})

      card =
        submit(%{ctx | card: Boards.get_card!(ctx.card.id)}, %{
          "evidence" => "mix test: 4 passed",
          "evidence_commit" => "abc1234"
        })

      assert [job] = jobs(card)
      assert job.pool == "checkers"
      assert job.kind == "verify"
      assert job.status == "queued"
      assert job.prompt =~ "Verify card ##{card.id} “Work”"
      assert job.prompt =~ "The export has a header row"
      assert job.prompt =~ "mix test: 4 passed"
      assert job.prompt =~ "Check out abc1234 in a clean tree"
      assert job.prompt =~ "git worktree add /tmp/verify-#{card.id} abc1234"
      assert job.prompt =~ "slipdock verify #{card.id} accept --evidence-commit abc1234"
      assert job.prompt =~ "/boards/#{ctx.board.id}/cards/#{card.id}"
    end

    test "with no bar or evidence the prompt says so", ctx do
      card = submit(ctx)
      [job] = jobs(card)
      assert job.prompt =~ "(none written"
      assert job.prompt =~ "Commit: (none given)"
      refute job.prompt =~ "--evidence-commit"
    end

    test "submitting again while pending doesn't queue a second", ctx do
      card = submit(ctx)
      {:ok, _} = Boards.update_card(card, %{"completed" => true}, actor: ctx.builder)
      assert length(jobs(card)) == 1
    end

    test "a decision stops the other verify jobs, but not the decider's own", ctx do
      card = submit(ctx)
      [first] = jobs(card)

      {:ok, second} =
        Slipdock.Runners.queue(card, %{pool: "checkers", kind: "verify", prompt: "x"})

      checker = %{ctx.builder | job_id: second.id}

      {:ok, _} =
        Verified.decide(card, "reject", %{"reason" => "bar 1: No header"}, checker, ctx.owner)

      assert Repo.get!(Job, first.id).status == "cancelled"
      assert Repo.get!(Job, second.id).status == "queued"

      # Fixed and submitted again: a fresh job.
      card = Boards.get_card!(card.id)
      {:ok, _} = Boards.update_card(card, %{"completed" => true}, actor: ctx.builder)
      assert [_, _, third] = jobs(card)
      assert third.status == "queued"
    end

    test "a person completing the pending card stops its jobs", ctx do
      card = submit(ctx)
      {:ok, _} = Boards.update_card(card, %{"completed" => true}, actor: Actor.web(ctx.owner))
      assert [%{status: "cancelled"}] = jobs(card)
    end

    test "a job the queue won't take is said on the card, and the card still waits", ctx do
      now = DateTime.utc_now(:second)

      Repo.insert_all(
        Job,
        for _ <- 1..200 do
          %{
            board_id: ctx.board.id,
            root_board_id: ctx.board.id,
            card_id: ctx.card.id,
            pool: "other",
            kind: "claude",
            prompt: "",
            status: "queued",
            inserted_at: now,
            updated_at: now
          }
        end
      )

      card = submit(ctx)
      assert card.verify_state == "pending"
      refute Enum.any?(jobs(card), &(&1.kind == "verify"))
      [body] = Boards.get_card!(card.id).comments |> Enum.map(& &1.body)
      assert body =~ "**Verify job not queued** for pool `checkers`"
      assert body =~ "queue is full"
    end

    test "the runner that built the card never takes its verify job (#1625)", ctx do
      {:ok, builder, _} =
        Slipdock.Runners.create_runner(ctx.board, %{"name" => "a", "pool" => "checkers"})

      {:ok, other, _} =
        Slipdock.Runners.create_runner(ctx.board, %{"name" => "b", "pool" => "checkers"})

      # The builder runs the card's work job, and submits from it.
      {:ok, work} =
        Slipdock.Runners.queue(ctx.card, %{pool: "checkers", kind: "claude", prompt: "Do"})

      assert %{id: id} = Slipdock.Runners.claim(builder)
      assert id == work.id

      card = submit(%{ctx | builder: %{ctx.builder | job_id: work.id}})
      [verify] = Enum.filter(jobs(card), &(&1.kind == "verify"))
      assert verify.exclude_runner_id == builder.id

      assert Slipdock.Runners.claim(builder) == nil
      assert %{id: claimed} = Slipdock.Runners.claim(other)
      assert claimed == verify.id

      # Two runners in the pool: nothing to say on the card.
      refute Enum.any?(Boards.get_card!(card.id).comments, &(&1.body =~ "waits"))
    end

    test "with no job id, the builder is the last runner to take a job on the card", ctx do
      {:ok, builder, _} =
        Slipdock.Runners.create_runner(ctx.board, %{"name" => "a", "pool" => "checkers"})

      {:ok, _work} =
        Slipdock.Runners.queue(ctx.card, %{pool: "checkers", kind: "claude", prompt: "Do"})

      Slipdock.Runners.claim(builder)

      card = submit(%{ctx | builder: %{ctx.builder | job_id: nil}})
      [verify] = Enum.filter(jobs(card), &(&1.kind == "verify"))
      assert verify.exclude_runner_id == builder.id

      # The builder is the pool's only runner, so the job waits, and the card says so.
      [body] =
        Boards.get_card!(card.id).comments
        |> Enum.map(& &1.body)
        |> Enum.filter(&(&1 =~ "waits"))

      assert body =~
               "**Verify job ##{verify.id} waits:** the only runner in pool `checkers` built this card"

      assert Slipdock.Runners.claim(builder) == nil
      assert Repo.get!(Job, verify.id).status == "queued"
    end

    test "with no runner in the pool at all, the card says the job waits for one", ctx do
      card = submit(ctx)
      [verify] = jobs(card)
      assert verify.exclude_runner_id == nil

      assert Enum.any?(
               Boards.get_card!(card.id).comments,
               &(&1.body =~ "waits:** no runner is in pool `checkers` yet")
             )
    end

    test "the pool is inherited by subcards and carried by an export", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.card, t)
      assert sub.verify_pool == "checkers"

      doc = Portable.export(ctx.owner, boards: [Boards.get_board!(ctx.board.id)])
      assert hd(doc.boards).root.verify_pool == "checkers"
      {:ok, report} = Portable.import(ctx.owner, Jason.encode!(doc))
      assert Boards.get_board!(hd(report.boards).id).verify_pool == "checkers"
    end
  end

  describe "a rule proposal meets a bar asking for a rule (#1882)" do
    test "the prompt says an open proposal meets it, and a rejection never asks for an edit",
         ctx do
      {:ok, _} = Slipdock.Handbook.install(ctx.owner, ctx.board)
      board = Boards.get_board!(ctx.board.id)
      prompt = Verified.verify_prompt(ctx.card, board)

      assert prompt =~
               "A bar item that adds, rewords or drops a handbook rule is met by a matching " <>
                 "open rule proposal: a garden proposal with an `edit_section` step on that " <>
                 "page's `## Rules` that says what the bar asks"

      assert prompt =~
               "A rejection never asks the builder to edit `## Rules` directly: when the " <>
                 "proposal is missing or says the wrong thing, ask for it to be filed or corrected."

      assert prompt =~ "--check proposal --json"
      assert prompt =~ "judge the proposal's content, not the live Rules list"
      assert prompt =~ "name its id in the accept reason"
      # Still one bar step, numbered with the rest.
      assert prompt =~ "4. The bar. Each item"
      assert prompt =~ "5. The rules."
    end

    test "without a handbook there are no rules, and nothing about proposals", ctx do
      prompt = Verified.verify_prompt(ctx.card, ctx.board)
      assert prompt =~ "4. The bar. Each item"
      refute prompt =~ Verified.rule_proposal_sentence()
      refute prompt =~ Verified.rule_rejection_sentence()
      refute prompt =~ "garden"
    end
  end

  describe "missed should rules become findings (#1784)" do
    test "the prompt asks for them as a Findings block in the accept reason", ctx do
      {:ok, _} = Slipdock.Handbook.install(ctx.owner, ctx.board)
      prompt = Verified.verify_prompt(ctx.card, Boards.get_board!(ctx.board.id))

      assert prompt =~
               "List any `should` rule missed in the accept reason, each as a finding in a " <>
                 "`Findings:` block there (`- rule: ARCH-6 missed: <how>`)"
    end

    test "without a handbook there are no rules, and no ask for them", ctx do
      refute Verified.verify_prompt(ctx.card, ctx.board) =~ "Findings:"
    end

    test "an accept reason with that block leaves rule findings on the card", ctx do
      set(ctx, %{"verify_work" => true})
      card = submit(ctx, %{"evidence" => "mix test: 4 passed"})
      checker = %{ctx.builder | agent: "checker", job_id: nil}

      {:ok, _} =
        Verified.decide(
          card,
          "accept",
          %{"reason" => "Bar met.\n\nFindings:\n- rule: ARCH-6 missed: a clock of its own"},
          checker,
          ctx.owner
        )

      assert [%Slipdock.Findings.Finding{kind: "rule", source: "agent", text: text}] =
               Repo.all(from(f in Slipdock.Findings.Finding, where: f.card_id == ^card.id))

      assert text == "ARCH-6 missed: a clock of its own"
    end
  end
end
