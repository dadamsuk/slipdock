defmodule Slipdock.VerifiedCreateDoneTest do
  @moduledoc """
  A card created already finished (#1918), straight into a done list or with
  `completed` set, meets what an agent completing it would: on a board that
  verifies work an agent can't create one (a submission needs a card to
  submit), and on one that asks for evidence it needs some. People, the
  assistant, automations, other lists and boards with the switches off are
  untouched.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Created done"}, owner: owner)
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

  defp others(ctx),
    do: [
      {Actor.web(ctx.owner), "Person"},
      {Actor.assistant(ctx.owner), "Assistant"},
      {Actor.automation(), "Rule"}
    ]

  describe "evidence, with evidence_required on" do
    setup ctx, do: %{board: switch(ctx, %{"evidence_required" => true})}

    test "an agent can't create a card in a done list with no evidence, and none is made",
         ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(ctx.done, %{"title" => "Sneaked in"}, actor: ctx.agent)

      assert {message, _} = changeset.errors[:evidence]
      assert message =~ "evidence_commit"
      assert message =~ ctx.done.name
      assert message =~ "complete_card"
      assert count(ctx.done) == 0
    end

    test "nor one created completed in another list", ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(ctx.todo, %{"title" => "Ticked", "completed" => true},
                 actor: ctx.agent
               )

      assert changeset.errors[:evidence]
      assert count(ctx.todo) == 0
    end

    test "blank evidence is no evidence", ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(ctx.done, %{"title" => "Blank", "evidence" => "  "},
                 actor: ctx.agent
               )

      assert changeset.errors[:evidence]
      assert count(ctx.done) == 0
    end

    test "an agent's card in a done list with evidence is made", ctx do
      for {attrs, title} <- [
            {%{"evidence" => "Ran the tests"}, "Said"},
            {%{"evidence_commit" => "abc1234"}, "Committed"},
            {%{"evidence_suite" => %{"result" => "passed", "passed" => 3, "failed" => 0}},
             "Suite"}
          ] do
        assert {:ok, card} =
                 Boards.Cards.create_card(ctx.done, Map.put(attrs, "title", title),
                   actor: ctx.agent
                 )

        assert card.column_id == ctx.done.id
      end
    end

    test "a person, the assistant, an automation and an unknown door need no evidence", ctx do
      for {actor, title} <- others(ctx) do
        assert {:ok, card} = Boards.Cards.create_card(ctx.done, %{"title" => title}, actor: actor)
        assert card.column_id == ctx.done.id
      end

      assert {:ok, _} = Boards.Cards.create_card(ctx.done, %{"title" => "No actor"})
      assert count(ctx.done) == 4
    end

    test "an agent creates a card with no evidence in a list that isn't done", ctx do
      for column <- [ctx.todo, ctx.doing] do
        assert {:ok, card} =
                 Boards.Cards.create_card(column, %{"title" => "Open"}, actor: ctx.agent)

        assert card.column_id == column.id
        refute card.completed
      end
    end

    test "an invalid card is refused for what's wrong with it, not for its evidence", ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(ctx.done, %{"title" => ""}, actor: ctx.agent)

      assert changeset.errors[:title]
      refute changeset.errors[:evidence]
    end
  end

  describe "verification, with verify_work on" do
    setup ctx, do: %{board: switch(ctx, %{"verify_work" => true, "evidence_required" => true})}

    test "an agent can't create a card in a done list even with evidence", ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(
                 ctx.done,
                 %{"title" => "Self-accepted", "evidence" => "x"},
                 actor: ctx.agent
               )

      assert {message, _} = changeset.errors[:completed]
      assert message =~ "verifies work"
      assert message =~ ctx.done.name
      assert message =~ "slipdock done"
      refute changeset.errors[:evidence]
      assert count(ctx.done) == 0
    end

    test "nor one created completed in another list", ctx do
      assert {:error, changeset} =
               Boards.Cards.create_card(
                 ctx.doing,
                 %{"title" => "Ticked", "completed" => "true", "evidence" => "x"},
                 actor: ctx.agent
               )

      assert changeset.errors[:completed]
      assert count(ctx.doing) == 0
    end

    test "on a board that ships by pull request, a PR doesn't get one in", ctx do
      switch(%{ctx | board: Repo.reload!(ctx.board)}, %{"ship_via" => "pull_request"})

      assert {:error, changeset} =
               Boards.Cards.create_card(
                 ctx.done,
                 %{"title" => "With PR", "evidence_pr" => "https://example.com/pr/1"},
                 actor: ctx.agent
               )

      assert changeset.errors[:completed]
      assert count(ctx.done) == 0
    end

    test "a person, the assistant and an automation still create one there", ctx do
      for {actor, title} <- others(ctx) do
        assert {:ok, card} = Boards.Cards.create_card(ctx.done, %{"title" => title}, actor: actor)
        assert card.column_id == ctx.done.id
      end
    end

    test "an agent creates one in a list that isn't done, to submit later", ctx do
      assert {:ok, card} =
               Boards.Cards.create_card(ctx.todo, %{"title" => "Later"}, actor: ctx.agent)

      refute card.completed
    end
  end

  test "with verify_work alone, evidence isn't asked first", ctx do
    switch(ctx, %{"verify_work" => true})

    assert {:error, changeset} =
             Boards.Cards.create_card(ctx.done, %{"title" => "Bare"}, actor: ctx.agent)

    assert changeset.errors[:completed]
    refute changeset.errors[:evidence]
  end

  test "with the switches off, an agent creates a card in a done list freely", ctx do
    assert {:ok, card} =
             Boards.Cards.create_card(ctx.done, %{"title" => "Free"}, actor: ctx.agent)

    assert card.column_id == ctx.done.id

    assert {:ok, card} =
             Boards.Cards.create_card(ctx.todo, %{"title" => "Ticked", "completed" => true},
               actor: ctx.agent
             )

    assert card.completed
  end

  test "with bar_required on, a done list asks no bar", ctx do
    switch(ctx, %{"bar_required" => true})

    assert {:ok, card} =
             Boards.Cards.create_card(ctx.done, %{"title" => "Done"}, actor: ctx.agent)

    refute card.bar_locked_at
  end
end
