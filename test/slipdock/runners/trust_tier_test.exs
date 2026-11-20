defmodule Slipdock.Runners.TrustTierTest do
  @moduledoc """
  The trust tier a job's prompt carries (#3516): the least-trusted author of
  the card's title, description and bar, the rule that queued it, its
  rejection and its handoff, as `owner`, `member` or `anyone`.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.TrustTier

  setup do
    owner = user_fixture("tier-owner@example.com")
    board = board_fixture(%{"name" => "Tiers"}, owner: owner)
    member = user_fixture("tier-member@example.com")
    grant(%{level: "write", user_id: member.id, board_id: board.id})
    %{owner: owner, member: member, board: board, todo: Enum.at(board.columns, 1)}
  end

  defp grant(attrs), do: Repo.insert!(Grant.changeset(%Grant{}, attrs))

  defp card_by(ctx, user, attrs \\ %{}) do
    {:ok, card} =
      Boards.Cards.create_card(ctx.todo, Map.merge(%{"title" => "Do it"}, attrs),
        by: user,
        via: "web"
      )

    card
  end

  defp tier(card, attrs \\ %{}) do
    {:ok, job} = Runners.queue(card, Map.merge(%{pool: "p", kind: "work", prompt: "go"}, attrs))
    TrustTier.of(job)
  end

  test "a card the owner wrote: owner", ctx do
    card = card_by(ctx, ctx.owner, %{"description" => "Mine"})
    assert card.text_by == [ctx.owner.id]
    assert tier(card) == "owner"
  end

  test "a card the server made, with no writer: owner", ctx do
    {:ok, card} = Boards.Cards.create_card(ctx.todo, %{"title" => "Made"})
    assert card.text_by == []
    assert tier(card) == "owner"
  end

  test "a member's edit to the owner's card: member", ctx do
    card = card_by(ctx, ctx.owner)

    {:ok, card} =
      Boards.Cards.update_card(card, %{"description" => "Theirs"}, by: ctx.member, via: "web")

    assert card.text_by == [ctx.owner.id, ctx.member.id]
    assert tier(card) == "member"
  end

  test "an edit that leaves the text alone doesn't count its writer", ctx do
    card = card_by(ctx, ctx.owner)

    {:ok, card} =
      Boards.Cards.update_card(card, %{"priority" => "high"}, by: ctx.member, via: "web")

    assert card.text_by == [ctx.owner.id]
    assert tier(card) == "owner"
  end

  test "a writer who may only read now, or whose access has gone: anyone", ctx do
    for after_level <- ["read", nil] do
      writer = user_fixture()
      g = grant(%{level: "write", user_id: writer.id, board_id: ctx.board.id})
      card = card_by(ctx, writer)
      Repo.delete!(g)
      if after_level, do: grant(%{level: after_level, user_id: writer.id, board_id: ctx.board.id})
      assert tier(card) == "anyone", inspect(after_level)
    end
  end

  test "someone who may comment counts as a member", ctx do
    commenter = user_fixture()
    grant(%{level: "comment", user_id: commenter.id, board_id: ctx.board.id})
    card = card_by(ctx, ctx.owner)
    {:ok, _} = Boards.Handoffs.leave_handoff(card, commenter, %{next_step: "Look", via: "ui"})
    assert tier(card) == "member"
  end

  test "a mail sent on a permitted sender's behalf: anyone", ctx do
    {:ok, card} =
      Boards.Cards.create_card(ctx.todo, %{"title" => "From mail"},
        by: ctx.owner,
        via: "email",
        outside_author: true
      )

    assert card.text_by == [0]
    assert tier(card) == "anyone"
  end

  test "a card from before the writers were kept falls back to its creator", ctx do
    card = card_by(ctx, ctx.member)
    Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [text_by: nil])
    card = Repo.get!(Card, card.id)
    assert tier(card) == "member"

    {:ok, card} =
      Boards.Cards.update_card(card, %{"title" => "Renamed"}, by: ctx.owner, via: "web")

    assert card.text_by == [ctx.member.id, ctx.owner.id]
  end

  test "the handoff's author counts, but not for a verify job", ctx do
    card = card_by(ctx, ctx.owner)

    {:ok, _} =
      Boards.Handoffs.leave_handoff(card, ctx.member, %{next_step: "Then this", via: "ui"})

    assert tier(card) == "member"
    assert tier(card, %{kind: "verify"}) == "owner"
  end

  test "the rule that queued the job counts its author", ctx do
    card = card_by(ctx, ctx.owner)

    rule =
      Repo.insert!(%Slipdock.Automations.Rule{
        name: "Send it",
        source: "when a card is added, send it to a runner",
        spec: %{},
        board_id: ctx.board.id,
        created_by_id: ctx.member.id
      })

    assert tier(card, %{rule: rule}) == "member"
  end

  test "a rejection by a member counts", ctx do
    card = card_by(ctx, ctx.owner)

    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [verify_state: "rejected", verify_note: "No", verify_by: %{"user_id" => ctx.member.id}]
    )

    assert tier(Repo.get!(Card, card.id)) == "member"
  end

  test "a merge job is the server's own: owner", ctx do
    card = card_by(ctx, ctx.member)
    assert TrustTier.of(%Runners.Job{kind: "merge", card_id: card.id}) == "owner"
  end
end
