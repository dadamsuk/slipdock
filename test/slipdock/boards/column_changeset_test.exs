defmodule Slipdock.Boards.ColumnChangesetTest do
  @moduledoc """
  A list's board is set where the list is made, never from the attributes of
  a later change.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias Slipdock.Boards.Column
  alias Slipdock.Repo

  setup do
    user = user_fixture("lists@example.com")
    board = board_fixture(%{"name" => "Here"}, owner: user)
    other = board_fixture(%{"name" => "Elsewhere"}, owner: user)
    %{board: board, other: other, column: hd(board.columns)}
  end

  test "the changeset takes no board from its attributes", ctx do
    for attrs <- [%{"board_id" => ctx.other.id}, %{board_id: ctx.other.id}] do
      changeset = Column.changeset(ctx.column, attrs)

      assert changeset.valid?
      assert changeset.changes == %{}
    end
  end

  test "a list with no board on its struct is refused, whatever the attributes say", ctx do
    changeset = Column.changeset(%Column{}, %{"name" => "Loose", "board_id" => ctx.board.id})

    refute changeset.valid?
    assert %{board_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "update_column/2 leaves the list on its board", ctx do
    assert {:ok, column} =
             Boards.Columns.update_column(ctx.column, %{
               "name" => "Renamed",
               "board_id" => ctx.other.id
             })

    assert column.name == "Renamed"
    assert Repo.get!(Column, ctx.column.id).board_id == ctx.board.id
  end

  test "create_column/2 puts the list on the board it is given", ctx do
    assert {:ok, column} =
             Boards.Columns.create_column(ctx.board, %{
               "name" => "New list",
               "board_id" => ctx.other.id
             })

    assert column.board_id == ctx.board.id
    refute Enum.any?(Boards.get_board!(ctx.other.id).columns, &(&1.name == "New list"))
  end
end
