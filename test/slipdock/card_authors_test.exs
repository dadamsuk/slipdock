defmodule Slipdock.CardAuthorsTest do
  @moduledoc """
  Who created a card and who changed it last, and when (#2028,
  `Slipdock.CardAuthors`): the creator from the card's `created` ledger row,
  the last change the later of its newest activity row and its own
  `updated_at`, and nobody recorded is the time alone, never a guess.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, CardAuthors, Repo, Runners}
  alias Slipdock.Boards.{Activity, Card, CardMove}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture()
    owner = Repo.update!(Ecto.Changeset.change(owner, name: "Robin Maker"))
    board = board_fixture(%{"name" => "Authors"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns

    on_exit(fn -> Actor.put(nil) end)
    %{owner: owner, board: board, todo: todo, doing: doing}
  end

  # A write as `actor`, both in the ledger (opts) and the activity log (the
  # process's actor), the way a door makes one.
  defp as(actor, name \\ nil, fun) do
    Actor.put(actor, name)

    try do
      fun.(actor: actor)
    after
      Actor.put(nil)
    end
  end

  defp create(ctx, actor, name \\ nil) do
    {:ok, card} =
      as(actor, name, fn opts ->
        Boards.Cards.create_card(ctx.todo, %{"title" => "Made"}, opts)
      end)

    card
  end

  # Moves a card's own `updated_at` and its activity rows' times, so the
  # ordering can be set up without sleeping.
  defp set_updated(card, at),
    do: Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [updated_at: at])

  defp set_activity(card, at),
    do: Repo.update_all(from(a in Activity, where: a.card_id == ^card.id), set: [inserted_at: at])

  defp authors(card), do: CardAuthors.for_card(Boards.Cards.get_card!(card.id))

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  describe "created by" do
    test "a person in the web UI, by their name", ctx do
      card = create(ctx, Actor.web(ctx.owner))

      assert %{created_by: %{kind: "person", name: "Robin Maker", user_id: id}} = authors(card)
      assert id == ctx.owner.id
      assert authors(card).created_at == Boards.Cards.get_card!(card.id).inserted_at
    end

    test "an agent over MCP, by its token label", ctx do
      card = create(ctx, Actor.mcp(%{user: ctx.owner, token: %{label: "claude-desktop"}}))
      assert %{created_by: %{kind: "agent", name: "claude-desktop"}} = authors(card)
    end

    test "an agent over the CLI with no label, as an agent, not as its token's owner", ctx do
      actor = %{kind: "agent", via: "cli", user_id: ctx.owner.id, agent: nil, job_id: nil}
      card = create(ctx, actor)
      assert %{created_by: %{kind: "agent", name: "An agent"}} = authors(card)
    end

    test "a runner job, by its loop's name", ctx do
      {:ok, runner, _} =
        Runners.create_runner(ctx.board, %{"name" => "Dev server", "pool" => "dev"})

      seed = card_fixture(ctx.todo)
      {:ok, _} = Runners.queue(seed, %{pool: "dev", kind: "claude", prompt: "go"})
      %Job{} = job = Runners.claim(runner)

      card = create(ctx, Actor.runner(ctx.owner, job.id, "bigwhite-token"))

      assert %{created_by: %{kind: "runner", name: "Dev server loop", job_id: job_id}} =
               authors(card)

      assert job_id == job.id
      # The activity row is named for the loop too, so the last change reads the same.
      assert %{updated_by: %{name: "Dev server loop"}} = authors(card)
    end

    test "a runner job whose job has no runner name falls back to the token label", ctx do
      seed = card_fixture(ctx.todo)
      {:ok, job} = Runners.queue(seed, %{pool: "dev", kind: "claude", prompt: "go"})
      card = create(ctx, Actor.runner(ctx.owner, job.id, "bigwhite-token"))
      assert %{created_by: %{kind: "agent", name: "bigwhite-token"}} = authors(card)
    end

    test "an automation rule, by the rule's name", ctx do
      rule_fixture(
        ctx.board,
        %{
          "trigger" => %{"type" => "card_completed"},
          "actions" => [
            %{"type" => "create_card", "title" => "Follow up", "column" => ctx.todo.name}
          ]
        },
        %{"name" => "Follow-ups"}
      )

      done = card_fixture(ctx.todo, %{"title" => "Launch"})
      {:ok, _} = Boards.Cards.toggle_completed(done)

      follow = Repo.one!(from(c in Card, where: c.title == "Follow up"))
      assert %{created_by: %{kind: "automation", name: "Follow-ups"}} = authors(follow)
    end

    test "a card older than the ledger, or a backfilled row, shows the date only", ctx do
      card = card_fixture(ctx.todo)
      Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [backfilled: true])
      assert %{created_by: nil, created_at: %DateTime{}} = authors(card)

      Repo.delete_all(from(m in CardMove, where: m.card_id == ^card.id))
      assert %{created_by: nil} = authors(card)
    end

    test "nobody said who: the time alone", ctx do
      card = card_fixture(ctx.todo)
      assert %{created_by: nil, updated_by: nil} = authors(card)
    end
  end

  describe "last changed by" do
    setup ctx do
      other = user_fixture("authors.editor@example.com")
      other = Repo.update!(Ecto.Changeset.change(other, name: "Sam Editor"))
      card = create(ctx, Actor.web(ctx.owner))
      # Everything so far was a while ago.
      set_updated(card, ago(600))
      set_activity(card, ago(600))
      %{other: other, card: card}
    end

    test "a card nobody touched since is last changed by whoever made it", ctx do
      fresh = create(ctx, Actor.web(ctx.owner))
      assert %{updated_by: %{name: "Robin Maker"}} = authors(fresh)
    end

    test "a comment: the comment's author, though the card's updated_at didn't move", ctx do
      as(Actor.web(ctx.other), "Sam Editor", fn _ ->
        Boards.Comments.add_comment(Boards.Cards.get_card!(ctx.card.id), "Looks good",
          by: ctx.other
        )
      end)

      %{updated_by: who, updated_at: at} = authors(ctx.card)
      assert who.name == "Sam Editor"
      assert DateTime.compare(at, ago(60)) == :gt
    end

    test "a field edit: its editor", ctx do
      as(Actor.mcp(%{user: ctx.owner, token: %{label: "codex"}}), fn opts ->
        Boards.Cards.update_card(
          Boards.Cards.get_card!(ctx.card.id),
          %{"priority" => "high"},
          opts
        )
      end)

      assert %{updated_by: %{kind: "agent", name: "codex"}} = authors(ctx.card)
    end

    test "a move: its mover", ctx do
      as(Actor.web(ctx.other), "Sam Editor", fn opts ->
        Boards.Cards.move_card(ctx.card.id, ctx.doing.id, nil, opts)
      end)

      assert %{updated_by: %{kind: "person", name: "Sam Editor"}} = authors(ctx.card)
    end

    test "an automation's change: the rule's name", ctx do
      Process.put(:automation_depth, 1)

      try do
        Actor.as_rule("Escalate", fn ->
          Boards.Cards.update_card(Boards.Cards.get_card!(ctx.card.id), %{
            "priority" => "critical"
          })
        end)
      after
        Process.delete(:automation_depth)
      end

      assert %{updated_by: %{kind: "automation", name: "Escalate"}} = authors(ctx.card)
    end

    test "a row from before actor tracking: the time alone", ctx do
      Repo.update_all(from(a in Activity, where: a.card_id == ^ctx.card.id),
        set: [actor_kind: nil, actor_name: nil, user_id: nil]
      )

      set_updated(ctx.card, ago(600))
      assert %{updated_by: nil, updated_at: at} = authors(ctx.card)
      assert DateTime.compare(at, ago(590)) == :lt
    end
  end

  describe "when activity and updated_at disagree" do
    setup ctx do
      card = create(ctx, Actor.web(ctx.owner))
      %{card: card}
    end

    test "activity later: its time and its actor", ctx do
      set_updated(ctx.card, ago(3600))
      set_activity(ctx.card, ago(60))

      assert %{updated_by: %{name: "Robin Maker"}, updated_at: at} = authors(ctx.card)
      assert at == ago(60) or DateTime.diff(at, ago(60)) in -1..1
    end

    test "updated_at later by more than a moment: its time, and nobody", ctx do
      set_activity(ctx.card, ago(3600))
      set_updated(ctx.card, ago(60))

      assert %{updated_by: nil, updated_at: at} = authors(ctx.card)
      assert DateTime.diff(at, ago(60)) in -1..1
    end

    test "within a moment of each other: the same change, by the row's actor", ctx do
      set_activity(ctx.card, ago(61))
      set_updated(ctx.card, ago(60))

      assert %{updated_by: %{name: "Robin Maker"}, updated_at: at} = authors(ctx.card)
      assert DateTime.diff(at, ago(60)) in -1..1
    end
  end

  test "loop_name/1 reads as the card names a loop" do
    assert CardAuthors.loop_name("Dev server") == "Dev server loop"
  end
end
