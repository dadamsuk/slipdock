defmodule Slipdock.VerifiedNoCodeTest do
  @moduledoc """
  A card that changes no code on a pull request board (#1938): a sweep, a
  handbook reconcile or a read-and-file card has no branch and no pull
  request. An agent completes it with the reason in `evidence_no_code`
  instead of `evidence_pr`; without either the refusal stands, and with
  both it is refused. The verifier is told to judge the claim, and
  accepting it completes it with nothing to merge.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Runners.Job

  @why "a read-only sweep: filed #40 and #41, no code"
  @pr "https://github.com/acme/app/pull/131"

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "No code", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "evidence_required" => true,
        "ship_via" => "pull_request"
      })

    [_backlog, _todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Sweep the code"})
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "checker"}

    %{
      owner: owner,
      board: board,
      doing: doing,
      done: done,
      card: card,
      builder: builder,
      checker: checker
    }
  end

  defp fresh(card), do: Repo.get!(Card, card.id)

  defp submit(card, attrs, ctx) do
    Boards.update_card(
      fresh(card),
      Map.merge(%{"completed" => true, "evidence" => "swept lib/, filed two cards"}, attrs),
      actor: ctx.builder
    )
  end

  defp accept(card, ctx), do: Verified.decide(fresh(card), "accept", %{}, ctx.checker, ctx.owner)

  defp merge_jobs(card),
    do: Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == "merge"))

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  describe "an agent completing a card that changes no code" do
    test "with the reason, is submitted without a PR", ctx do
      assert {:ok, card} = submit(ctx.card, %{"evidence_no_code" => @why}, ctx)
      assert card.verify_state == "pending"
      assert card.evidence_no_code == @why
      assert card.evidence_pr == nil
      assert Verified.no_code?(card)
    end

    test "without the reason or a PR, the evidence_pr refusal still stands", ctx do
      assert {:error, cs} = submit(ctx.card, %{}, ctx)
      assert %{evidence_pr: [message]} = errors_on(cs)
      assert message =~ "--no-code"
      refute fresh(ctx.card).verify_state
    end

    test "a blank reason is no reason", ctx do
      assert {:error, cs} = submit(ctx.card, %{"evidence_no_code" => "   "}, ctx)
      assert %{evidence_pr: [_]} = errors_on(cs)
    end

    test "with a PR as well, is refused: it is one or the other", ctx do
      assert {:error, cs} =
               submit(ctx.card, %{"evidence_no_code" => @why, "evidence_pr" => @pr}, ctx)

      assert %{evidence_no_code: [message]} = errors_on(cs)
      assert message =~ "not both"
    end

    test "the reason alone counts as evidence", ctx do
      assert {:ok, %{verify_state: "pending"}} =
               Boards.update_card(
                 fresh(ctx.card),
                 %{"completed" => true, "evidence_no_code" => @why},
                 actor: ctx.builder
               )
    end

    test "a reason over 1000 characters is refused", ctx do
      assert {:error, cs} =
               submit(ctx.card, %{"evidence_no_code" => String.duplicate("x", 1001)}, ctx)

      assert %{evidence_no_code: [_]} = errors_on(cs)
    end

    test "the evidence comment says no code, and why", ctx do
      {:ok, card} = submit(ctx.card, %{"evidence_no_code" => @why}, ctx)
      assert Enum.any?(comments(card), &(&1 =~ "**Evidence.**" and &1 =~ "No code: #{@why}"))
    end

    test "a person completing needs neither", ctx do
      assert {:ok, %{completed: true}} =
               Boards.update_card(fresh(ctx.card), %{"completed" => true})
    end
  end

  describe "accepting it" do
    test "completes it, in Done, with no merge job", ctx do
      {:ok, _} = submit(ctx.card, %{"evidence_no_code" => @why}, ctx)

      assert Verified.nothing_to_merge?(fresh(ctx.card))
      assert {:ok, card} = accept(ctx.card, ctx)
      assert card.completed
      assert card.verify_state == "accepted"
      assert card.column_id == ctx.done.id
      refute "review" in card.flags
      assert merge_jobs(card) == []

      assert Enum.any?(
               comments(card),
               &(&1 =~ "**Accepted**" and &1 =~ "changes no code: nothing to merge")
             )
    end

    test "a card with a PR still merges", ctx do
      {:ok, _} = submit(ctx.card, %{"evidence_pr" => @pr}, ctx)

      refute Verified.no_code?(fresh(ctx.card))
      refute Verified.nothing_to_merge?(fresh(ctx.card))
      assert {:ok, %{verify_state: "merging", completed: false}} = accept(ctx.card, ctx)
    end

    test "a rejection clears the reason, so the next completion gives its own", ctx do
      {:ok, _} = submit(ctx.card, %{"evidence_no_code" => @why}, ctx)

      {:ok, card} =
        Verified.decide(
          fresh(ctx.card),
          "reject",
          %{"reason" => "the ask: it asks for a fix in lib/"},
          ctx.checker,
          ctx.owner
        )

      assert card.verify_state == "rejected"
      assert card.evidence_no_code == nil
    end
  end

  describe "what the builder and the verifier are told" do
    test "the ship instructions say how to complete a card with no code", ctx do
      text = Verified.ship_instructions(fresh(ctx.card))
      assert text =~ "changes no code"
      assert text =~ "slipdock done #{ctx.card.id} --no-code"
      assert text =~ "never a token one"
    end

    test "a push board has no ship instructions to add it to", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"ship_via" => "push"})
      assert Verified.ship_instructions(fresh(ctx.card)) == nil
    end

    test "the verify prompt shows the reason and judges the claim, with no checkout", ctx do
      {:ok, card} = submit(ctx.card, %{"evidence_no_code" => @why}, ctx)

      prompt = Verified.verify_prompt(card, Repo.get!(Board, card.board_id))
      assert prompt =~ "changes no code: \"#{@why}\""
      assert prompt =~ "Judge the claim against the ask"
      assert prompt =~ "`no code:"
      refute prompt =~ "gh pr view"
      refute prompt =~ "git worktree add /tmp/verify-#{card.id}"
    end

    test "the verify prompt for a card with a PR is unchanged", ctx do
      {:ok, card} = submit(ctx.card, %{"evidence_pr" => @pr}, ctx)

      prompt = Verified.verify_prompt(card, Repo.get!(Board, card.board_id))
      assert prompt =~ "gh pr view #{@pr}"
      refute prompt =~ "changes no code: \""
    end
  end
end
