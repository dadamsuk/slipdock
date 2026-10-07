defmodule Slipdock.AssigneeScopeTest do
  @moduledoc """
  Who can be put on a card, and who is told about it: only people the person
  doing it can see, who can open the card themselves (`Boards.resolve_assignees/3`
  and the backstop under `Boards.create_card/3` and `Boards.update_card/3`).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Access, Boards, Mentions}
  alias Slipdock.Boards.Card
  alias Slipdock.Wiki.Links

  setup do
    domain = "#{System.unique_integer([:positive])}.example.com"
    owner = user_fixture("owner@#{domain}")
    mate = user_fixture("mate@#{domain}")
    stranger = user_fixture("stranger@#{domain}")
    board = board_fixture(%{}, owner: owner) |> share_fixture(mate)
    card = card_fixture(hd(board.columns), %{"title" => "Mine"})

    %{owner: owner, mate: mate, stranger: stranger, board: board, card: card, domain: domain}
  end

  describe "resolve_assignees/3" do
    test "takes ids, addresses and me, for people who can see the card", ctx do
      assert {:ok, [mate_id, owner_id]} =
               Boards.resolve_assignees(ctx.card, ctx.owner, [
                 ctx.mate.id,
                 "MATE@#{ctx.domain}",
                 "me"
               ])

      assert {mate_id, owner_id} == {ctx.mate.id, ctx.owner.id}
      assert {:ok, [_]} = Boards.resolve_assignees(ctx.board, ctx.owner, [to_string(ctx.mate.id)])
    end

    test "a stranger, a nobody and an unknown id are all the same not found", ctx do
      nobody = "nobody@#{ctx.domain}"

      assert {:error, {:not_found, s}} =
               Boards.resolve_assignees(ctx.card, ctx.owner, ["stranger@#{ctx.domain}"])

      assert s == "stranger@#{ctx.domain}"

      assert {:error, {:not_found, ^nobody}} =
               Boards.resolve_assignees(ctx.card, ctx.owner, [nobody])

      assert {:error, {:not_found, _}} =
               Boards.resolve_assignees(ctx.card, ctx.owner, [ctx.stranger.id])

      assert {:error, {:not_found, _}} =
               Boards.resolve_assignees(ctx.card, ctx.owner, [99_999_999])
    end

    test "somebody visible who can't open this card is refused too", ctx do
      # The owner can see the stranger — they share another board — but the
      # stranger cannot open this one.
      elsewhere = board_fixture(%{}, owner: ctx.owner) |> share_fixture(ctx.stranger)
      assert {:ok, _} = Boards.resolve_assignees(elsewhere, ctx.owner, [ctx.stranger.id])

      assert {:error, {:not_found, _}} =
               Boards.resolve_assignees(ctx.card, ctx.owner, [ctx.stranger.id])
    end
  end

  describe "the backstop under every write" do
    test "somebody who can't open the card is dropped, not assigned", ctx do
      {:ok, card} =
        Boards.update_card(ctx.card, %{"add_assignee_ids" => [ctx.mate.id, ctx.stranger.id]})

      assert Enum.map(Card.assignees(card), & &1.id) == [ctx.mate.id]

      {:ok, card} =
        Boards.create_card(hd(ctx.board.columns), %{
          "title" => "New",
          "assignee_ids" => [ctx.stranger.id, ctx.owner.id]
        })

      assert card.assignee_id == ctx.owner.id
      assert Enum.map(Card.assignees(card), & &1.id) == [ctx.owner.id]
    end

    test "an id that names nobody neither crashes nor half-saves", ctx do
      assert {:ok, card} =
               Boards.update_card(ctx.card, %{
                 "title" => "Renamed",
                 "add_assignee_ids" => [99_999_999]
               })

      assert card.title == "Renamed"
      assert Card.assignees(card) == []
    end

    test "whoever is on the card already stays when the set is edited", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"assignee_ids" => [ctx.mate.id]})
      [grant] = Access.list_grants(ctx.board)
      {:ok, _} = Access.revoke(grant)

      {:ok, card} = Boards.update_card(card, %{"add_assignee_ids" => [ctx.owner.id]})
      assert Enum.map(Card.assignees(card), & &1.id) == [ctx.mate.id, ctx.owner.id]
    end
  end

  describe "mentions" do
    setup ctx do
      # A grant on one sub-board reaches that sub-board and nothing above it.
      {:ok, template} = Boards.find_template("Simple")
      {:ok, sub} = sub_board(ctx.card, template)
      {:ok, _} = Access.grant(Boards.get_board!(sub.id), ctx.stranger, "write", ctx.owner)
      %{sub: Boards.get_board!(sub.id)}
    end

    test "someone with a grant on a sub-board is not a member of the rest of the tree", ctx do
      assert ctx.stranger.id in Enum.map(Links.members(ctx.sub), & &1.id)
      refute ctx.stranger.id in Enum.map(Links.members(ctx.board), & &1.id)
      assert Mentions.people(ctx.board, "@stranger @mate") |> Enum.map(& &1.id) == [ctx.mate.id]
      refute SlipdockWeb.Mention.people(ctx.board) =~ "stranger@"
    end

    test "and is not emailed the card they can't open", ctx do
      {:ok, _} = Boards.add_comment(ctx.card, "@stranger and @mate, look", by: ctx.owner)
      assert_email_sent(to: [{"", "mate@#{ctx.domain}"}])
      refute_email_sent()
    end

    test "an address is not a mention", ctx do
      assert Mentions.find(Links.members(ctx.board), "mate@#{ctx.domain}") == nil
      assert Mentions.find(Links.members(ctx.board), "mate").id == ctx.mate.id
    end
  end
end
