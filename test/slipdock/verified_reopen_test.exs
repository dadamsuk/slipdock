defmodule Slipdock.VerifiedReopenTest do
  @moduledoc """
  Done stays done (#1850): on every board, with no switch, an agent can't
  reopen a completed card, by unticking it or by moving it out of a done
  list, and the refusal says a person reopens finished work. People, the
  in-app assistant and automations still can, and an agent still moves cards
  that aren't done and edits done ones otherwise. A move to another board
  (`Boards.move_card_to_board/3`) is held to the same (#1851).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Verified}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Reopen", "code" => unique_code()}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})
    :ok = Boards.move_card(card.id, done.id, nil, actor: Actor.web(owner))
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: "bot"}

    %{
      owner: owner,
      board: board,
      backlog: backlog,
      todo: todo,
      doing: doing,
      done: done,
      card: Repo.get!(Card, card.id),
      agent: agent
    }
  end

  defp fresh(card), do: Repo.get!(Card, card.id)

  defp assert_done(ctx) do
    card = fresh(ctx.card)
    assert card.completed
    assert card.column_id == ctx.done.id
  end

  test "the card starts done, in the done list", ctx do
    assert_done(ctx)
  end

  test "an agent moving a done card out of the done list is refused, and it stays done", ctx do
    for column <- [ctx.todo, ctx.doing, ctx.backlog] do
      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(ctx.card.id, column.id, nil, actor: ctx.agent)

      assert message =~ "card ##{ctx.card.id} is done, and an agent can't reopen it"
      assert message =~ "a person reopens finished work"
      assert_done(ctx)
    end

    # The way the CLI and the API move a card, to the top of a list.
    assert {:error, :unprocessable_entity, _} =
             Boards.move_card_to_index(ctx.card, ctx.todo, :top, actor: ctx.agent)

    assert_done(ctx)
  end

  test "so is a runner's agent, or one on the CLI", ctx do
    for actor <- [%{ctx.agent | via: "runner", job_id: 1}, %{ctx.agent | via: "cli"}] do
      assert {:error, :unprocessable_entity, _} =
               Boards.move_card(ctx.card.id, ctx.todo.id, nil, actor: actor)
    end

    assert_done(ctx)
  end

  test "an agent unticking a done card is refused on completed", ctx do
    for value <- [false, "false"] do
      assert {:error, cs} =
               Boards.update_card(ctx.card, %{"completed" => value}, actor: ctx.agent)

      assert %{completed: ["is refused: card #" <> _ = message]} = errors_on(cs)
      assert message =~ "an agent can't reopen it"
      assert_done(ctx)
    end
  end

  test "people, the in-app assistant and automations reopen as before", ctx do
    for actor <- [Actor.web(ctx.owner), %{ctx.agent | via: "assistant"}, Actor.automation()] do
      assert :ok = Boards.move_card(ctx.card.id, ctx.todo.id, nil, actor: actor)
      refute fresh(ctx.card).completed
      :ok = Boards.move_card(ctx.card.id, ctx.done.id, nil, actor: Actor.web(ctx.owner))

      assert {:ok, %{completed: false}} =
               Boards.update_card(fresh(ctx.card), %{"completed" => false}, actor: actor)

      {:ok, _} = Boards.update_card(fresh(ctx.card), %{"completed" => true})
    end

    # With no actor at all (a server path that says nobody), nothing is checked.
    assert :ok = Boards.move_card(ctx.card.id, ctx.todo.id, nil)
    refute fresh(ctx.card).completed
  end

  test "an agent still edits a done card, and moves it from one done list to another", ctx do
    assert {:ok, %{title: "Work, renamed", completed: true}} =
             Boards.update_card(ctx.card, %{"title" => "Work, renamed"}, actor: ctx.agent)

    # Saying it is done again isn't reopening it.
    assert {:ok, %{completed: true}} =
             Boards.update_card(fresh(ctx.card), %{"completed" => true}, actor: ctx.agent)

    {:ok, shipped} = Boards.create_column(ctx.board, %{"name" => "Shipped", "category" => "done"})
    assert :ok = Boards.move_card(ctx.card.id, shipped.id, nil, actor: ctx.agent)
    card = fresh(ctx.card)
    assert card.completed and card.column_id == shipped.id
  end

  test "an agent still moves and completes cards that aren't done", ctx do
    open = card_fixture(ctx.todo, %{"title" => "Open"})
    assert :ok = Boards.move_card(open.id, ctx.doing.id, nil, actor: ctx.agent)
    assert :ok = Boards.move_card(open.id, ctx.todo.id, nil, actor: ctx.agent)

    assert {:ok, %{completed: true}} =
             Boards.update_card(fresh(open), %{"completed" => true}, actor: ctx.agent)

    # A card ticked off in a list that isn't a done list isn't taken out of
    # one: moving it on reopens nothing, so it isn't refused.
    ticked = card_fixture(ctx.todo, %{"title" => "Ticked", "completed" => true})
    assert :ok = Boards.move_card(ticked.id, ctx.doing.id, nil, actor: ctx.agent)
    assert fresh(ticked).completed
  end

  test "on a board that verifies work and ships by pull request too", ctx do
    {:ok, _} =
      Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

    assert {:error, :unprocessable_entity, message} =
             Boards.move_card(ctx.card.id, ctx.todo.id, nil, actor: ctx.agent)

    assert message =~ "an agent can't reopen it"
    assert_done(ctx)
  end

  describe "a move to another board (#1851)" do
    setup ctx do
      other = board_fixture(%{"name" => "Elsewhere", "code" => unique_code()}, owner: ctx.owner)
      [o_backlog, o_todo, o_doing, o_done] = other.columns
      %{other: other, o_backlog: o_backlog, o_todo: o_todo, o_doing: o_doing, o_done: o_done}
    end

    test "an agent moving a done card to a list there that isn't done is refused, and it stays",
         ctx do
      for column <- [ctx.o_backlog, ctx.o_todo, ctx.o_doing],
          actor <- [ctx.agent, %{ctx.agent | via: "runner", job_id: 1}, %{ctx.agent | via: "cli"}] do
        assert {:error, message} = Boards.move_card_to_board(ctx.card, column, actor: actor)
        assert message == Verified.reopen_message(ctx.card, ctx.agent)
        assert_done(ctx)
      end
    end

    test "people, the in-app assistant and automations still move it", ctx do
      for actor <- [Actor.web(ctx.owner), %{ctx.agent | via: "assistant"}, Actor.automation()] do
        card = card_fixture(ctx.done, %{"title" => "Done too", "completed" => true})
        assert {:ok, _} = Boards.move_card_to_board(card, ctx.o_todo, actor: actor)
        moved = fresh(card)
        assert moved.board_id == ctx.other.id and moved.column_id == ctx.o_todo.id
        refute moved.completed
      end

      # With no actor at all, nothing is checked.
      assert {:ok, _} = Boards.move_card_to_board(ctx.card, ctx.o_todo)
      assert fresh(ctx.card).column_id == ctx.o_todo.id
    end

    test "an agent still moves a done card to the other board's done list", ctx do
      assert {:ok, _} = Boards.move_card_to_board(ctx.card, ctx.o_done, actor: ctx.agent)
      card = fresh(ctx.card)
      assert card.completed and card.column_id == ctx.o_done.id
    end

    test "an agent still moves cards that aren't done, or ticked ones not in a done list", ctx do
      open = card_fixture(ctx.todo, %{"title" => "Open"})
      assert {:ok, _} = Boards.move_card_to_board(open, ctx.o_doing, actor: ctx.agent)
      assert fresh(open).column_id == ctx.o_doing.id

      ticked = card_fixture(ctx.todo, %{"title" => "Ticked", "completed" => true})
      assert {:ok, _} = Boards.move_card_to_board(ticked, ctx.o_todo, actor: ctx.agent)
      assert fresh(ticked).column_id == ctx.o_todo.id
    end

    test "judged by where it lands: a kept stand-in's list", ctx do
      stand_in = fn column ->
        Repo.insert!(%Card{
          title: "Work",
          board_id: ctx.other.id,
          column_id: column.id,
          position: 0,
          stand_in_for_id: ctx.card.id
        })
      end

      # A stand-in in To Do: aiming at the done list still lands in To Do.
      in_todo = stand_in.(ctx.o_todo)
      assert {:error, _} = Boards.move_card_to_board(ctx.card, ctx.o_done, actor: ctx.agent)
      assert_done(ctx)

      # A stand-in in the done list: aiming at To Do lands in Done, so it stays done.
      Repo.delete!(in_todo)
      stand_in.(ctx.o_done)
      assert {:ok, _} = Boards.move_card_to_board(ctx.card, ctx.o_todo, actor: ctx.agent)
      card = fresh(ctx.card)
      assert card.completed and card.column_id == ctx.o_done.id
    end
  end

  describe "Verified.reopen_message/2" do
    test "is nil for a card that isn't done, or a person; the message for an agent", ctx do
      open = card_fixture(ctx.todo, %{"title" => "Open"})
      assert Verified.reopen_message(open, ctx.agent) == nil
      assert Verified.reopen_message(ctx.card, Actor.web(ctx.owner)) == nil
      assert Verified.reopen_message(ctx.card, nil) == nil
      assert Verified.reopen_message(ctx.card, ctx.agent) =~ "add a card for that and link it"
    end
  end
end
