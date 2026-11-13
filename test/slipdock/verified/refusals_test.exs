defmodule Slipdock.Verified.RefusalsTest do
  @moduledoc """
  What a move and a decision are refused with, word for word, and who is
  let through (#2842): the branches of `Slipdock.Verified.check_move/3` and
  `decide/5` that the other verified tests reach only by their status.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Refusals", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    card = card_fixture(todo, %{"title" => "Work"})

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    %{
      owner: owner,
      board: board,
      doing: doing,
      done: done,
      card: card,
      builder: agent.("builder"),
      checker: agent.("checker")
    }
  end

  defp on(ctx, attrs) do
    {:ok, _board} = Boards.update_board(ctx.board, attrs)
    Repo.get!(Card, ctx.card.id)
  end

  defp submit(ctx, attrs \\ %{}) do
    card = on(ctx, %{"verify_work" => true})

    {:ok, card} =
      Boards.Cards.update_card(card, Map.merge(%{"completed" => true}, attrs),
        actor: ctx.builder,
        by: ctx.owner
      )

    assert card.verify_state == "pending"
    card
  end

  describe "check_move/3" do
    test "an agent starting a card with no bar is told to write one; a person isn't", ctx do
      card = on(ctx, %{"bar_required" => true})

      assert Verified.check_move(card, ctx.doing, ctx.builder) ==
               {:error,
                "this board asks for each card's bar before work starts: write what done " <>
                  "means for card ##{card.id} (its `bar`), then move it"}

      assert Verified.check_move(card, ctx.doing, Actor.web(ctx.owner)) == :ok
    end

    test "on a board that verifies work an agent submits rather than moves to done", ctx do
      card = on(ctx, %{"verify_work" => true})

      assert Verified.check_move(card, ctx.done, ctx.builder) ==
               {:error,
                "this board verifies work: submit card ##{card.id} by completing it " <>
                  "(complete_card, `slipdock done`), and a different agent or a person " <>
                  "accepts it into the done list"}
    end

    test "a person moves an open card into the done list on a board that verifies work", ctx do
      card = on(ctx, %{"verify_work" => true})

      assert Verified.check_move(card, ctx.done, Actor.web(ctx.owner)) == :ok
      assert Verified.check_move(card, ctx.done, Actor.automation()) == :ok
    end

    test "with no switch on, an agent's move anywhere is let through", ctx do
      assert Verified.check_move(ctx.card, ctx.doing, ctx.builder) == :ok
      assert Verified.check_move(ctx.card, ctx.done, ctx.builder) == :ok
    end
  end

  describe "decide/5" do
    test "merged is only for a card being merged: a pending one is a conflict", ctx do
      card = submit(ctx)

      assert Verified.decide(card, "merged", %{}, Actor.web(ctx.owner), ctx.owner) ==
               {:error, :conflict, "card ##{card.id} isn't waiting for its merge"}
    end

    test "a decision that is none of the known ones is named as such", ctx do
      card = submit(ctx)

      assert Verified.decide(card, "maybe", %{}, ctx.checker, ctx.owner) ==
               {:error, :unprocessable_entity,
                "decision must be accept, reject or merged (agree or disagree for an audit)"}
    end

    test "a card that was never submitted isn't waiting for verification", ctx do
      assert Verified.decide(ctx.card, "accept", %{}, ctx.checker, ctx.owner) ==
               {:error, :conflict, "card ##{ctx.card.id} isn't waiting for verification"}
    end

    test "the submitter is told a different agent, or a person, verifies it", ctx do
      card = submit(ctx)

      assert Verified.decide(card, "accept", %{}, ctx.builder, ctx.owner) ==
               {:error, :forbidden,
                "you submitted card ##{card.id}: a different agent, or a person, verifies it"}
    end

    test "a rejection with a blank reason is refused for the reason, before its parts", ctx do
      card = submit(ctx)

      for params <- [%{}, %{"reason" => "  "}, %{"reason" => "", "checks" => ["bar:1=fail"]}] do
        assert Verified.decide(card, "reject", params, ctx.checker, ctx.owner) ==
                 {:error, :unprocessable_entity, "a rejection needs its reason"}
      end
    end

    test "an acceptance needs no reason", ctx do
      card = submit(ctx)

      assert {:ok, %Card{verify_state: "accepted", completed: true}} =
               Verified.decide(card, "accept", %{"reason" => ""}, ctx.checker, ctx.owner)
    end

    test "a commit other than the evidence's is refused, naming the evidence's", ctx do
      card = submit(ctx, %{"evidence" => "Ran it", "evidence_commit" => "abc1234def"})

      assert Verified.decide(card, "accept", %{"commit" => "fff0000"}, ctx.checker, ctx.owner) ==
               {:error, :unprocessable_entity,
                "the evidence is for commit abc1234def: verify the work at that commit"}
    end

    test "a commit named for a card whose evidence gave none is kept, not compared", ctx do
      card = submit(ctx, %{"evidence" => "Ran it"})
      assert card.evidence_commit == nil

      assert {:ok, card} =
               Verified.decide(card, "accept", %{"commit" => "fff0000"}, ctx.checker, ctx.owner)

      assert card.verify_state == "accepted"
      assert card.verify_commit == "fff0000"
    end

    test "with no commit named, the evidence's stands and the card is accepted", ctx do
      card = submit(ctx, %{"evidence" => "Ran it", "evidence_commit" => "abc1234def"})

      assert {:ok, card} = Verified.decide(card, "accept", %{}, ctx.checker, ctx.owner)
      assert card.verify_state == "accepted"
      assert card.verify_commit == nil
    end

    test "the reason and the commit each land in their own field", ctx do
      card = submit(ctx, %{"evidence" => "Ran it", "evidence_commit" => "abc1234def"})

      assert {:ok, card} =
               Verified.decide(
                 card,
                 "accept",
                 %{"reason" => "read the diff", "commit" => "abc1234"},
                 ctx.checker,
                 ctx.owner
               )

      assert card.verify_note == "read the diff"
      assert card.verify_commit == "abc1234"
    end
  end
end
