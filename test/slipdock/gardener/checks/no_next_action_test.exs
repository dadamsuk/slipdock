defmodule Slipdock.Gardener.Checks.NoNextActionTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Boards
  alias Slipdock.Gardener.Checks.NoNextAction

  setup do
    board = board_fixture()
    [_backlog, todo, _doing, _done] = board.columns
    {:ok, t} = Boards.find_template(nil, "Simple")
    epic = card_fixture(todo, %{"title" => "Epic"})
    {:ok, sub} = sub_board(epic, t)
    %{board: board, epic: epic, sub: Boards.get_board!(sub.id)}
  end

  test "an epic with an empty sub-board is flagged for review", %{board: board, epic: epic} do
    assert [finding] = find(NoNextAction, board)

    assert finding.proposal == [
             %{"op" => "flag", "card" => epic.id, "flag" => "review"},
             %{
               "op" => "comment",
               "card" => epic.id,
               "body" => "No next step: none of its subcards is open."
             }
           ]
  end

  test "only dropped subcards is no next step either", %{board: board, sub: sub} do
    {:ok, dropped} = Boards.create_column(sub, %{"name" => "Dropped", "category" => "dropped"})
    card_fixture(dropped)
    assert [_] = find(NoNextAction, board)
  end

  test "an open subcard is a next step", %{board: board, sub: sub} do
    card_fixture(hd(sub.columns))
    assert find(NoNextAction, board) == []
  end

  test "all done is epic_done's, and a review flag already set is left", %{
    board: board,
    sub: sub,
    epic: epic
  } do
    card_fixture(hd(sub.columns), %{"completed" => true})
    assert find(NoNextAction, board) == []

    other = card_fixture(hd(board.columns), %{"flags" => ["review"]})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, _} = sub_board(other, t)
    refute Enum.any?(find(NoNextAction, board), &(&1.subject["cards"] == [other.id]))
    assert epic
  end
end
