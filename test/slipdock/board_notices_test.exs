defmodule Slipdock.BoardNoticesTest do
  @moduledoc """
  `{:boards_changed}` reaches the people a board concerns and nobody else
  (#386): a change goes out on its tree's root topic, reach that grows goes to
  the person, and a delete or revoke still reaches whoever could see it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Access, Accounts, Boards}

  setup do
    owner = user_fixture("owner@example.com")
    other = user_fixture("other@example.com")
    board = board_fixture(%{"name" => "Mine"}, owner: owner)
    %{owner: owner, other: other, board: board}
  end

  # Subscribes this test process as the page would, and returns the roots.
  defp listen(user), do: Boards.subscribe_all(user)

  describe "a change to a board" do
    test "reaches its owner, and not somebody it was never shared with", ctx do
      listen(ctx.owner)
      {:ok, _} = Boards.update_board(ctx.board, %{"description" => "changed"})
      assert_receive {:boards_changed}

      theirs = board_fixture(%{"name" => "Theirs"}, owner: ctx.other)
      {:ok, _} = Boards.update_board(theirs, %{"description" => "changed"})
      refute_receive {:boards_changed}, 50
    end

    test "inside a sub-board reaches whoever listens on the root", ctx do
      card = card_fixture(hd(ctx.board.columns), %{"title" => "Epic"})
      {:ok, t} = Boards.find_template("Simple")
      {:ok, sub} = sub_board(card, t)
      sub = Boards.get_board!(sub.id)

      listen(ctx.owner)
      card_fixture(hd(sub.columns), %{"title" => "Task"})
      assert_receive {:boards_changed}
    end
  end

  describe "a board deleted" do
    test "still reaches the owner and the people it was shared with", ctx do
      {:ok, _} = Access.grant(ctx.board, ctx.other, "read", ctx.owner)
      assert ctx.board.id in listen(ctx.other)

      {:ok, _} = Boards.delete_board(ctx.board)
      assert_receive {:boards_changed}
    end

    test "as a sub-board reaches the tree it was in", ctx do
      card = card_fixture(hd(ctx.board.columns), %{"title" => "Epic"})
      {:ok, t} = Boards.find_template("Simple")
      {:ok, sub} = sub_board(card, t)

      listen(ctx.owner)
      {:ok, _} = Boards.delete_board(Boards.get_board!(sub.id))
      assert_receive {:boards_changed}
    end
  end

  test "a new board tells its owner, who is not listening on it yet", ctx do
    roots = listen(ctx.owner)
    stranger = user_fixture("stranger@example.com")

    new = board_fixture(%{"name" => "New"}, owner: ctx.owner)
    refute new.id in roots
    assert_receive {:boards_changed}

    assert new.id in Boards.resubscribe_all(ctx.owner, roots)
    {:ok, _} = Boards.update_board(new, %{"description" => "changed"})
    assert_receive {:boards_changed}

    # And it is nobody else's business.
    board_fixture(%{"name" => "Another"}, owner: stranger)
    refute_receive {:boards_changed}, 50
  end

  test "a grant tells the grantee; once revoked and reloaded they hear no more", ctx do
    roots = listen(ctx.other)
    refute ctx.board.id in roots

    {:ok, grant} = Access.grant(ctx.board, ctx.other, "read", ctx.owner)
    assert_receive {:boards_changed}
    roots = Boards.resubscribe_all(ctx.other, roots)
    assert ctx.board.id in roots

    {:ok, _} = Access.revoke(grant)
    assert_receive {:boards_changed}
    flush()

    roots = Boards.resubscribe_all(ctx.other, roots)
    refute ctx.board.id in roots
    {:ok, _} = Boards.update_board(ctx.board, %{"description" => "changed"})
    refute_receive {:boards_changed}, 50
  end

  test "a grant to a group tells its members, and so does joining one", ctx do
    member = user_fixture("member@example.com")
    joiner = user_fixture("joiner@example.com")
    {:ok, group} = Accounts.create_group(ctx.owner, %{"name" => "Crew"})
    {:ok, group} = Accounts.add_group_member(group, member.email)

    listen(member)
    {:ok, _} = Access.grant(ctx.board, group, "read", ctx.owner)
    assert_receive {:boards_changed}

    flush()
    roots = listen(joiner)
    refute ctx.board.id in roots
    {:ok, _} = Accounts.add_group_member(group, joiner.email)
    assert_receive {:boards_changed}
    assert ctx.board.id in Boards.resubscribe_all(joiner, roots)
  end

  test "reordering boards tells only the person reordering", ctx do
    {:ok, _} = Access.grant(ctx.board, ctx.other, "read", ctx.owner)
    listen(ctx.other)
    flush()

    Boards.reorder_boards(ctx.owner, [ctx.board.id])
    refute_receive {:boards_changed}, 50

    Boards.reorder_boards(ctx.other, [ctx.board.id])
    assert_receive {:boards_changed}
  end

  describe "Access.notice_root_ids/1" do
    test "takes in owned, archived, card-shared and page-shared trees, as roots", ctx do
      card = card_fixture(hd(ctx.board.columns), %{"title" => "Epic"})
      {:ok, t} = Boards.find_template("Simple")
      {:ok, sub} = sub_board(card, t)
      {:ok, _} = Boards.archive_board(ctx.board)
      assert Access.notice_root_ids(ctx.owner) == [ctx.board.id]

      shared_card_board = board_fixture(%{"name" => "Cards"}, owner: ctx.owner)
      shared_card = card_fixture(hd(shared_card_board.columns), %{"title" => "One"})
      page_board = board_fixture(%{"name" => "Pages"}, owner: ctx.owner)
      page = page_fixture(page_board, %{}, user: ctx.owner)
      # A card on a sub-board: the notice still goes to the root.
      deep = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Deep"})

      assert Access.notice_root_ids(ctx.other) == []

      {:ok, _} = Access.grant(shared_card, ctx.other, "read", ctx.owner)
      {:ok, _} = Access.grant(page, ctx.other, "read", ctx.owner)
      {:ok, _} = Access.grant(deep, ctx.other, "read", ctx.owner)

      assert Enum.sort(Access.notice_root_ids(ctx.other)) ==
               Enum.sort([ctx.board.id, shared_card_board.id, page_board.id])
    end
  end

  defp flush do
    receive do
      {:boards_changed} -> flush()
    after
      0 -> :ok
    end
  end
end
