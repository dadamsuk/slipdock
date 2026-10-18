defmodule Slipdock.Gardener.Checks.EpicDoneTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Boards
  alias Slipdock.Gardener
  alias Slipdock.Gardener.Checks.EpicDone

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, _doing, done] = board.columns
    {:ok, t} = Boards.find_template(nil, "Simple")
    epic = card_fixture(todo, %{"title" => "Epic"})
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    %{owner: owner, board: board, done: done, epic: epic, sub: sub}
  end

  test "an open epic with every leaf done is completed and moved to done", %{
    board: board,
    epic: epic,
    sub: sub,
    done: done,
    owner: owner
  } do
    card_fixture(hd(sub.columns), %{"completed" => true})
    card_fixture(hd(sub.columns), %{"completed" => true})

    assert [finding] = find(EpicDone, board)
    assert finding.subject == %{"cards" => [epic.id]}

    assert finding.proposal == [
             %{"op" => "complete", "card" => epic.id},
             %{"op" => "move", "card" => epic.id, "column" => done.id}
           ]

    assert finding.explanation =~ "has all 2 of its subcards done"

    {:ok, _} = Gardener.run(board, only: ["epic_done"])
    [s] = Gardener.list_open(board)
    {:ok, _} = Gardener.apply(s, owner)
    epic = Boards.get_card!(epic.id)
    assert epic.completed
    assert epic.column_id == done.id
  end

  test "an epic with a leaf still open is not", %{board: board, sub: sub} do
    card_fixture(hd(sub.columns), %{"completed" => true})
    card_fixture(hd(sub.columns))
    assert find(EpicDone, board) == []
  end

  test "an epic already complete, or a card with no subcards, is not", %{
    board: board,
    epic: epic,
    sub: sub
  } do
    card_fixture(hd(sub.columns), %{"completed" => true})
    {:ok, _} = Boards.update_card(Boards.get_card!(epic.id), %{"completed" => true})
    card_fixture(hd(board.columns), %{"completed" => true})
    assert find(EpicDone, board) == []
  end

  test "already in done, it is only completed", %{board: board, epic: epic, sub: sub, done: done} do
    card_fixture(hd(sub.columns), %{"completed" => true})
    :ok = Boards.move_card(epic.id, done.id)
    {:ok, _} = Boards.update_card(Boards.get_card!(epic.id), %{"completed" => false})

    assert [%{proposal: [%{"op" => "complete"}]}] = find(EpicDone, board)
  end

  test "an empty sub-board has nothing done: not this check", %{board: board} do
    assert find(EpicDone, board) == []
  end
end
