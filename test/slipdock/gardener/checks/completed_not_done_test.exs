defmodule Slipdock.Gardener.Checks.CompletedNotDoneTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Boards
  alias Slipdock.Gardener.Checks.CompletedNotDone

  setup do
    board = board_fixture()
    [_backlog, todo, doing, done] = board.columns
    %{board: board, todo: todo, doing: doing, done: done}
  end

  test "a complete card outside Done is moved there", %{board: board, doing: doing, done: done} do
    card = card_fixture(doing, %{"title" => "Finished", "completed" => true})

    assert [finding] = find(CompletedNotDone, board)
    assert finding.proposal == [%{"op" => "move", "card" => card.id, "column" => done.id}]
    assert finding.explanation == "“Finished” is complete but still in “In Progress”, not “Done”"
  end

  test "an open card, or a complete one in Done, is not", %{board: board, todo: todo, done: done} do
    card_fixture(todo)
    c = card_fixture(todo)
    :ok = Boards.move_card(c.id, done.id)
    assert find(CompletedNotDone, board) == []
  end

  test "a complete card in a dropped list is where it belongs", %{board: board} do
    {:ok, dropped} = Boards.create_column(board, %{"name" => "Won't do", "category" => "dropped"})
    card_fixture(dropped, %{"completed" => true})
    assert find(CompletedNotDone, board) == []
  end

  test "a board with no done list has nowhere to move it" do
    board = board_fixture(%{}, [])
    board = Boards.get_board!(board.id)

    for col <- board.columns,
        col.category == "done",
        do: {:ok, _} = Boards.update_column(col, %{"category" => "", "name" => "Shelf"})

    card_fixture(hd(board.columns), %{"completed" => true})
    assert find(CompletedNotDone, board) == []
  end
end
