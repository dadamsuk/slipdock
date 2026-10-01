defmodule Slipdock.AccessTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.{Access, Accounts, Boards}
  alias Slipdock.Swimlanes.Config

  setup do
    owner = user_fixture("owner@example.com")
    other = user_fixture("other@example.com")
    board = board_fixture(%{"name" => "Private"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Secret"})
    %{owner: owner, other: other, board: board, card: card}
  end

  test "owner, stranger, and unclaimed legacy boards", ctx do
    assert Access.board_permission(ctx.owner, ctx.board) == :owner
    assert Access.board_permission(ctx.other, ctx.board) == :none
    assert Access.card_permission(ctx.other, ctx.card) == :none
    assert Access.board_permission(nil, ctx.board) == :none

    {:ok, legacy} = Boards.create_board(%{"name" => "Legacy"})
    assert Access.board_permission(ctx.other, legacy) == :owner
    assert Access.claim_unowned_boards(ctx.owner) == 1
    assert Boards.get_board!(legacy.id).owner_id == ctx.owner.id
  end

  test "board grants to users and groups, and listing", ctx do
    {:ok, grant} = Access.grant(ctx.board, "other@example.com", "read", ctx.owner)
    assert grant.user_id == ctx.other.id
    assert Access.board_permission(ctx.other, ctx.board) == :read
    assert Access.card_permission(ctx.other, ctx.card) == :read
    assert Enum.map(Access.list_boards(ctx.other), & &1.id) == [ctx.board.id]

    # Re-granting updates the level rather than duplicating.
    {:ok, _} = Access.grant(ctx.board, ctx.other, "write", ctx.owner)
    assert [%{level: "write"}] = Access.list_grants(ctx.board)
    assert Access.board_permission(ctx.other, ctx.board) == :write

    {:ok, group} = Accounts.create_group(ctx.owner, %{"name" => "Crew"})
    third = user_fixture("third@example.com")
    {:ok, _} = Accounts.add_group_member(group, third.email)
    {:ok, _} = Access.grant(ctx.board, group, "read", ctx.owner)
    assert Access.board_permission(third, ctx.board) == :read

    [g1, g2] = Access.list_grants(ctx.board)
    {:ok, _} = Access.revoke(g1)
    {:ok, _} = Access.revoke(g2)
    assert Access.board_permission(ctx.other, ctx.board) == :none
    assert Access.board_permission(third, ctx.board) == :none
    assert Access.list_boards(ctx.other) == []
  end

  test "card grants reach only that card, and raise a reader on it", ctx do
    {:ok, _} = Access.grant(ctx.card, ctx.other, "read", ctx.owner)
    assert Access.card_permission(ctx.other, ctx.card) == :read
    assert Access.board_permission(ctx.other, ctx.board) == :none
    assert Enum.map(Access.shared_cards(ctx.other), & &1.id) == [ctx.card.id]

    {:ok, _} = Access.grant(ctx.board, ctx.other, "read", ctx.owner)
    {:ok, _} = Access.grant(ctx.card, ctx.other, "write", ctx.owner)
    assert Access.board_permission(ctx.other, ctx.board) == :read
    assert Access.card_permission(ctx.other, ctx.card) == :write

    # A sub-board inside a granted card inherits the card's permission.
    {:ok, t} = Boards.find_template("Simple")
    {:ok, sub} = Boards.create_sub_board(ctx.card, t)
    assert Access.board_permission(ctx.other, sub) == :write
  end

  test "view grants open the board only through that view", ctx do
    {:ok, view} =
      Boards.create_saved_view(ctx.board, %{
        "name" => "Mine",
        "config" => Config.to_map(%Config{q: "secret"})
      })

    {:ok, _} = Access.grant(view, ctx.other, "read", ctx.owner)
    assert Access.board_permission(ctx.other, ctx.board) == :view
    assert Access.view_permission(ctx.other, view) == :read
    assert Enum.map(Access.accessible_views(ctx.other, ctx.board), & &1.id) == [view.id]
    assert Enum.map(Access.list_boards(ctx.other), & &1.id) == [ctx.board.id]
    # No card access by itself: the LiveView decides what the view shows.
    assert Access.card_permission(ctx.other, ctx.card) == :none
    assert Access.accessible_views(ctx.owner, ctx.board) |> length() == 1

    {:ok, _} = Access.grant(view, ctx.other, "write", ctx.owner)
    assert Access.view_permission(ctx.other, view) == :write
  end

  test "grant validation", ctx do
    assert {:error, msg} = Access.grant(ctx.board, "not an email", "read", ctx.owner)
    assert msg =~ "email"
  end
end
