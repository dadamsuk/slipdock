defmodule Slipdock.ProfilesTierTest do
  @moduledoc """
  Profiles 2, the human tier (#1952): each profile's tier and its strict
  defaults, a tree's changes to them on the root board, and what an agent's
  acceptance does on a board that ships by pull request for each tier:
  `none` and `ledger` merge; `before_merge` holds the card and opens one
  wait routed `release`, which a person answers with Merge (the merge is
  queued) or Send back (rejected, the reason as the failing part). With
  profiles off every tier is `none`. A held card keeps its lane, the health
  monitor leaves it alone, and the ledger says who it waits for.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Ledger, Lanes, Profiles, Repo, Runners, Verified, WaitRoutes}
  alias Slipdock.Boards.{Card, Wait}
  alias Slipdock.Health.Context
  alias Slipdock.Health.Detectors.{MergeMissing, OrphanInProgress}
  alias Slipdock.Runners.{Job, Runner}

  @pr "https://github.com/acme/app/pull/7"

  setup do
    owner = user_fixture()
    releaser = user_fixture()

    board =
      board_fixture(%{"name" => "Tiers", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "ship_via" => "pull_request",
        "profiles" => true
      })

    {:ok, _} = Slipdock.Access.grant(board, releaser, "write", owner)
    [_backlog, todo, doing, _done] = board.columns
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "checker"}

    # A runner that merges, so a queued merge has somewhere to go.
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "merger", "pool" => "m"})
    runner = Runners.report_kinds(runner, "merge")

    Repo.update_all(from(r in Runner, where: r.id == ^runner.id),
      set: [last_seen_at: DateTime.utc_now(:second)]
    )

    %{
      owner: owner,
      releaser: releaser,
      board: board,
      todo: todo,
      doing: doing,
      builder: builder,
      checker: checker
    }
  end

  defp card(ctx, profile, attrs \\ %{}) do
    card = card_fixture(ctx.doing, Map.merge(%{"title" => "Work"}, attrs))
    {:ok, card} = Boards.Cards.update_card(card, %{"profile" => profile})
    card
  end

  defp submit(card, ctx) do
    {:ok, card} =
      Boards.Cards.update_card(
        Repo.get!(Card, card.id),
        %{"completed" => true, "evidence_pr" => @pr, "evidence_commit" => "abc1234"},
        actor: ctx.builder
      )

    assert card.verify_state == "pending"
    card
  end

  defp accept(card, actor, ctx),
    do: Verified.decide(Repo.get!(Card, card.id), "accept", %{}, actor, ctx.owner)

  defp merge_jobs(card),
    do: Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == "merge"))

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  defp person(user), do: Actor.web(user)

  defp held!(ctx, profile \\ "schema", attrs \\ %{}) do
    card = ctx |> card(profile, attrs) |> submit(ctx)
    {:ok, held} = accept(card, ctx.checker, ctx)
    assert held.verify_state == "held"
    held
  end

  describe "the tiers" do
    test "the defaults are the strict ones" do
      assert Profiles.default_tiers() == %{
               "docs" => "none",
               "fix" => "none",
               "feature" => "ledger",
               "schema" => "before_merge",
               "security" => "before_merge",
               "spike" => "none"
             }

      assert Profiles.tiers() == ~w(none ledger before_merge)
    end

    test "merge_tiers applies changes, default puts one back, and keeps only what differs" do
      assert {:ok, %{"schema" => "none"}} = Profiles.merge_tiers(%{}, %{"schema" => "none"})

      assert {:ok, %{}} =
               Profiles.merge_tiers(%{"schema" => "none"}, %{"schema" => "default"})

      # Setting a profile to its default keeps nothing for it.
      assert {:ok, %{}} = Profiles.merge_tiers(%{}, %{"feature" => "ledger"})

      assert {:ok, %{"docs" => "before_merge"}} =
               Profiles.merge_tiers(%{}, %{docs: "before_merge"})
    end

    test "merge_tiers refuses an unknown profile or tier, naming the lists" do
      assert {:error, message} = Profiles.merge_tiers(%{}, %{"chores" => "none"})
      assert message =~ "chores"
      assert message =~ "security, schema, feature, fix, docs, spike"

      assert {:error, message} = Profiles.merge_tiers(%{}, %{"docs" => "sometimes"})
      assert message =~ "none, ledger, before_merge"

      assert {:error, _} = Profiles.merge_tiers(%{}, "schema=none")
    end

    test "the board's changeset refuses a wrong map and keeps only the changes", ctx do
      assert {:error, cs} = Boards.update_board(ctx.board, %{"profile_tiers" => %{"x" => "none"}})
      assert %{profile_tiers: [_]} = errors_on(cs)

      {:ok, board} =
        Boards.update_board(ctx.board, %{
          "profile_tiers" => %{"schema" => "none", "feature" => "ledger"}
        })

      assert board.profile_tiers == %{"schema" => "none"}
    end

    test "a card's tier: its profile's, none with profiles off, and the root's for a sub-board",
         ctx do
      assert ctx |> card("docs") |> Profiles.tier() == "none"
      assert ctx |> card("feature") |> Profiles.tier() == "ledger"
      assert ctx |> card("spike") |> Profiles.tier() == "none"

      parent = card(ctx, "feature")
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(parent, t)
      [first | _] = Repo.preload(sub, :columns).columns
      sub_card = card_fixture(first, %{"title" => "Sub"})
      {:ok, sub_card} = Boards.Cards.update_card(sub_card, %{"profile" => "schema"})
      assert Profiles.tier(sub_card) == "before_merge"

      {:ok, _} = Boards.update_board(ctx.board, %{"profile_tiers" => %{"schema" => "ledger"}})
      assert Profiles.tier(Repo.get!(Card, sub_card.id)) == "ledger"

      {:ok, _} = Boards.update_board(Repo.get!(Boards.Board, sub.id), %{"profiles" => false})
      assert Profiles.tier(Repo.get!(Card, sub_card.id)) == "none"
    end

    test "a card with no profile is judged by the one it infers", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Move", "paths" => "priv/repo/migrations/**"})
      assert is_nil(card.profile)
      assert Profiles.tier(card) == "before_merge"
    end

    test "security set to none is warned about" do
      assert Profiles.tier_warnings(%{}) == []
      assert [warning] = Profiles.tier_warnings(%{"security" => "none"})
      assert warning =~ "security is set to none"
    end

    test "put_tiers refuses a sub-board's tiers, naming the root", ctx do
      parent = card(ctx, "feature")
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(parent, t)

      assert {:error, message} =
               Profiles.put_tiers(sub, %{"profile_tiers" => %{"schema" => "none"}})

      assert message =~ "root board (##{ctx.board.id})"
    end
  end

  describe "acceptance by tier" do
    test "none and ledger merge, as without profiles", ctx do
      # A docs card is accepted by the server with no verifier (#1953):
      # test/slipdock/profiles_verify_test.exs.
      for profile <- ~w(fix feature) do
        card = ctx |> card(profile) |> submit(ctx)
        {:ok, accepted} = accept(card, ctx.checker, ctx)
        assert accepted.verify_state == "merging", profile
        assert [_job] = merge_jobs(card)
        assert is_nil(Boards.Waits.current_wait(card))
      end
    end

    test "before_merge holds the card and opens one release wait with Merge and Send back",
         ctx do
      {:ok, _} = WaitRoutes.set(ctx.board, %{"release" => [ctx.releaser.email]})
      held = held!(ctx, "schema")

      assert "review" in held.flags
      assert merge_jobs(held) == []

      wait = Boards.Waits.current_wait(held)
      assert wait.purpose == "before_merge"
      assert wait.question == "release"
      assert wait.choices == ["Merge", "Send back"]
      assert wait.on_user_id == ctx.releaser.id
      assert wait.needs =~ "profile schema"
      assert wait.needs =~ @pr

      assert Enum.any?(comments(held), &(&1 =~ "held for a person before merging"))
    end

    test "with no release route the wait is on the board's owner", ctx do
      held = held!(ctx, "security")
      assert Boards.Waits.current_wait(held).on_user_id == ctx.owner.id
    end

    test "with profiles off, or a tier changed to none, a schema card merges", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"profile_tiers" => %{"schema" => "none"}})
      card = ctx |> card("schema") |> submit(ctx)
      assert {:ok, %{verify_state: "merging"}} = accept(card, ctx.checker, ctx)

      {:ok, _} =
        Boards.update_board(Repo.get!(Boards.Board, ctx.board.id), %{
          "profile_tiers" => %{"schema" => "default"},
          "profiles" => false
        })

      card = ctx |> card("schema") |> submit(ctx)
      assert {:ok, %{verify_state: "merging"}} = accept(card, ctx.checker, ctx)
    end

    test "a person's acceptance is a person's look: it merges", ctx do
      card = ctx |> card("schema") |> submit(ctx)
      assert {:ok, %{verify_state: "merging"}} = accept(card, person(ctx.owner), ctx)
      assert [_] = merge_jobs(card)
    end
  end

  describe "answering the wait" do
    test "Merge from a person queues the merge", ctx do
      held = held!(ctx)
      {:ok, _} = Boards.Waits.answer_wait(held, person(ctx.owner), %{"choice" => 1})

      card = Repo.get!(Card, held.id)
      assert card.verify_state == "merging"
      refute "review" in card.flags
      assert [_job] = merge_jobs(card)
      assert Enum.any?(comments(card), &(&1 =~ "**Merge approved**"))
    end

    test "Send back rejects it, the person's reason the failing part", ctx do
      held = held!(ctx)

      {:ok, _} =
        Boards.Waits.answer_wait(held, person(ctx.owner), %{
          "choice" => 2,
          "answer" => "the migration locks the cards table"
        })

      card = Repo.get!(Card, held.id)
      assert card.verify_state == "rejected"
      assert card.verify_note =~ "the migration locks the cards table"
      assert card.verify_checks["ask"] == "misses"
      assert card.verify_checks["notes"]["ask"] =~ "locks the cards table"
      assert card.column_id == ctx.todo.id
      assert merge_jobs(card) == []
    end

    test "a skip sends it back too, saying no reason was given", ctx do
      held = held!(ctx)
      {:ok, _} = Boards.Waits.answer_wait(held, person(ctx.owner), %{"skip" => true})

      card = Repo.get!(Card, held.id)
      assert card.verify_state == "rejected"
      assert card.verify_note =~ "no reason given"
    end

    test "an agent can't answer or skip it", ctx do
      held = held!(ctx)
      other = %{ctx.builder | agent: "someone-else"}

      assert {:error, message} = Boards.Waits.answer_wait(held, other, %{"choice" => 1})
      assert message =~ "a person decides"
      assert {:error, _} = Boards.Waits.answer_wait(held, other, %{"skip" => true})

      assert Repo.get!(Card, held.id).verify_state == "held"
      assert Boards.Waits.current_wait(held)
    end

    test "a withdrawn wait leaves it held: nothing merges", ctx do
      held = held!(ctx)
      {:ok, _} = Boards.Waits.withdraw_wait(held, person(ctx.owner))
      card = Repo.get!(Card, held.id)
      assert card.verify_state == "held"
      assert merge_jobs(card) == []
    end
  end

  describe "a person deciding on the card" do
    test "accept merges and closes the wait; reject needs a reason and sends it back", ctx do
      held = held!(ctx)
      assert {:ok, card} = accept(held, person(ctx.owner), ctx)
      assert card.verify_state == "merging"
      assert is_nil(Boards.Waits.current_wait(card))
      assert Repo.get_by!(Wait, card_id: card.id).close_reason == "withdrawn"

      held = held!(ctx)

      assert {:error, :unprocessable_entity, _} =
               Verified.decide(held, "reject", %{}, person(ctx.owner), ctx.owner)

      assert {:ok, %{verify_state: "rejected"}} =
               Verified.decide(
                 held,
                 "reject",
                 %{"reason" => "not now"},
                 person(ctx.owner),
                 ctx.owner
               )
    end

    test "an agent is refused", ctx do
      held = held!(ctx)

      assert {:error, :forbidden, message} =
               Verified.decide(held, "accept", %{}, %{ctx.checker | agent: "third"}, ctx.owner)

      assert message =~ "held for a person"
    end
  end

  describe "while held" do
    test "it keeps its lane as a card awaiting verification does on a pull request board", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => true})
      held!(ctx, "schema", %{"paths" => "lib/a/**"})
      other = card_fixture(ctx.todo, %{"title" => "Other", "paths" => "lib/a/b.ex"})
      assert %Card{} = Lanes.conflict(other)
    end

    test "the health monitor flags neither a missing merge nor an orphan", ctx do
      held = held!(ctx)
      later = DateTime.add(DateTime.utc_now(), 3 * 3600, :second)
      board = Repo.get!(Boards.Board, ctx.board.id)

      assert MergeMissing.detect(Context.new(board, later), %{"minutes" => 10}) == []

      refute Enum.any?(
               OrphanInProgress.detect(Context.new(board, later), %{"minutes" => 1}),
               &(&1.card_id == held.id)
             )
    end

    test "the ledger says who it waits for, until it merges", ctx do
      {:ok, _} = WaitRoutes.set(ctx.board, %{"release" => [ctx.releaser.email]})
      held = held!(ctx)
      board = Repo.get!(Boards.Board, ctx.board.id)

      line = fn ->
        {:ok, ledger} = Ledger.since(board, since: "1")
        ledger.days |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.card.id == held.id))
      end

      assert line.().waiting_for == Slipdock.Accounts.User.display_name(ctx.releaser)
      assert "accepted" in line.().events

      {:ok, _} = Boards.Waits.answer_wait(held, person(ctx.releaser), %{"choice" => 1})
      assert is_nil(line.().waiting_for)
    end
  end
end
