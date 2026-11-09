defmodule Slipdock.VerifiedBarTest do
  @moduledoc """
  Verified work 1 (#1631): a board that asks for a bar refuses an agent
  starting work on a card without one, locks the bar when work starts, and
  refuses an agent changing it after. People, the assistant and boards with
  the switch off are untouched.
  """
  # Sync: the export/import test derives board codes, as the other import tests.
  use Slipdock.DataCase, async: false

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Portable, Verified}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Bars", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Work"})
    agent = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "bot"}
    %{owner: owner, board: board, todo: todo, doing: doing, card: card, agent: agent}
  end

  defp on(ctx) do
    {:ok, board} = Boards.update_board(ctx.board, %{"bar_required" => true})
    board
  end

  defp column_of(card), do: Repo.get!(Card, card.id).column_id

  describe "with the switch off (the default)" do
    test "an agent starts a card with no bar, and a bar written never locks", ctx do
      refute ctx.board.bar_required
      assert Verified.switches(ctx.board) == []
      assert :ok = Boards.move_card(ctx.card.id, ctx.doing.id, nil, actor: ctx.agent)
      assert column_of(ctx.card) == ctx.doing.id

      {:ok, card} = Boards.update_card(Repo.get!(Card, ctx.card.id), %{"bar" => "Tests pass"})
      {:ok, _} = Boards.update_card(card, %{"title" => "Work, again"})
      assert Repo.get!(Card, card.id).bar_locked_at == nil
    end
  end

  describe "with the switch on" do
    setup ctx, do: %{board: on(ctx)}

    test "names itself among the board's switches", ctx do
      assert Verified.switches(ctx.board) == [:bar]
    end

    test "an agent can't start a card with no bar, and the card stays put", ctx do
      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(ctx.card.id, ctx.doing.id, nil, actor: ctx.agent)

      assert message =~ "bar"
      assert column_of(ctx.card) == ctx.todo.id
    end

    test "a blank bar is no bar", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"bar" => "   "})
      assert Repo.get!(Card, ctx.card.id).bar == nil

      assert {:error, :unprocessable_entity, _} =
               Boards.move_card(ctx.card.id, ctx.doing.id, nil, actor: ctx.agent)
    end

    test "a person, the assistant and an automation may start one with no bar", ctx do
      assert :ok = Boards.move_card(ctx.card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      assert Repo.get!(Card, ctx.card.id).bar_locked_at == nil

      other = card_fixture(ctx.todo, %{"title" => "Assisted"})

      assert :ok =
               Boards.move_card(other.id, ctx.doing.id, nil, actor: Actor.assistant(ctx.owner))

      third = card_fixture(ctx.todo, %{"title" => "Ruled"})
      assert :ok = Boards.move_card(third.id, ctx.doing.id, nil, actor: Actor.automation())
    end

    test "moving within a list, or to a list that isn't in progress, isn't checked", ctx do
      assert :ok = Boards.move_card(ctx.card.id, ctx.todo.id, nil, actor: ctx.agent)
      [backlog | _] = ctx.board.columns
      assert :ok = Boards.move_card(ctx.card.id, backlog.id, nil, actor: ctx.agent)
    end

    test "the bar locks when work starts, and an agent can't change it after", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"bar" => "  Tests pass  "}, actor: ctx.agent)
      assert card.bar == "Tests pass"
      assert card.bar_locked_at == nil

      assert :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      card = Repo.get!(Card, card.id)
      assert %DateTime{} = card.bar_locked_at

      assert {:error, cs} = Boards.update_card(card, %{"bar" => "Less"}, actor: ctx.agent)
      assert %{bar: [message]} = errors_on(cs)
      assert message =~ "locked"
      assert Repo.get!(Card, card.id).bar == "Tests pass"

      # The same text again, and the card's other fields, are fine.
      assert {:ok, _} = Boards.update_card(card, %{"bar" => "Tests pass "}, actor: ctx.agent)
      assert {:ok, _} = Boards.update_card(card, %{"percent_complete" => 50}, actor: ctx.agent)

      # A person still can.
      assert {:ok, %{bar: "Less"}} =
               Boards.update_card(card, %{"bar" => "Less"}, actor: Actor.web(ctx.owner))
    end

    test "it locks once: leaving and coming back keeps the first moment", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"bar" => "Done"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      first = Repo.get!(Card, card.id).bar_locked_at
      :ok = Boards.move_card(card.id, ctx.todo.id, nil, actor: ctx.agent)
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      assert Repo.get!(Card, card.id).bar_locked_at == first
    end

    test "a person starting a card with a bar locks it too", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"bar" => "Done"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      assert Repo.get!(Card, card.id).bar_locked_at
    end

    test "a person changing a locked bar is a line in the activity log (#1622)", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"bar" => "Done"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      card = Repo.get!(Card, card.id)

      {:ok, _} =
        Boards.update_card(card, %{"bar" => "Done, and documented"}, actor: Actor.web(ctx.owner))

      messages =
        Repo.all(
          from(a in Slipdock.Boards.Activity, where: a.card_id == ^card.id, select: a.message)
        )

      assert "set the bar of “Work”" in messages
      assert "changed the locked bar of “Work”" in messages
    end

    test "a claimed job's prompt carries the card's bar; a verify job's is left alone", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"bar" => "Tests pass"})
      {:ok, job} = Slipdock.Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "Do it."})

      # #1883: then the check at pickup, before building.
      assert Slipdock.Runners.claimed_prompt(job) ==
               "Do it.\n\nThe card's bar (what done means for it); work to it as written:\nTests pass" <>
                 "\n\n" <>
                 Slipdock.Verified.bar_pickup_check() <>
                 "\n\n" <> Slipdock.Runners.ClaimMove.prompt_line(card.id)

      check = Slipdock.Verified.bar_pickup_check()
      assert check =~ "Before building, check each part of the bar against the guide"
      assert check =~ "needs a person (a handbook rule added, reworded or dropped, a merge"
      assert check =~ "stop and ask. Open a wait"

      assert check =~
               "Don't build to your own reading of it and leave the conflict to the verifier."

      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      assert Slipdock.Runners.claimed_prompt(job) =~ "locked when work started"

      {:ok, verify} =
        Slipdock.Runners.queue(card, %{pool: "dev", kind: "verify", prompt: "Check."})

      assert Slipdock.Runners.claimed_prompt(verify) == "Check."

      other = card_fixture(ctx.todo, %{"title" => "No bar"})
      {:ok, plain} = Slipdock.Runners.queue(other, %{pool: "dev", kind: "claude", prompt: "Go."})
      # No bar, nothing to check at pickup.
      assert Slipdock.Runners.claimed_prompt(plain) ==
               "Go.\n\n" <> Slipdock.Runners.ClaimMove.prompt_line(other.id)

      refute Slipdock.Runners.claimed_prompt(plain) =~ "check each part of the bar"
    end

    test "turned off again, a locked bar is an agent's to change", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"bar" => "Done"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      {:ok, _} = Boards.update_board(ctx.board, %{"bar_required" => false})

      assert {:ok, %{bar: "Other"}} =
               Boards.update_card(Repo.get!(Card, card.id), %{"bar" => "Other"}, actor: ctx.agent)
    end

    test "too long a bar is refused", ctx do
      assert {:error, cs} =
               Boards.update_card(ctx.card, %{
                 "bar" => String.duplicate("a", Card.bar_length() + 1)
               })

      assert %{bar: [_]} = errors_on(cs)
    end

    test "a card's subcards take the switch", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.card, t)
      assert sub.bar_required
    end

    test "an export carries the switch and the bar, and an import keeps them", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"bar" => "Tests pass"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)

      doc = Portable.export(ctx.owner, boards: [Boards.get_board!(ctx.board.id)])
      [tree] = doc.boards
      assert tree.root.bar_required

      {:ok, report} = Portable.import(ctx.owner, Jason.encode!(doc))
      imported = Boards.get_board!(hd(report.boards).id)
      assert imported.bar_required

      copy = Repo.get_by!(Card, board_id: imported.id, title: "Work")
      assert copy.bar == "Tests pass"

      assert copy.bar_locked_at ==
               DateTime.truncate(Repo.get!(Card, card.id).bar_locked_at, :second)
    end
  end
end
