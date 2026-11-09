defmodule Slipdock.SpikeCardsTest do
  @moduledoc """
  Spike cards merge nothing and hold no lane (#2349): a spike answers a
  question by building, so an agent completing one names no pull request
  (it completes with `evidence_no_code`), its default human tier is `none`
  and an agent's acceptance holds nothing, and its paths, in progress, hold
  no lane against an overlapping card nor hold a queued job back. A card
  is a spike by its profile, or with no profile by its `spike` tag, on any
  board.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Lanes, Profiles, Repo, Runners, Verified}
  alias Slipdock.Boards.{Card, Wait}
  alias Slipdock.Runners.Job

  @pr "https://github.com/acme/app/pull/9"
  @why "spike: answer on W-12, prototype on card-1"

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Spikes", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "evidence_required" => true,
        "ship_via" => "pull_request",
        "profiles" => true,
        "lanes" => true
      })

    [_backlog, todo, doing, _done] = board.columns
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "checker"}

    %{owner: owner, board: board, todo: todo, doing: doing, builder: builder, checker: checker}
  end

  defp tagged(card, board, name) do
    {:ok, card} = Boards.set_card_tags(card, [tag_fixture(board, name)])
    card
  end

  defp spike(ctx, attrs \\ %{}) do
    card = card_fixture(ctx.doing, Map.merge(%{"title" => "Does the API page?"}, attrs))
    {:ok, card} = Boards.update_card(card, %{"profile" => "spike"})
    card
  end

  defp complete(card, attrs, actor) do
    Boards.update_card(
      Repo.get!(Card, card.id),
      Map.merge(%{"completed" => true, "evidence" => "ran it against the sandbox"}, attrs),
      actor: actor
    )
  end

  defp with_pr, do: %{"evidence_pr" => @pr, "evidence_commit" => "abc1234"}

  describe "spike?/1" do
    test "by profile, or with none by its tag in any case", ctx do
      assert ctx |> spike() |> Profiles.spike?()

      plain = card_fixture(ctx.todo, %{"title" => "Plain"})
      refute Profiles.spike?(plain)

      hand = plain |> tagged(ctx.board, "Spike") |> then(&Repo.get!(Card, &1.id))
      assert Profiles.spike?(hand)

      # A profile someone set wins over the tag.
      {:ok, featured} = Boards.update_card(hand, %{"profile" => "feature"})
      refute Profiles.spike?(featured)
      refute Profiles.spike?(%Card{})
    end
  end

  describe "completing a spike" do
    test "an agent naming a PR is refused, the message naming --no-code", ctx do
      assert {:error, cs} = complete(spike(ctx), with_pr(), ctx.builder)
      assert %{evidence_pr: [message]} = errors_on(cs)
      assert message =~ "a spike merges nothing"
      assert message =~ "--no-code"
      refute Repo.get!(Card, cs.data.id).completed
    end

    test "a hand-tagged spike is refused too, profiles on or off", ctx do
      card = ctx.doing |> card_fixture(%{"title" => "Hand"}) |> tagged(ctx.board, "spike")
      {:ok, _} = Boards.update_board(ctx.board, %{"profiles" => false})
      assert {:error, cs} = complete(card, with_pr(), ctx.builder)
      assert %{evidence_pr: [_]} = errors_on(cs)
    end

    test "an agent setting the profile to spike in the same write is refused", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Turned spike"})

      assert {:error, cs} =
               complete(card, Map.put(with_pr(), "profile", "spike"), ctx.builder)

      assert %{evidence_pr: [_]} = errors_on(cs)
    end

    test "a person is not refused", ctx do
      assert {:ok, card} = complete(spike(ctx), with_pr(), Actor.web(ctx.owner))
      assert card.completed
    end

    test "a card that isn't a spike still completes with a PR", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Feature"})
      assert {:ok, %{verify_state: "pending"}} = complete(card, with_pr(), ctx.builder)
    end

    test "with --no-code it is submitted, and an agent's acceptance merges nothing", ctx do
      assert {:ok, card} = complete(spike(ctx), %{"evidence_no_code" => @why}, ctx.builder)
      assert card.verify_state == "pending"

      assert {:ok, accepted} =
               Verified.decide(Repo.get!(Card, card.id), "accept", %{}, ctx.checker, ctx.owner)

      assert accepted.completed
      assert accepted.verify_state == "accepted"
      assert Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == "merge")) == []
      assert Repo.all(from(w in Wait, where: w.card_id == ^card.id)) == []
    end
  end

  describe "the spike tier" do
    test "defaults to none, so a spike is never held", ctx do
      assert Profiles.default_tiers()["spike"] == "none"
      assert ctx |> spike() |> Repo.preload(:board) |> Profiles.tier() == "none"
    end

    test "a board can still raise it", ctx do
      {:ok, _} =
        Boards.update_board(ctx.board, %{"profile_tiers" => %{"spike" => "before_merge"}})

      assert ctx |> spike() |> Repo.preload(:board) |> Profiles.tier() == "before_merge"
    end
  end

  describe "lanes" do
    test "a spike in progress with paths blocks no overlapping card", ctx do
      running = spike(ctx)
      {:ok, running} = Boards.update_card(running, %{"paths" => ["lib/a/**"]})
      working_job_fixture(running)

      next = card_fixture(ctx.todo, %{"title" => "Next"})
      {:ok, next} = Boards.update_card(next, %{"paths" => ["lib/a/b.ex"]})

      assert Lanes.conflict(next) == nil
      assert :ok = Boards.move_card(next.id, ctx.doing.id, nil, actor: ctx.builder)
    end

    test "a hand-tagged spike holds none either; untagged, the same card does", ctx do
      running = card_fixture(ctx.doing, %{"title" => "Prototype"})
      {:ok, running} = Boards.update_card(running, %{"paths" => ["lib/a/**"]})
      working_job_fixture(running)

      next = card_fixture(ctx.todo, %{"title" => "Next"})
      {:ok, next} = Boards.update_card(next, %{"paths" => ["lib/a/b.ex"]})
      assert %Card{id: id} = Lanes.conflict(next)
      assert id == running.id

      tagged(running, ctx.board, "spike")
      assert Lanes.conflict(next) == nil
    end

    test "a spike isn't held behind a card in progress, nor its job", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "r", "pool" => "dev"})
      running = card_fixture(ctx.doing, %{"title" => "Running"})
      {:ok, running} = Boards.update_card(running, %{"paths" => ["lib/a/**"]})
      working_job_fixture(running)

      queued = card_fixture(ctx.todo, %{"title" => "Spike it"})
      {:ok, queued} = Boards.update_card(queued, %{"paths" => ["lib/a/b.ex"]})
      queued = tagged(queued, ctx.board, "spike")

      assert Lanes.conflict(Repo.get!(Card, queued.id)) == nil
      {:ok, job} = Runners.queue(queued, %{pool: "dev", kind: "claude", prompt: "go"})
      assert Lanes.held_cards(ctx.board.id) == %{}
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id
    end

    test "no job is held behind a spike in progress", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "r", "pool" => "dev"})
      running = spike(ctx)
      {:ok, running} = Boards.update_card(running, %{"paths" => ["lib/a/**"]})
      working_job_fixture(running)

      next = card_fixture(ctx.todo, %{"title" => "Next"})
      {:ok, next} = Boards.update_card(next, %{"paths" => ["lib/a/b.ex"]})
      {:ok, job} = Runners.queue(next, %{pool: "dev", kind: "claude", prompt: "go"})

      assert Lanes.held_cards(ctx.board.id) == %{}
      assert Runners.held_reason(Repo.reload!(job), claimant: true) == nil
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id
    end
  end
end
