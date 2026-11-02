defmodule Slipdock.VerifiedJobsTest do
  @moduledoc """
  Verified work 4 (#1634): a board that verifies work and names a runner
  pool queues each submitted card for it as a `verify` job, whose prompt
  carries the bar, the evidence and how to decide; a decision stops the
  other verify jobs on the card. No pool, or verification off, queues none.
  """
  use Slipdock.DataCase, async: false

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
      assert job.prompt =~ "Check out abc1234"
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
      {:ok, _} = Verified.decide(card, "reject", %{"reason" => "No header"}, checker, ctx.owner)

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
end
