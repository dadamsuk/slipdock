defmodule Slipdock.VerifiedCirclingTest do
  @moduledoc """
  A card going round in circles (#2047, `Slipdock.Verified.Circling`): the
  second rejection, or one repeating a rule id an earlier one failed, keeps
  the card flagged review, comments with the rounds and the parts each
  failed, raises a warning alert on the root board and emails the owner.
  A first rejection does none of it, an acceptance takes the flag off, and
  the card heads the owner's Waiting on you until then.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Actor, Boards, Repo, Verified, Work}
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Verified.Circling

  setup do
    owner = user_fixture("circling-owner@example.com")
    board = board_fixture(%{"name" => "Circles", "code" => unique_code()}, owner: owner)
    # No rejection-limit wait in the way: that is #1779's, tested beside it.
    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "verify_rejection_limit" => 0})

    [_backlog, _todo, doing, _done] = board.columns

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    %{
      owner: owner,
      board: board,
      doing: doing,
      builder: agent.("builder"),
      checker: agent.("checker")
    }
  end

  defp submit(card, ctx) do
    {:ok, card} =
      Boards.Cards.update_card(
        Repo.get!(Card, card.id),
        %{"completed" => true, "evidence" => "ran it"},
        actor: ctx.builder
      )

    assert card.verify_state == "pending"
    card
  end

  defp reject(card, ctx, reason) do
    {:ok, _} =
      Verified.decide(
        Repo.get!(Card, card.id),
        "reject",
        %{"reason" => reason},
        ctx.checker,
        ctx.owner
      )

    Repo.get!(Card, card.id)
  end

  defp round(card, ctx, reason), do: card |> submit(ctx) |> reject(ctx, reason)

  defp circling_comments(card) do
    Repo.all(
      from(c in Comment,
        where: c.card_id == ^card.id and like(c.body, "**Going round in circles:**%"),
        order_by: [asc: c.id],
        select: c.body
      )
    )
  end

  defp alerts(card), do: Repo.all(from(a in Alert, where: a.card_id == ^card.id))

  describe "the triggers" do
    test "a first rejection doesn't fire: the flag comes off, no comment, alert or email",
         ctx do
      card = card_fixture(ctx.doing, %{"title" => "Once"})
      card = round(card, ctx, "UX-4: the header row is missing")

      assert card.verify_rejections == 1
      refute "review" in card.flags
      assert circling_comments(card) == []
      assert alerts(card) == []
      refute Circling.circling?(card)
      refute_email_sent()
    end

    test "the second rejection, on another rule, flags it review and tells the owner", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Twice"})
      card = round(card, ctx, "bar 2: the empty list case fails")
      card = round(card, ctx, "UX-4: the header row is missing")

      assert card.verify_rejections == 2
      assert card.verify_state == "rejected"
      assert "review" in card.flags
      assert Circling.circling?(card)

      assert [body] = circling_comments(card)
      assert body =~ "rejected 2 times, in 2 rounds of verification"
      assert body =~ "1. bar 2\n2. UX-4"
      assert body =~ "No rule was failed twice."
      assert body =~ "Flagged `review` until it is accepted"

      assert [alert] = alerts(card)
      assert alert.board_id == ctx.board.id
      assert alert.severity == "warning"
      assert alert.title == "Card ##{card.id} is going round in circles: 2 rejections"
      assert alert.body =~ "Rules failed: UX-4"

      assert_email_sent(fn email ->
        assert email.to == [{"", ctx.owner.email}]
        assert email.subject == alert.title
        assert email.text_body =~ "has been rejected 2 times"
      end)
    end

    test "a later rejection repeating a rule id fires again; one that doesn't stays quiet",
         ctx do
      card = card_fixture(ctx.doing, %{"title" => "Again"})
      card = round(card, ctx, "UX-4: the header row is missing")
      card = round(card, ctx, "bar 1: the totals are wrong")
      assert length(circling_comments(card)) == 1

      # The third fails on something new: still flagged, nothing said again.
      card = round(card, ctx, "ARCH-3: writes around Boards")
      assert "review" in card.flags
      assert length(circling_comments(card)) == 1
      assert length(alerts(card)) == 1

      # The fourth fails UX-4 again, which the first did.
      card = round(card, ctx, "UX-4: still no header row")
      assert [_, body] = circling_comments(card)
      assert body =~ "rejected 4 times"
      assert body =~ "1. UX-4\n2. bar 1\n3. ARCH-3\n4. UX-4"
      assert body =~ "UX-4 was failed again."
      assert length(alerts(card)) == 2
    end

    test "repeated_rules/1 and fires?/2 read the rounds" do
      assert Circling.repeated_rules([{"a", ["UX-4", "bar 1"]}, {"b", ["UX-4"]}]) == ["UX-4"]
      assert Circling.repeated_rules([{"a", ["bar 1"]}, {"b", ["bar 1"]}]) == []
      assert Circling.repeated_rules([]) == []
      refute Circling.fires?(1, [{"a", ["UX-4"]}])
      assert Circling.fires?(2, [{"a", ["bar 1"]}, {"b", ["bar 2"]}])
      refute Circling.fires?(3, [{"a", ["UX-4"]}, {"b", ["bar 2"]}, {"c", ["UX-5"]}])
      assert Circling.fires?(3, [{"a", ["UX-4"]}, {"b", ["bar 2"]}, {"c", ["UX-4"]}])
    end
  end

  describe "until it is accepted" do
    test "the flag stays through a resubmission and comes off on acceptance", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Accepted"})
      card = round(card, ctx, "bar 1: one")
      card = round(card, ctx, "bar 2: two")
      card = submit(card, ctx)
      assert "review" in card.flags
      assert Circling.circling?(card)

      {:ok, card} =
        Verified.decide(card, "accept", %{"reason" => "all good now"}, ctx.checker, ctx.owner)

      card = Repo.get!(Card, card.id)
      assert card.completed
      refute "review" in card.flags
      refute Circling.circling?(card)
      assert Work.waiting_on_me(ctx.owner) |> Enum.all?(&(&1.card.id != card.id))
    end
  end

  describe "Waiting on you" do
    test "a circling card comes first, however new, and counts", ctx do
      old = card_fixture(ctx.doing, %{"title" => "Old review"})
      {:ok, _} = Boards.Cards.update_card(old, %{"assignee_ids" => [ctx.owner.id]})
      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, old.id), %{"flags" => ["review"]})

      card = card_fixture(ctx.doing, %{"title" => "Circling"})
      card = round(card, ctx, "bar 1: one")
      assert Enum.map(Work.waiting_on_me(ctx.owner), & &1.card.id) == [old.id]

      card = round(card, ctx, "bar 2: two")

      assert [first | rest] = Work.waiting_on_me(ctx.owner)
      assert first.card.id == card.id
      assert first.reason == "circling"
      assert first.text == "Going round in circles: rejected 2 times"
      assert Enum.map(rest, & &1.card.id) == [old.id]
      assert Work.waiting_count(ctx.owner) == 2
    end

    test "a person taking the flag off takes it off the list", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Seen"})
      card = round(card, ctx, "bar 1: one")
      card = round(card, ctx, "bar 2: two")
      assert hd(Work.waiting_on_me(ctx.owner)).reason == "circling"

      {:ok, _} = Boards.Cards.update_card(card, %{"flags" => []}, actor: Actor.web(ctx.owner))
      assert Work.waiting_on_me(ctx.owner) |> Enum.all?(&(&1.reason != "circling"))
    end
  end
end
