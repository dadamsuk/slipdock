defmodule Slipdock.OriginTest do
  @moduledoc """
  Origin on cards (#2778, W-2588 §2): every card made from now on records
  who or what made it, set by the server from who made it; a caller inside
  a runner job may name only a generator (`sweep`, `findings`), and nobody
  can claim `person`. Shown on the card, a filter, and a rule condition.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Filters, Origin, Overseer, Repo}
  alias Slipdock.Automations.Runner
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Made"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp made(column, opts, attrs \\ %{}) do
    Boards.Cards.create_card(column, Map.merge(%{"title" => "A card"}, attrs), opts)
  end

  defp origin_of({:ok, %Card{} = card}), do: {card.origin, card.origin_job_id}

  describe "resolve/4" do
    test "reads the actor: a person, an agent with or without its job, a rule" do
      assert Origin.resolve(Actor.unknown() |> Map.put(:kind, "human"), nil, nil, nil) ==
               {:ok, {"person", nil}}

      assert Origin.resolve(%{kind: "agent", job_id: 7}, nil, nil, nil) == {:ok, {"agent", 7}}
      assert Origin.resolve(%{kind: "agent", job_id: nil}, nil, nil, nil) == {:ok, {"agent", nil}}
      assert Origin.resolve(Actor.automation(), nil, nil, nil) == {:ok, {"automation", nil}}
      # Nobody said who, but a person's account is writing.
      assert Origin.resolve(Actor.unknown(), %{id: 1}, nil, "") == {:ok, {"person", nil}}
      assert Origin.resolve(Actor.unknown(), nil, nil, nil) == {:ok, {nil, nil}}
    end

    test "the server's own say wins, and keeps the job it was made in" do
      assert Origin.resolve(Actor.automation(), nil, "verify", "sweep") == {:ok, {"verify", nil}}

      assert Origin.resolve(%{kind: "agent", job_id: 3}, nil, "import", nil) ==
               {:ok, {"import", 3}}
    end

    test "a job may name a generator; nothing else may claim one, and nobody claims person" do
      job = %{kind: "agent", job_id: 9}
      assert Origin.resolve(job, nil, nil, "sweep") == {:ok, {"sweep", 9}}
      assert Origin.resolve(job, nil, nil, "findings") == {:ok, {"findings", 9}}

      for {actor, claim} <- [
            {job, "person"},
            {job, "overseer"},
            {job, "nonsense"},
            {%{kind: "agent", job_id: nil}, "sweep"},
            {Actor.web(nil), "sweep"}
          ] do
        assert {:error, message} = Origin.resolve(actor, nil, nil, claim)
        assert message =~ "only an agent inside a runner job"
      end
    end

    test "labels read with the job" do
      assert Origin.label("agent", 12) == "agent (job #12)"
      assert Origin.label("sweep", nil) == "sweep"
      assert Origin.label(nil, 4) == nil
    end
  end

  describe "made by" do
    test "a person in the web UI, or by mail", ctx do
      assert origin_of(made(ctx.todo, actor: Actor.web(ctx.owner))) == {"person", nil}
      assert origin_of(made(ctx.todo, actor: Actor.email(ctx.owner))) == {"person", nil}
      assert origin_of(made(ctx.todo, by: ctx.owner)) == {"person", nil}
    end

    test "an agent, in a job and out of one", ctx do
      assert origin_of(made(ctx.todo, actor: Actor.runner(ctx.owner, 41))) == {"agent", 41}
      assert origin_of(made(ctx.todo, via: "mcp", by: ctx.owner)) == {"agent", nil}
    end

    test "a generator a job names, and the refused claims", ctx do
      job = Actor.runner(ctx.owner, 5)
      assert origin_of(made(ctx.todo, [actor: job], %{"origin" => "sweep"})) == {"sweep", 5}
      assert origin_of(made(ctx.todo, [actor: job], %{origin: "findings"})) == {"findings", 5}

      assert {:error, changeset} = made(ctx.todo, [actor: job], %{"origin" => "person"})
      assert %{origin: [message]} = errors_on(changeset)
      assert message =~ "only an agent inside a runner job"

      assert {:error, _} = made(ctx.todo, [actor: Actor.web(ctx.owner)], %{"origin" => "sweep"})
      # Only the two the job could name were made.
      assert Repo.aggregate(Card, :count) == 2
    end

    test "a rule's create-a-card action", ctx do
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "card_created", "column" => "Backlog"},
        "actions" => [%{"type" => "create_card", "title" => "Follow up", "column" => "To Do"}]
      })

      card_fixture(ctx.backlog, %{"title" => "Trigger"})
      follow = Repo.get_by!(Card, title: "Follow up")
      assert {follow.origin, follow.origin_job_id} == {"automation", nil}
    end

    test "the overseer's own card", ctx do
      settings = %Overseer.Settings{board_id: ctx.board.id}
      assert {:ok, card} = Overseer.ensure_card(ctx.board, settings)
      assert card.origin == "overseer"
    end

    test "a copy gets its own origin, not the original's", ctx do
      {:ok, original} = made(ctx.todo, actor: Actor.runner(ctx.owner, 3))
      {:ok, copy} = Boards.Cards.copy_card(original, nil, by: ctx.owner)
      assert {copy.origin, copy.origin_job_id} == {"person", nil}

      {:ok, clock} = Boards.Cards.copy_card(original, nil, origin: "automation")
      assert clock.origin == "automation"
    end

    test "an import", ctx do
      {:ok, report} =
        Slipdock.Importers.import(
          ctx.owner,
          File.read!("test/support/fixtures/trello_board.json")
        )

      board = Boards.get_board!(hd(report.boards).id)
      origins = board.columns |> Enum.flat_map(& &1.cards) |> Enum.map(& &1.origin) |> Enum.uniq()
      assert origins == ["import"]
    end

    test "a card made before origins were kept has none", ctx do
      {:ok, card} = made(ctx.todo, by: ctx.owner)
      Repo.update_all(Ecto.Query.from(c in Card, where: c.id == ^card.id), set: [origin: nil])
      assert Repo.get!(Card, card.id).origin == nil
    end
  end

  describe "filtering" do
    setup ctx do
      {:ok, person} = made(ctx.todo, actor: Actor.web(ctx.owner))
      {:ok, sweep} = made(ctx.todo, [actor: Actor.runner(ctx.owner, 8)], %{"origin" => "sweep"})
      {:ok, old} = made(ctx.todo, by: ctx.owner)
      Repo.update_all(Ecto.Query.from(c in Card, where: c.id == ^old.id), set: [origin: nil])
      %{person: person, sweep: sweep, old: old}
    end

    test "list_cards takes an origin, or none", ctx do
      ids = &(Boards.Cards.list_cards(ctx.board, %{"origin" => &1}) |> Enum.map(fn c -> c.id end))
      assert ids.("sweep") == [ctx.sweep.id]
      assert ids.("person") == [ctx.person.id]
      assert ids.("none") == [ctx.old.id]
      assert length(ids.(nil)) == 3
      assert length(ids.("all")) == 3
    end

    test "the board's filter matches it, and counts as one", ctx do
      filters = %{Filters.empty() | origin: "sweep"}
      assert Filters.matches?(Repo.get!(Card, ctx.sweep.id), filters)
      refute Filters.matches?(Repo.get!(Card, ctx.person.id), filters)
      assert Filters.matches?(Repo.get!(Card, ctx.old.id), %{filters | origin: "none"})
      refute Filters.matches?(Repo.get!(Card, ctx.sweep.id), %{filters | origin: "none"})
      assert Filters.count(filters) == 1
      assert Filters.any?(filters)
    end

    test "a rule's condition reads it", ctx do
      condition = [%{"field" => "origin", "op" => "is", "value" => "sweep"}]
      assert Runner.conditions_match?(condition, Repo.get!(Card, ctx.sweep.id))
      refute Runner.conditions_match?(condition, Repo.get!(Card, ctx.person.id))
      assert "origin" in Slipdock.Automations.Spec.condition_fields()
    end
  end
end
