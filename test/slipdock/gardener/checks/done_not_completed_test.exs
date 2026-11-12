defmodule Slipdock.Gardener.Checks.DoneNotCompletedTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Boards
  alias Slipdock.Gardener.Checks.DoneNotCompleted

  setup do
    board = board_fixture()
    [_backlog, todo, _doing, done] = board.columns
    %{board: board, todo: todo, done: done}
  end

  defp in_done_open(todo, done, attrs \\ %{}) do
    card = card_fixture(todo, attrs)
    :ok = Boards.Cards.move_card(card.id, done.id)

    {:ok, card} =
      Boards.Cards.update_card(Boards.Cards.get_card!(card.id), %{"completed" => false})

    card
  end

  test "a card in Done that isn't complete is completed", %{board: board, todo: todo, done: done} do
    card = in_done_open(todo, done, %{"title" => "Shipped"})

    assert [finding] = find(DoneNotCompleted, board)
    assert finding.proposal == [%{"op" => "complete", "card" => card.id}]
    assert finding.explanation == "“Shipped” is in “Done” but was never marked complete"
  end

  test "a complete card in Done, and an open one elsewhere, are not", %{
    board: board,
    todo: todo,
    done: done
  } do
    card_fixture(todo)
    c = card_fixture(todo)
    :ok = Boards.Cards.move_card(c.id, done.id)
    assert Boards.Cards.get_card!(c.id).completed
    assert find(DoneNotCompleted, board) == []
  end

  test "an epic in Done with work still open beneath it is left alone", %{
    board: board,
    todo: todo,
    done: done
  } do
    epic = in_done_open(todo, done)
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    card_fixture(hd(Boards.get_board!(sub.id).columns))

    assert find(DoneNotCompleted, board) == []
  end
end
