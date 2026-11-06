defmodule Slipdock.VerifiedEpicPrTest do
  @moduledoc """
  Epics on a pull request board (#1917): each subcard ships and merges its
  own pull request, so an epic has none of its own left to merge. An agent
  completes one without `evidence_pr`, and accepting it completes it with
  no merge job: when it names no pull request, or one a subcard already
  merged. An epic naming a pull request of its own still merges it, and a
  card with no subcards still needs one.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Runners.Job

  @sub_pr "https://github.com/acme/app/pull/131"
  @own_pr "https://github.com/acme/app/pull/133"

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Epics by PR", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "evidence_required" => true,
        "ship_via" => "pull_request"
      })

    [_backlog, _todo, doing, done] = board.columns
    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    [column | _] = Boards.get_board!(sub.id).columns
    sub_card = card_fixture(column, %{"title" => "Part one"})
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "checker"}

    %{
      owner: owner,
      board: board,
      doing: doing,
      done: done,
      epic: epic,
      sub: sub,
      sub_card: sub_card,
      builder: builder,
      checker: checker
    }
  end

  defp fresh(card), do: Repo.get!(Card, card.id)

  # The subcard as a merge leaves it: accepted, complete, its PR kept.
  defp merged(card, pr \\ @sub_pr) do
    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [completed: true, verify_state: "accepted", evidence_pr: pr, merge_sha: "abc1234"]
    )

    fresh(card)
  end

  defp submit(card, attrs, ctx) do
    Boards.update_card(
      fresh(card),
      Map.merge(%{"completed" => true, "evidence" => "every subcard merged"}, attrs),
      actor: ctx.builder
    )
  end

  defp accept(card, ctx), do: Verified.decide(fresh(card), "accept", %{}, ctx.checker, ctx.owner)

  defp merge_jobs(card),
    do: Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == "merge"))

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  test "the sub-board ships by pull request too", ctx do
    assert Board.ships_by_pr?(Repo.get!(Board, ctx.sub.id))
  end

  describe "epic?/1" do
    test "a card with a live subcard is one; one with none, or only archived, isn't", ctx do
      assert Verified.epic?(ctx.epic)
      refute Verified.epic?(ctx.sub_card)

      {:ok, _} = Boards.archive_card(ctx.sub_card)
      refute Verified.epic?(ctx.epic)
    end

    test "an archived sub-board makes no epic", ctx do
      ctx.sub |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()
      refute Verified.epic?(ctx.epic)
    end
  end

  describe "an agent completing an epic" do
    test "with its subcards merged, is submitted without a PR of its own", ctx do
      merged(ctx.sub_card)

      assert {:ok, %{verify_state: "pending", evidence_pr: nil}} = submit(ctx.epic, %{}, ctx)
    end

    test "still needs some evidence", ctx do
      merged(ctx.sub_card)

      assert {:error, cs} =
               Boards.update_card(fresh(ctx.epic), %{"completed" => true}, actor: ctx.builder)

      assert %{evidence: [_]} = errors_on(cs)
      refute fresh(ctx.epic).verify_state
    end

    test "is still refused while a subcard is open", ctx do
      assert {:error, cs} = submit(ctx.epic, %{}, ctx)
      assert %{completed: [message]} = errors_on(cs)
      assert message =~ "Part one"
    end

    test "a card with no subcards still needs its PR, and the refusal says epics don't", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Plain"})

      assert {:error, cs} = submit(card, %{}, ctx)
      assert %{evidence_pr: [message]} = errors_on(cs)
      assert message =~ "--pr"
      assert message =~ "an epic"
    end

    test "whose subcards are all archived is no epic, and needs its PR", ctx do
      {:ok, _} = Boards.archive_card(ctx.sub_card)

      assert {:error, cs} = submit(ctx.epic, %{}, ctx)
      assert %{evidence_pr: [_]} = errors_on(cs)
    end
  end

  describe "accepting an epic" do
    test "with no PR completes it, in Done, with no merge job", ctx do
      merged(ctx.sub_card)
      {:ok, _} = submit(ctx.epic, %{}, ctx)

      assert Verified.nothing_to_merge?(fresh(ctx.epic))
      assert {:ok, card} = accept(ctx.epic, ctx)
      assert card.completed
      assert card.verify_state == "accepted"
      assert card.column_id == ctx.done.id
      refute "review" in card.flags
      assert merge_jobs(card) == []
      assert Enum.any?(comments(card), &(&1 =~ "**Accepted**" and &1 =~ "nothing to merge"))
    end

    test "naming a PR a subcard already merged completes it without merging (#1796)", ctx do
      merged(ctx.sub_card)
      # The same pull request, written a little differently.
      {:ok, _} =
        submit(
          ctx.epic,
          %{"evidence_pr" => String.replace(@sub_pr, "acme", "Acme") <> "/#top"},
          ctx
        )

      assert {:ok, card} = accept(ctx.epic, ctx)
      assert card.completed
      assert card.verify_state == "accepted"
      assert merge_jobs(card) == []
    end

    test "naming a PR of its own still merges it", ctx do
      merged(ctx.sub_card)
      {:ok, _} = submit(ctx.epic, %{"evidence_pr" => @own_pr}, ctx)

      refute Verified.nothing_to_merge?(fresh(ctx.epic))
      assert {:ok, card} = accept(ctx.epic, ctx)
      refute card.completed
      assert card.verify_state == "merging"
      assert Enum.any?(comments(card), &(&1 =~ "merging #{@own_pr}"))
    end

    test "naming a subcard's PR that isn't accepted yet still merges it", ctx do
      merged(ctx.sub_card)
      # A second subcard submitted on that PR, but not yet accepted and merged.
      other = card_fixture(ctx.sub_card |> Repo.preload(:column) |> Map.fetch!(:column))

      Repo.update_all(from(c in Card, where: c.id == ^other.id),
        set: [verify_state: "pending", evidence_pr: @own_pr]
      )

      {:ok, _} = submit(ctx.epic, %{"evidence_pr" => @own_pr}, ctx)
      assert {:ok, %{verify_state: "merging"}} = accept(ctx.epic, ctx)
    end

    test "a card with no subcards still merges its PR", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Plain"})
      {:ok, _} = submit(card, %{"evidence_pr" => @own_pr}, ctx)

      refute Verified.nothing_to_merge?(fresh(card))
      assert {:ok, %{verify_state: "merging", completed: false}} = accept(card, ctx)
    end
  end

  describe "what the builder and the verifier are told" do
    test "an epic's ship instructions say to complete it without --pr", ctx do
      text = Verified.ship_instructions(fresh(ctx.epic))
      assert text =~ "This card is an epic"
      assert text =~ "complete the epic without `--pr`"
      assert text =~ "slipdock done #{ctx.epic.id} --evidence"
      assert text =~ "nothing to merge"
    end

    test "a card with no subcards isn't told about epics", ctx do
      refute Verified.ship_instructions(fresh(ctx.sub_card)) =~ "epic"
    end

    test "the verify prompt for an epic with no PR checks its subcards and main's build", ctx do
      merged(ctx.sub_card)
      {:ok, card} = submit(ctx.epic, %{}, ctx)

      prompt = Verified.verify_prompt(card, Repo.get!(Board, card.board_id))
      assert prompt =~ "epic with no pull request of its own"
      assert prompt =~ "Every subcard is accepted and merged"
      assert prompt =~ "gh run list --branch"
      refute prompt =~ "gh pr view"
    end

    test "the verify prompt for an epic naming its own PR checks that PR", ctx do
      merged(ctx.sub_card)
      {:ok, card} = submit(ctx.epic, %{"evidence_pr" => @own_pr}, ctx)

      prompt = Verified.verify_prompt(card, Repo.get!(Board, card.board_id))
      assert prompt =~ "gh pr view #{@own_pr}"
      refute prompt =~ "epic with no pull request"
    end
  end
end
