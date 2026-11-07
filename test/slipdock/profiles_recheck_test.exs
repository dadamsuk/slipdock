defmodule Slipdock.ProfilesRecheckTest do
  @moduledoc """
  The profile checked against the actual change (#2017): an agent completing
  a card on a board with profiles on, with the change's `changed_lines` and
  `changed_files`, raises its profile (never lowers it) in the same write,
  with the reason in the card's activity. A person's `fix` survives a large
  diff but not a migration or a security path; a person completing it, a
  board with profiles off or a completion with no change raises nothing;
  a malformed change is refused.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card

  @migration "priv/repo/migrations/20261107000000_add_thing.exs"

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Rechecked", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"profiles" => true})
    [_backlog, todo, doing, _done] = board.columns
    agent = Actor.runner(owner.id, nil, "bot")
    %{owner: owner, board: board, todo: todo, doing: doing, agent: agent}
  end

  # A card an agent has started, so it has its inferred profile.
  defp started(ctx, attrs, tags \\ []) do
    card = card_fixture(ctx.todo, Map.put_new(attrs, "title", "Work"))

    if tags != [] do
      {:ok, _} = Boards.set_card_tags(card, Enum.map(tags, &tag(ctx.board, &1)))
    end

    :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
    Repo.get!(Card, card.id)
  end

  defp tag(board, name) do
    Repo.get_by(Slipdock.Boards.Tag, board_id: board.id, name: name) ||
      tag_fixture(board, name)
  end

  defp complete(card, change, actor) do
    Boards.update_card(card, Map.merge(%{"completed" => true}, change), actor: actor)
  end

  defp activity(ctx, card),
    do: ctx.board.id |> Boards.list_activities(100, card.id) |> Enum.map(& &1.message)

  test "the size bump: a fix over the limit is a feature, logged with the count", ctx do
    card = started(ctx, %{"paths" => "lib/x.ex"}, ["bug"])
    assert card.profile == "fix"

    {:ok, _} =
      complete(card, %{"changed_lines" => 612, "changed_files" => ["lib/x.ex"]}, ctx.agent)

    card = Repo.get!(Card, card.id)
    assert card.completed
    assert {card.profile, card.profile_source} == {"feature", "inferred"}
    assert "profile raised: fix → feature, 612 lines changed" in activity(ctx, card)
  end

  test "a change at the limit, or one with no count, leaves a fix alone", ctx do
    card = started(ctx, %{"paths" => "lib/x.ex"}, ["bug"])
    {:ok, _} = complete(card, %{"changed_lines" => 400}, ctx.agent)
    assert Repo.get!(Card, card.id).profile == "fix"

    other = started(ctx, %{"paths" => "lib/y.ex"}, ["bug"])
    {:ok, _} = complete(other, %{"changed_files" => ["lib/y.ex"]}, ctx.agent)
    assert Repo.get!(Card, other.id).profile == "fix"
    refute Enum.any?(activity(ctx, other), &String.starts_with?(&1, "profile raised"))
  end

  test "a docs card whose change adds a migration is schema", ctx do
    card = started(ctx, %{"paths" => "docs/**"})
    assert card.profile == "docs"

    {:ok, _} =
      complete(
        card,
        %{"changed_lines" => "12", "changed_files" => "docs/a.md, #{@migration}"},
        ctx.agent
      )

    assert Repo.get!(Card, card.id).profile == "schema"
    assert "profile raised: docs → schema, changes #{@migration}" in activity(ctx, card)
  end

  test "a security path raises it to security, even over a person's fix", ctx do
    card = started(ctx, %{"paths" => "lib/x.ex"})
    {:ok, card} = Boards.update_card(card, %{"profile" => "fix"}, actor: Actor.web(ctx.owner))
    assert card.profile_source == "person"

    {:ok, _} =
      complete(
        card,
        %{"changed_lines" => 8, "changed_files" => ["lib/slipdock/access.ex"]},
        ctx.agent
      )

    assert Repo.get!(Card, card.id).profile == "security"
    assert "profile raised: fix → security, changes lib/slipdock/access.ex" in activity(ctx, card)
  end

  test "a person's fix survives a large diff", ctx do
    card = started(ctx, %{"paths" => "lib/x.ex"})
    {:ok, card} = Boards.update_card(card, %{"profile" => "fix"}, actor: Actor.web(ctx.owner))

    {:ok, _} =
      complete(card, %{"changed_lines" => 5000, "changed_files" => ["lib/x.ex"]}, ctx.agent)

    assert %{profile: "fix", profile_source: "person"} = Repo.get!(Card, card.id)
  end

  test "never lowered: a schema card with a small docs-only change stays schema", ctx do
    card = started(ctx, %{"paths" => @migration})
    assert card.profile == "schema"

    {:ok, _} =
      complete(card, %{"changed_lines" => 900, "changed_files" => ["docs/a.md"]}, ctx.agent)

    assert Repo.get!(Card, card.id).profile == "schema"
    refute Enum.any?(activity(ctx, card), &String.starts_with?(&1, "profile raised"))
  end

  test "a profile the completing write sets is the one judged", ctx do
    card = started(ctx, %{"paths" => "lib/x.ex"})

    {:ok, _} =
      complete(card, %{"profile" => "docs", "changed_lines" => 401}, ctx.agent)

    assert Repo.get!(Card, card.id).profile == "feature"
  end

  test "a card with no profile is judged by its inferred one, and stored when raised", ctx do
    card = card_fixture(ctx.doing, %{"title" => "Unstarted", "paths" => "docs/**"})
    assert card.profile == nil

    {:ok, _} = complete(card, %{"changed_files" => [@migration]}, ctx.agent)
    assert %{profile: "schema", profile_source: "inferred"} = Repo.get!(Card, card.id)
    assert "profile raised: docs → schema, changes #{@migration}" in activity(ctx, card)
  end

  test "with profiles off nothing is raised", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"profiles" => false})
    card = card_fixture(ctx.doing, %{"title" => "Off", "paths" => "docs/**"})

    {:ok, _} =
      complete(card, %{"changed_lines" => 5000, "changed_files" => [@migration]}, ctx.agent)

    card = Repo.get!(Card, card.id)
    assert card.completed
    assert card.profile == nil
  end

  test "a person, the assistant or a rule completing it raises nothing", ctx do
    for actor <- [Actor.web(ctx.owner), Actor.assistant(ctx.owner), Actor.automation()] do
      card = started(ctx, %{"paths" => "docs/**"})
      {:ok, _} = complete(card, %{"changed_files" => [@migration]}, actor)
      assert Repo.get!(Card, card.id).profile == "docs"
    end
  end

  test "only a completion: a write that doesn't complete it raises nothing", ctx do
    card = started(ctx, %{"paths" => "docs/**"})

    {:ok, _} =
      Boards.update_card(card, %{"changed_files" => [@migration], "percent_complete" => 50},
        actor: ctx.agent
      )

    assert Repo.get!(Card, card.id).profile == "docs"
  end

  test "a malformed change is refused, and nothing is written", ctx do
    card = started(ctx, %{"paths" => "lib/x.ex"}, ["bug"])

    for {change, field} <- [
          {%{"changed_lines" => -1}, :changed_lines},
          {%{"changed_lines" => "many"}, :changed_lines},
          {%{"changed_lines" => 1.5}, :changed_lines},
          {%{"changed_files" => [1, 2]}, :changed_files},
          {%{"changed_files" => %{"a" => 1}}, :changed_files},
          {%{"changed_files" => List.duplicate("a.ex", 5001)}, :changed_files}
        ] do
      assert {:error, changeset} = complete(card, change, ctx.agent)
      assert Keyword.has_key?(changeset.errors, field)
    end

    refute Repo.get!(Card, card.id).completed
  end

  describe "on a board that verifies work" do
    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})
      %{board: board}
    end

    test "a docs card raised by its change isn't accepted unverified", ctx do
      plain = started(ctx, %{"title" => "Plain", "paths" => "docs/**"})

      {:ok, _} =
        complete(plain, %{"evidence" => "read", "changed_files" => ["docs/a.md"]}, ctx.agent)

      assert Repo.get!(Card, plain.id).verify_state == "accepted"

      raised = started(ctx, %{"title" => "Raised", "paths" => "docs/**"})

      {:ok, _} =
        complete(raised, %{"evidence" => "read", "changed_files" => [@migration]}, ctx.agent)

      assert %{verify_state: "pending", profile: "schema"} = Repo.get!(Card, raised.id)
    end
  end

  describe "the ship instructions" do
    test "ask for the change on a profiles board, and not without profiles", ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

      card = card_fixture(ctx.doing, %{"title" => "Shipped"})
      assert Verified.ship_instructions(card) =~ "--diff-base origin/<default branch>"

      assert Verified.ship_instructions(card) =~
               "complete_card `changed_lines` and `changed_files`"

      {:ok, _} = Boards.update_board(board, %{"profiles" => false})
      refute Verified.ship_instructions(Repo.get!(Card, card.id)) =~ "--diff-base"
    end
  end
end
