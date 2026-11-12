defmodule Slipdock.OverseerHousekeepingTest do
  @moduledoc """
  The morning digest of Housekeeping's work (#2781, W-2588 §5): once a day
  at the overseer's `digest_at` in the owner's zone, a status update on the
  overseer's card grouping what the Housekeeping feeds worked by theme, and
  naming only what needs the owner: rejected, escalated, given up on, or
  overlapping an in-progress epic's paths. An empty day says so.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Overseer, Repo}
  alias Slipdock.Boards.{Card, StatusUpdate}
  alias Slipdock.Overseer.{Housekeeping, Settings}

  setup do
    owner = user_fixture()
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"timezone" => "Europe/London"})
    board = board_fixture(%{"name" => "Chores"}, owner: owner)
    [_backlog, _todo, doing, _done] = board.columns
    {:ok, housekeeping} = Boards.create_column(board, %{"name" => "Housekeeping"})
    {:ok, triage} = Boards.create_column(board, %{"name" => "Triage", "category" => "triage"})

    feed =
      rule_fixture(
        board,
        %{
          "trigger" => %{"type" => "list_top", "column" => "Housekeeping", "backfill" => true},
          "actions" => [%{"type" => "runner", "pool" => "loop"}]
        },
        %{"enabled" => false}
      )

    %{
      owner: owner,
      board: board,
      doing: doing,
      housekeeping: housekeeping,
      triage: triage,
      feed: feed
    }
  end

  @since ~U[2027-03-01 07:00:00Z]
  @now ~U[2027-03-02 07:05:00Z]

  # A card the Housekeeping feed sent a job for, ended in the window.
  defp worked(ctx, title, attrs \\ %{}, job \\ %{}) do
    card = card_fixture(ctx.housekeeping, %{"title" => title})

    working_job_fixture(
      card,
      Map.merge(
        %{status: "done", rule_id: ctx.feed.id, finished_at: ~U[2027-03-02 01:00:00Z]},
        job
      )
    )

    if attrs != %{},
      do: Repo.update_all(from(c in Card, where: c.id == ^card.id), set: Map.to_list(attrs))

    Repo.get!(Card, card.id)
  end

  defp tagged(ctx, card, name) do
    {:ok, tag} = Boards.create_tag(ctx.board, %{"name" => name})
    Boards.set_card_tags(card, [tag])
  end

  defp digest(ctx),
    do: Housekeeping.digest(Repo.get!(Slipdock.Boards.Board, ctx.board.id), @since, @now)

  describe "the digest" do
    test "groups the cards by tag, else other, largest first, and names nobody", ctx do
      a = worked(ctx, "Flaky test")
      b = worked(ctx, "Another flaky test")
      c = worked(ctx, "Untagged")
      tagged(ctx, a, "ci")
      {:ok, ci} = {:ok, Repo.get_by!(Slipdock.Boards.Tag, name: "ci")}
      Boards.set_card_tags(b, [ci])

      result = digest(ctx)
      assert [{"ci", [_, _]}, {"other", [only]}] = result.groups
      assert only.id == c.id
      assert result.needs_owner == []
      assert result.body =~ "3 cards worked."
      assert result.body =~ "- ci: 2 (##{a.id}, ##{b.id})"
      assert result.body =~ "- other: 1 (##{c.id})"
      assert result.body =~ "Nothing needs you."
    end

    test "leaves out jobs from other rules and outside the window", ctx do
      todo = Enum.find(Boards.get_board!(ctx.board.id).columns, &(&1.name == "To Do"))
      other = card_fixture(todo, %{"title" => "Mine"})
      working_job_fixture(other, %{status: "done", finished_at: ~U[2027-03-02 01:00:00Z]})
      worked(ctx, "Yesterday's", %{}, %{finished_at: ~U[2027-02-28 23:00:00Z]})

      assert digest(ctx).cards == []
    end

    test "names a rejected, an escalated and a given-up card, and says why", ctx do
      rejected =
        worked(ctx, "Rejected", %{verify_state: "rejected", verify_at: ~U[2027-03-02 02:00:00Z]})

      escalated = worked(ctx, "Grew", %{column_id: ctx.triage.id})
      gave_up = worked(ctx, "Stuck", %{}, %{status: "failed", recovery: "gave_up"})
      fine = worked(ctx, "Fine")

      needs = digest(ctx).needs_owner |> Map.new(fn {card, why} -> {card.id, why} end)

      assert needs == %{
               rejected.id => "rejected by verification",
               escalated.id => "escalated to Triage",
               gave_up.id => "given up on"
             }

      refute Map.has_key?(needs, fine.id)
      body = digest(ctx).body
      assert body =~ "Needs you:"
      assert body =~ "- ##{escalated.id} “Grew”: escalated to Triage"
    end

    test "names one whose paths overlap a card in progress under an epic", ctx do
      epic = card_fixture(ctx.doing, %{"title" => "Epic"})
      {:ok, sub} = Boards.create_sub_board(epic, hd(Boards.list_templates(nil)))

      {:ok, sub_doing} =
        Boards.create_column(sub, %{"name" => "Doing", "category" => "doing"})

      subcard = card_fixture(sub_doing, %{"title" => "Epic work"})
      {:ok, _} = Boards.update_card(subcard, %{"paths" => "lib/app/**"})

      overlapping = worked(ctx, "Touches the epic", %{paths: ["lib/app/x.ex"]})
      apart = worked(ctx, "Elsewhere", %{paths: ["docs/**"]})

      needs = Map.new(digest(ctx).needs_owner, fn {card, why} -> {card.id, why} end)
      assert needs[overlapping.id] =~ "its paths overlap ##{subcard.id} “Epic work”"
      refute Map.has_key?(needs, apart.id)
    end

    test "an empty day says so in a line", ctx do
      assert digest(ctx).body == "**Housekeeping since Mon 1 Mar 07:00**: nothing ran."
    end
  end

  describe "maybe_digest/3" do
    defp on(ctx, attrs \\ %{}) do
      {:ok, settings} = Overseer.put_settings(ctx.board, Map.put(attrs, "enabled", true))
      settings
    end

    defp updates(settings),
      do: Repo.all(from(u in StatusUpdate, where: u.card_id == ^settings.card_id))

    test "writes once a day after digest_at in the owner's zone, on the overseer's card", ctx do
      settings = on(ctx)
      worked(ctx, "Chore")
      root = Repo.get!(Slipdock.Boards.Board, ctx.board.id)

      # 06:59 in London (GMT in March): not yet.
      assert Housekeeping.maybe_digest(root, settings, ~U[2027-03-02 06:59:00Z]) == :not_due

      assert {:ok, body} = Housekeeping.maybe_digest(root, settings, ~U[2027-03-02 07:05:00Z])
      assert body =~ "1 card worked."
      assert [update] = updates(settings)
      assert update.body == body
      assert update.health == "on_track"

      # Not twice the same day.
      settings = Repo.get!(Settings, settings.id)
      assert settings.housekeeping_digest_on == ~D[2027-03-02]
      assert Housekeeping.maybe_digest(root, settings, ~U[2027-03-02 18:00:00Z]) == :not_due

      # The next day covers only since the last one.
      assert {:ok, next} = Housekeeping.maybe_digest(root, settings, ~U[2027-03-03 07:01:00Z])
      assert next =~ "nothing ran"
      assert length(updates(settings)) == 2
    end

    test "is at risk when something needs the owner, and follows digest_at", ctx do
      settings = on(ctx, %{"digest_at" => "06:30"})
      worked(ctx, "Rejected", %{verify_state: "rejected", verify_at: ~U[2027-03-02 02:00:00Z]})
      root = Repo.get!(Slipdock.Boards.Board, ctx.board.id)

      assert {:ok, _} = Housekeeping.maybe_digest(root, settings, ~U[2027-03-02 06:31:00Z])
      assert [%{health: "at_risk"}] = updates(settings)
    end

    test "nothing while the overseer is off", ctx do
      settings = on(ctx)
      {:ok, settings} = Overseer.put_settings(ctx.board, %{"enabled" => false})
      root = Repo.get!(Slipdock.Boards.Board, ctx.board.id)
      assert Housekeeping.maybe_digest(root, settings, ~U[2027-03-02 08:00:00Z]) == :not_due
    end

    test "the overseer's tick writes it", ctx do
      settings = on(ctx)
      Overseer.tick(~U[2027-03-02 07:10:00Z])
      assert Repo.get!(Settings, settings.id).housekeeping_digest_on == ~D[2027-03-02]
      assert Enum.any?(updates(settings), &(&1.body =~ "**Housekeeping since"))
    end
  end

  describe "digest_at" do
    test "defaults to 07:00, takes a time of day and refuses anything else", ctx do
      assert %Settings{}.digest_at == "07:00"
      assert {:ok, s} = Overseer.put_settings(ctx.board, %{"digest_at" => " 6:30 "})
      assert s.digest_at == "6:30"

      for bad <- ["25:00", "7", "07:60", "seven"] do
        assert {:error, changeset} = Overseer.put_settings(ctx.board, %{"digest_at" => bad}),
               bad

        assert errors_on(changeset)[:digest_at], bad
      end

      # Blank goes back to the default.
      assert {:ok, s} = Overseer.put_settings(ctx.board, %{"digest_at" => ""})
      assert s.digest_at == "07:00"
    end
  end
end
