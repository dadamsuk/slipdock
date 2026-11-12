defmodule Slipdock.VerifiedCreateTest do
  @moduledoc """
  A card created straight into a doing list (#1815) meets the checks a move
  into it makes: on a board that asks for a bar, an agent can't create one
  there without a bar, and one created with a bar has it locked; on a board
  with lanes on, an agent can't create one there whose paths overlap a card
  in progress. People, the assistant, automations, other lists and boards
  with the switches off are untouched.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Created in progress"}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    agent = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "bot"}

    %{owner: owner, board: board, todo: todo, doing: doing, done: done, agent: agent}
  end

  defp switch(ctx, attrs) do
    {:ok, board} = Boards.update_board(ctx.board, attrs)
    board
  end

  defp count(column),
    do: Repo.aggregate(from(c in Card, where: c.column_id == ^column.id), :count)

  describe "the bar, with bar_required on" do
    setup ctx, do: %{board: switch(ctx, %{"bar_required" => true})}

    test "an agent can't create a card in progress with no bar, and none is made", ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(ctx.doing, %{"title" => "Sneaked in"}, actor: ctx.agent)

      assert {message, _} = changeset.errors[:bar]
      assert message =~ "bar"
      assert message =~ ctx.doing.name
      assert count(ctx.doing) == 0
    end

    test "a blank bar is no bar", ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(ctx.doing, %{"title" => "Blank", "bar" => "  "},
                 actor: ctx.agent
               )

      assert changeset.errors[:bar]
      assert count(ctx.doing) == 0
    end

    test "an agent's card made in progress with a bar has it locked", ctx do
      assert {:ok, card} =
               Boards.Cards.create_card(ctx.doing, %{"title" => "Barred", "bar" => "Tests pass"},
                 actor: ctx.agent
               )

      assert %DateTime{} = card.bar_locked_at
      assert Repo.get!(Card, card.id).bar_locked_at

      assert {:error, changeset} =
               Boards.Cards.update_card(Repo.get!(Card, card.id), %{"bar" => "Less"},
                 actor: ctx.agent
               )

      assert changeset.errors[:bar]
    end

    test "a person's card made in progress with a bar locks too, as a move would", ctx do
      assert {:ok, card} =
               Boards.Cards.create_card(ctx.doing, %{"title" => "Theirs", "bar" => "Done well"},
                 actor: Actor.web(ctx.owner)
               )

      assert card.bar_locked_at
    end

    test "a person, the assistant, an automation and an unknown door need no bar", ctx do
      for {actor, title} <- [
            {Actor.web(ctx.owner), "Person"},
            {Actor.assistant(ctx.owner), "Assistant"},
            {Actor.automation(), "Rule"}
          ] do
        assert {:ok, card} =
                 Boards.Cards.create_card(ctx.doing, %{"title" => title}, actor: actor)

        assert card.bar_locked_at == nil
      end

      assert {:ok, _} = Boards.Cards.create_card(ctx.doing, %{"title" => "No actor"})
    end

    test "an agent creates a card with no bar in a list that isn't in progress", ctx do
      assert {:ok, card} =
               Boards.Cards.create_card(ctx.todo, %{"title" => "Later"}, actor: ctx.agent)

      assert card.bar_locked_at == nil

      assert {:ok, barred} =
               Boards.Cards.create_card(ctx.todo, %{"title" => "Planned", "bar" => "It works"},
                 actor: ctx.agent
               )

      assert barred.bar_locked_at == nil
    end

    test "an invalid card is refused for what's wrong with it, not for its bar", ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(ctx.doing, %{"title" => ""}, actor: ctx.agent)

      assert changeset.errors[:title]
      refute changeset.errors[:bar]
    end
  end

  test "with bar_required off, an agent creates a card in progress with no bar, unlocked",
       ctx do
    assert {:ok, card} =
             Boards.Cards.create_card(ctx.doing, %{"title" => "Free"}, actor: ctx.agent)

    assert card.bar_locked_at == nil

    assert {:ok, barred} =
             Boards.Cards.create_card(ctx.doing, %{"title" => "Barred", "bar" => "x"},
               actor: ctx.agent
             )

    assert barred.bar_locked_at == nil
  end

  describe "lanes, with lanes on" do
    setup ctx do
      board = switch(ctx, %{"lanes" => true})
      held = card_fixture(ctx.doing, %{"title" => "Holding"})
      {:ok, held} = Boards.Cards.update_card(held, %{"paths" => ["lib/foo/**"]})
      working_job_fixture(held)
      %{board: board, held: held}
    end

    test "an agent can't create a card in progress whose paths overlap, and none is made",
         ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(
                 ctx.doing,
                 %{"title" => "Overlaps", "paths" => "lib/foo/bar.ex"},
                 actor: ctx.agent
               )

      assert {message, _} = changeset.errors[:paths]
      assert message =~ "##{ctx.held.id}"
      assert message =~ "Holding"
      assert count(ctx.doing) == 1
    end

    test "an agent creates one in progress with paths apart, or none", ctx do
      assert {:ok, _} =
               Boards.Cards.create_card(ctx.doing, %{"title" => "Apart", "paths" => "lib/bar/**"},
                 actor: ctx.agent
               )

      assert {:ok, _} =
               Boards.Cards.create_card(ctx.doing, %{"title" => "Pathless"}, actor: ctx.agent)
    end

    test "an overlapping card is made in another list, or by a person", ctx do
      assert {:ok, _} =
               Boards.Cards.create_card(
                 ctx.todo,
                 %{"title" => "Queued", "paths" => "lib/foo/a.ex"},
                 actor: ctx.agent
               )

      assert {:ok, _} =
               Boards.Cards.create_card(
                 ctx.doing,
                 %{"title" => "Theirs", "paths" => "lib/foo/a.ex"},
                 actor: Actor.web(ctx.owner)
               )
    end

    test "an archived card holds no lane", ctx do
      {:ok, _} = Boards.Cards.archive_card(ctx.held)

      assert {:ok, _} =
               Boards.Cards.create_card(
                 ctx.doing,
                 %{"title" => "After", "paths" => "lib/foo/a.ex"},
                 actor: ctx.agent
               )
    end
  end

  test "with lanes off, an agent creates an overlapping card in progress", ctx do
    held = card_fixture(ctx.doing, %{"title" => "Holding"})
    {:ok, _} = Boards.Cards.update_card(held, %{"paths" => ["lib/foo/**"]})

    assert {:ok, _} =
             Boards.Cards.create_card(
               ctx.doing,
               %{"title" => "Overlaps", "paths" => "lib/foo/a.ex"},
               actor: ctx.agent
             )
  end

  test "with both on, a card with no bar is refused on its bar first", ctx do
    switch(ctx, %{"bar_required" => true, "lanes" => true})
    held = card_fixture(ctx.doing, %{"title" => "Holding", "bar" => "x"})
    {:ok, _} = Boards.Cards.update_card(held, %{"paths" => ["lib/**"]})

    assert {:error, changeset} =
             Boards.Cards.create_card(ctx.doing, %{"title" => "Both", "paths" => "lib/a.ex"},
               actor: ctx.agent
             )

    assert changeset.errors[:bar]
  end
end
