defmodule Slipdock.VerifiedVerifyTest do
  @moduledoc """
  Verified work 3 (#1633): on a board that verifies work, an agent's
  completion is a submission — pending, open, flagged for review — and a
  different actor accepts it (done, in the done list) or rejects it with a
  reason (kept, commented, pointed at by the handoff, evidence cleared). The
  submitter can't decide its own card; a person completing one accepts it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Portable, Verified}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Verify", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})

    agent = fn label, job ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label, job_id: job}
    end

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      done: done,
      card: card,
      builder: agent.("builder", nil),
      checker: agent.("checker", nil)
    }
  end

  defp on(ctx, attrs \\ %{}) do
    {:ok, board} = Boards.update_board(ctx.board, Map.merge(%{"verify_work" => true}, attrs))
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

  defp bodies(card), do: Boards.get_card!(card.id).comments |> Enum.map(& &1.body)

  test "off (the default): an agent's completion completes", ctx do
    card = submit(ctx)
    assert card.completed
    assert card.verify_state == nil
    refute "review" in card.flags
  end

  describe "on" do
    setup ctx, do: %{board: on(ctx)}

    test "names itself among the board's switches", ctx do
      assert Verified.switches(ctx.board) == [:verify]
    end

    test "an agent's completion is a submission: open, pending, flagged for review", ctx do
      card = submit(ctx)
      refute card.completed
      assert card.verify_state == "pending"
      assert "review" in card.flags
      assert card.verify_submitter["agent"] == "builder"
      assert card.verify_submitter["kind"] == "agent"
      assert %DateTime{} = card.verify_at
      assert card.column_id == ctx.doing.id
    end

    test "an agent can't move a card into the done list itself", ctx do
      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(ctx.card.id, ctx.done.id, nil, actor: ctx.builder)

      assert message =~ "verifies"
      refute Repo.get!(Card, ctx.card.id).completed
    end

    test "the submitter can't decide its own card", ctx do
      card = submit(ctx)

      assert {:error, :forbidden, message} =
               Verified.decide(card, "accept", %{}, ctx.builder, ctx.owner)

      assert message =~ "you submitted"
      assert Repo.get!(Card, card.id).verify_state == "pending"
    end

    test "a different agent accepts: done, in the done list, review flag off", ctx do
      card = submit(ctx)

      assert {:ok, card} =
               Verified.decide(
                 card,
                 "accept",
                 %{"reason" => "Tests pass"},
                 ctx.checker,
                 ctx.owner
               )

      assert card.completed
      assert card.verify_state == "accepted"
      assert card.verify_by["agent"] == "checker"
      assert card.verify_note == "Tests pass"
      assert card.column_id == ctx.done.id
      refute "review" in card.flags
      assert Enum.any?(bodies(card), &(&1 =~ "**Accepted** by agent “checker”"))
    end

    test "the same token in another runner job is a different agent", ctx do
      card = submit(ctx)
      other_job = %{ctx.builder | job_id: 99}

      assert {:ok, %{completed: true}} =
               Verified.decide(card, "accept", %{}, other_job, ctx.owner)

      refute Verified.same_actor?(card.verify_submitter, other_job)
      assert Verified.same_actor?(card.verify_submitter, ctx.builder)
    end

    test "a rejection needs its reason", ctx do
      card = submit(ctx)

      assert {:error, :unprocessable_entity, message} =
               Verified.decide(card, "reject", %{"reason" => "  "}, ctx.checker, ctx.owner)

      assert message =~ "reason"
    end

    test "a rejection keeps the reason, comments it, hands it off and clears the evidence",
         ctx do
      card = submit(ctx, %{"evidence" => "Ran it", "evidence_commit" => "abc1234"})

      assert {:ok, card} =
               Verified.decide(
                 card,
                 "reject",
                 %{"reason" => "bar 1: The empty list case fails\nSee the log"},
                 ctx.checker,
                 ctx.owner
               )

      refute card.completed
      assert card.verify_state == "rejected"
      assert card.verify_note == "bar 1: The empty list case fails\nSee the log"
      assert card.evidence == nil and card.evidence_commit == nil
      refute "review" in card.flags

      # Back at the top of the ready list, its rejection counted (#1624).
      assert card.column_id == ctx.todo.id
      assert card.verify_rejections == 1

      assert [%{id: first} | _] =
               Boards.get_board!(ctx.board.id).columns |> Enum.at(1) |> Map.get(:cards)

      assert first == card.id
      assert Enum.any?(bodies(card), &(&1 =~ "**Rejected** by agent “checker”"))

      handoff = Boards.current_handoff(card)

      assert handoff.next_step ==
               "Rework: rejected by agent “checker”, reason under Verification"

      # Fixed and completed again, it is pending again.
      card = Repo.get!(Card, card.id)
      {:ok, again} = Boards.update_card(card, %{"completed" => true}, actor: ctx.builder)
      assert again.verify_state == "pending"

      {:ok, again} =
        Verified.decide(again, "reject", %{"reason" => "bar 1: Still"}, ctx.checker, ctx.owner)

      assert again.verify_rejections == 2
    end

    test "an epic is not done while a subcard awaits verification (#1624)", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.card, t)
      [column | _] = Boards.get_board!(sub.id).columns
      first = card_fixture(column, %{"title" => "One"})
      second = card_fixture(column, %{"title" => "Two"})
      {:ok, _} = Boards.update_card(first, %{"completed" => true}, actor: Actor.web(ctx.owner))
      {:ok, _} = Boards.update_card(second, %{"completed" => true}, actor: ctx.builder)

      rollup = Boards.get_card!(ctx.card.id).rollup
      assert rollup.done == 1 and rollup.total == 2
      assert rollup.awaiting == 1
      refute rollup.health == :done
    end

    test "a pending card is waiting on whoever owns the board, in their work (#1624)", ctx do
      card = submit(ctx)
      items = Slipdock.Work.waiting_on_me(ctx.owner)
      assert [%{reason: "verify", text: text}] = Enum.filter(items, &(&1.card.id == card.id))
      assert text =~ "Awaiting verification"

      {:ok, _} = Verified.decide(card, "accept", %{}, ctx.checker, ctx.owner)
      refute Enum.any?(Slipdock.Work.waiting_on_me(ctx.owner), &(&1.card.id == card.id))
    end

    test "only a pending card can be decided, and only accept or reject", ctx do
      assert {:error, :conflict, _} = Verified.decide(ctx.card, "accept", %{}, ctx.checker, nil)
      card = submit(ctx)

      assert {:error, :unprocessable_entity, _} =
               Verified.decide(card, "maybe", %{}, ctx.checker, nil)
    end

    test "a commit given must be the evidence's; a prefix of it will do", ctx do
      card = submit(ctx, %{"evidence" => "Ran it", "evidence_commit" => "abc1234def"})

      assert {:error, :unprocessable_entity, message} =
               Verified.decide(card, "accept", %{"commit" => "fff0000"}, ctx.checker, ctx.owner)

      assert message =~ "abc1234def"

      assert {:ok, card} =
               Verified.decide(card, "accept", %{"commit" => "ABC1234"}, ctx.checker, ctx.owner)

      assert card.verify_commit == "ABC1234"
    end

    test "a person completing a pending card accepts it", ctx do
      card = submit(ctx)

      {:ok, card} =
        Boards.update_card(card, %{"completed" => true},
          actor: Actor.web(ctx.owner),
          by: ctx.owner
        )

      assert card.completed
      assert card.verify_state == "accepted"
      assert card.verify_by["kind"] == "human"
      refute "review" in card.flags
    end

    test "a person deciding in the web app is never the submitter", ctx do
      card = submit(ctx)

      assert {:ok, %{completed: true}} =
               Verified.decide(card, "accept", %{}, Actor.web(ctx.owner), ctx.owner)
    end

    test "with evidence asked for too, it is commented once: at submission", ctx do
      on(ctx, %{"evidence_required" => true})
      card = submit(ctx, %{"evidence" => "Ran it"})
      assert [_] = Enum.filter(bodies(card), &(&1 =~ "**Evidence.**"))

      {:ok, card} = Verified.decide(card, "accept", %{}, ctx.checker, ctx.owner)
      assert [_] = Enum.filter(bodies(card), &(&1 =~ "**Evidence.**"))
    end

    test "a card's subcards take the switch, and an export carries it", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.card, t)
      assert sub.verify_work

      doc = Portable.export(ctx.owner, boards: [Boards.get_board!(ctx.board.id)])
      assert hd(doc.boards).root.verify_work
    end
  end

  describe "who/1" do
    test "an agent by its token's label, or as an agent without one", ctx do
      assert Verified.who(ctx.builder) == "agent “builder”"
      assert Verified.who(%{ctx.builder | agent: nil}) == "an agent"
      assert Verified.who(%{"kind" => "agent", "agent" => "stored"}) == "agent “stored”"
    end

    test "a person by their name, else their email, as stored on a card", ctx do
      person = Actor.web(ctx.owner)
      assert Verified.who(person) == ctx.owner.email

      ctx.owner |> Ecto.Changeset.change(name: "Ann Owner") |> Slipdock.Repo.update!()
      assert Verified.who(person) == "Ann Owner"

      on(ctx)
      card = submit(ctx, %{})
      {:ok, card} = Verified.decide(card, "accept", %{}, person, ctx.owner)
      assert Verified.who(card.verify_by) == "Ann Owner"
    end

    test "a deleted account, and nobody at all", ctx do
      gone = %{Actor.web(ctx.owner) | user_id: -1}
      assert Verified.who(gone) == "a deleted account"
      assert Verified.who(nil) == "somebody"
      assert Verified.who(%{"kind" => "human"}) == "somebody"
    end
  end

  describe "person/1" do
    test "the user behind a person, nothing for an agent, a deleted account or nobody", ctx do
      assert Verified.person(Actor.web(ctx.owner)).id == ctx.owner.id
      assert Verified.person(%{"kind" => "human", "user_id" => ctx.owner.id}).id == ctx.owner.id
      assert Verified.person(ctx.builder) == nil

      assert Verified.person(%{"kind" => "agent", "agent" => "x", "user_id" => ctx.owner.id}) ==
               nil

      assert Verified.person(%{Actor.web(ctx.owner) | user_id: -1}) == nil
      assert Verified.person(nil) == nil
      assert Verified.person(%{"kind" => "human"}) == nil
    end
  end
end
