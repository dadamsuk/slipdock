defmodule Slipdock.AccessTest do
  use Slipdock.DataCase, async: true

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

  test "owner and stranger", ctx do
    assert Access.board_permission(ctx.owner, ctx.board) == :owner
    assert Access.board_permission(ctx.other, ctx.board) == :none
    assert Access.card_permission(ctx.other, ctx.card) == :none
    assert Access.board_permission(nil, ctx.board) == :none
  end

  test "a board with no owner is nobody's, not everybody's", ctx do
    ownerless = %{ctx.board | owner_id: nil}
    assert Access.board_permission(ctx.other, ownerless) == :none
    assert Access.board_permission(ctx.owner, ownerless) == :none
    assert Access.visible_users_for(ownerless) == []
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

  # inserted_at is to the second, so rows made in the same one need the id to
  # keep their order. Giving the earlier row the later one's time also moves it
  # to the end of the table, so without the tiebreaker it comes back second.
  defp same_second(schema, earlier, later) do
    Repo.update_all(from(r in schema, where: r.id == ^earlier.id),
      set: [inserted_at: later.inserted_at]
    )
  end

  test "boards made in the same second are listed in the order they were made", ctx do
    first = board_fixture(%{"name" => "First"}, owner: ctx.owner)
    second = board_fixture(%{"name" => "Second"}, owner: ctx.owner)
    same_second(Slipdock.Boards.Board, first, second)

    names = ctx.owner |> Access.list_boards() |> Enum.map(& &1.name)
    assert Enum.filter(names, &(&1 in ["First", "Second"])) == ["First", "Second"]
  end

  test "a reader's grants made in the same second come back in id order", ctx do
    {:ok, group} = Accounts.create_group(ctx.owner, %{"name" => "Crew"})
    {:ok, _} = Accounts.add_group_member(group, ctx.other.email)

    # Either one stored after the other but with the lower id, so the table's
    # own order and the id disagree, and only the tiebreaker gets both right.
    for renumber <- [:direct, :via_group] do
      board = board_fixture(%{"name" => "Shared #{renumber}"}, owner: ctx.owner)
      {:ok, direct} = Access.grant(board, ctx.other, "read", ctx.owner)
      {:ok, via_group} = Access.grant(board, group, "write", ctx.owner)
      moved = if renumber == :direct, do: direct, else: via_group

      Repo.update_all(from(g in Slipdock.Access.Grant, where: g.id == ^moved.id),
        set: [id: -moved.id, inserted_at: direct.inserted_at]
      )

      ids = Enum.map(Access.incoming_grants(ctx.other, board), & &1.id)
      assert ids == Enum.sort(ids)
      assert length(ids) == 2 and -moved.id in ids
    end
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
