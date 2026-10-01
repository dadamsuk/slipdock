defmodule Slipdock.BoardArchiveTest do
  @moduledoc """
  Archiving a whole board, and the order one person lists boards in.

  The two belong together: both are about what the board index shows, and
  neither is allowed to change anything on the boards themselves.
  """
  use Slipdock.DataCase, async: false

  import Ecto.Query

  alias Slipdock.{Access, Boards}
  alias Slipdock.Boards.Board
  import Slipdock.Fixtures

  describe "archiving" do
    test "takes the board off the listings without losing anything on it" do
      user = user_fixture()
      board = board_fixture(%{"name" => "Old work"}, owner: user)
      card = card_fixture(hd(board.columns), %{"title" => "Still here"})

      {:ok, board} = Boards.archive_board(board)
      assert Board.archived?(board)

      refute board.id in Enum.map(Access.list_boards(user), & &1.id)
      assert board.id in Enum.map(Access.list_boards(user, archived: true), & &1.id)
      assert board.id in Enum.map(Access.list_boards(user, archived: :all), & &1.id)

      # Everything on it is still there, and still readable.
      assert Boards.get_card!(card.id).title == "Still here"
      assert board.id in Access.readable_board_ids(user)
      assert Access.board_permission(user, board) == :owner
    end

    test "restoring puts it back" do
      user = user_fixture()
      board = board_fixture(%{}, owner: user)

      {:ok, board} = Boards.archive_board(board)
      {:ok, board} = Boards.unarchive_board(board)

      refute Board.archived?(board)
      assert board.id in Enum.map(Access.list_boards(user), & &1.id)
    end

    test "is recorded in the board's activity" do
      board = board_fixture(%{"name" => "Noted"})
      {:ok, board} = Boards.archive_board(board)
      {:ok, board} = Boards.unarchive_board(board)

      messages = board.id |> Boards.list_activities() |> Enum.map(& &1.message)
      assert "archived board “Noted”" in messages
      assert "restored board “Noted”" in messages
    end

    test "archiving twice is not an error, and neither is restoring a live board" do
      board = board_fixture()
      {:ok, archived} = Boards.archive_board(board)
      assert {:ok, ^archived} = Boards.archive_board(archived)
      {:ok, live} = Boards.unarchive_board(archived)
      assert {:ok, ^live} = Boards.unarchive_board(live)
    end

    test "a sub-board cannot be archived on its own" do
      board = board_fixture()
      card = card_fixture(hd(board.columns))
      {:ok, template} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(card, template)

      assert {:error, :sub_board} = Boards.archive_board(sub)
    end
  end

  describe "the order boards are listed in" do
    setup do
      user = user_fixture()
      a = board_fixture(%{"name" => "Alpha"}, owner: user)
      b = board_fixture(%{"name" => "Bravo"}, owner: user)
      c = board_fixture(%{"name" => "Charlie"}, owner: user)
      %{user: user, a: a, b: b, c: c}
    end

    defp names(user, sort \\ "manual") do
      user
      |> Access.list_boards(activity: true)
      |> Boards.sort_boards(sort)
      |> Enum.map(& &1.name)
    end

    test "starts as the order they were created in", ctx do
      assert names(ctx.user) == ["Alpha", "Bravo", "Charlie"]
    end

    test "is whatever the person sets", ctx do
      :ok = Boards.reorder_boards(ctx.user, [ctx.c.id, ctx.a.id, ctx.b.id])
      assert names(ctx.user) == ["Charlie", "Alpha", "Bravo"]
    end

    test "belongs to the person, not the board", ctx do
      other = user_fixture("other@example.com")
      shared = board_fixture(%{"name" => "Shared"}, owner: other)
      {:ok, _} = Access.grant(shared, ctx.user, "read", other)

      :ok = Boards.reorder_boards(ctx.user, [shared.id, ctx.a.id, ctx.b.id, ctx.c.id])

      assert names(ctx.user) == ["Shared", "Alpha", "Bravo", "Charlie"]
      # The owner of the shared board sees it exactly where they left it.
      assert names(other) == ["Shared"]
    end

    test "a board left out of the order falls to the end", ctx do
      :ok = Boards.reorder_boards(ctx.user, [ctx.c.id, ctx.b.id])
      assert names(ctx.user) == ["Charlie", "Bravo", "Alpha"]
    end

    test "a board made later goes to the end", ctx do
      :ok = Boards.reorder_boards(ctx.user, [ctx.c.id, ctx.b.id, ctx.a.id])
      board_fixture(%{"name" => "Delta"}, owner: ctx.user)
      assert names(ctx.user) == ["Charlie", "Bravo", "Alpha", "Delta"]
    end

    test "nudging moves one board a place, and stops at the ends", ctx do
      boards = ctx.user |> Access.list_boards() |> Boards.sort_boards("manual")

      :ok = Boards.nudge_board(ctx.user, ctx.c, :up, boards)
      assert names(ctx.user) == ["Alpha", "Charlie", "Bravo"]

      boards = ctx.user |> Access.list_boards() |> Boards.sort_boards("manual")
      :ok = Boards.nudge_board(ctx.user, ctx.a, :up, boards)
      assert names(ctx.user) == ["Alpha", "Charlie", "Bravo"]
    end

    test "placing a board drops it in front of another", ctx do
      boards = ctx.user |> Access.list_boards() |> Boards.sort_boards("manual")
      :ok = Boards.place_board(ctx.user, ctx.c, ctx.a.id, boards)
      assert names(ctx.user) == ["Charlie", "Alpha", "Bravo"]

      boards = ctx.user |> Access.list_boards() |> Boards.sort_boards("manual")
      :ok = Boards.place_board(ctx.user, ctx.c, nil, boards)
      assert names(ctx.user) == ["Alpha", "Bravo", "Charlie"]
    end

    test "the other sorts", ctx do
      :ok = Boards.reorder_boards(ctx.user, [ctx.c.id, ctx.b.id, ctx.a.id])

      assert names(ctx.user, "name") == ["Alpha", "Bravo", "Charlie"]
      assert names(ctx.user, "oldest") == ["Alpha", "Bravo", "Charlie"]
      assert names(ctx.user, "newest") == ["Charlie", "Bravo", "Alpha"]

      card_fixture(hd(ctx.b.columns))
      card_fixture(hd(ctx.b.columns))
      card_fixture(hd(ctx.a.columns))

      assert names(ctx.user, "cards") == ["Bravo", "Alpha", "Charlie"]

      # Timestamps are only accurate to the second, so say plainly when each
      # board was last touched rather than racing the clock.
      touched(ctx.a, -3600)
      touched(ctx.b, -60)
      touched(ctx.c, -86_400)
      assert names(ctx.user, "active") == ["Bravo", "Alpha", "Charlie"]
    end

    # Backdates everything logged on a board, so "recently active" has
    # something to tell the boards apart by.
    defp touched(board, seconds_ago) do
      when? = DateTime.add(DateTime.utc_now(:second), seconds_ago, :second)

      Slipdock.Repo.update_all(
        from(a in Slipdock.Boards.Activity, where: a.board_id == ^board.id),
        set: [inserted_at: when?]
      )
    end

    test "an unknown sort falls back on the person's own order", ctx do
      :ok = Boards.reorder_boards(ctx.user, [ctx.b.id, ctx.c.id, ctx.a.id])
      assert names(ctx.user, "nonsense") == ["Bravo", "Charlie", "Alpha"]
    end
  end
end
