defmodule Slipdock.Gardener.Checks.StaleInProgressTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Boards
  alias Slipdock.Gardener
  alias Slipdock.Gardener.Checks.StaleInProgress

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    %{owner: owner, board: board, todo: todo, doing: doing}
  end

  test "untouched in progress for 14 days goes back to the ready list", %{
    board: board,
    todo: todo,
    doing: doing
  } do
    card = card_fixture(doing, %{"title" => "Stuck"})
    age(card, 14)

    assert [finding] = find(StaleInProgress, board)
    assert finding.proposal == [%{"op" => "move", "card" => card.id, "column" => todo.id}]
    assert Map.keys(finding.alternatives) |> Enum.sort() == ["ask", "snooze"]
    assert finding.explanation =~ "“Stuck” is in “In Progress” with no activity since"
  end

  test "the threshold: 13 days is not stale, and the board's own days count", %{
    board: board,
    doing: doing
  } do
    card = card_fixture(doing)
    age(card, 13)
    assert find(StaleInProgress, board) == []
    assert [_] = find(StaleInProgress, board, settings: %{"days" => 13})
  end

  test "a recent comment is activity, and names who wrote it", %{
    board: board,
    doing: doing,
    owner: owner
  } do
    card = card_fixture(doing)
    {:ok, _} = Boards.add_comment(card, "Still on it", by: owner)
    age(card, 20)
    assert [finding] = find(StaleInProgress, board)
    assert finding.explanation =~ "; last comment by"

    {:ok, _} = Boards.add_comment(card, "Really", by: owner)
    assert find(StaleInProgress, board) == []
  end

  test "not in a doing list, complete, or snoozed: not stale", %{
    board: board,
    todo: todo,
    doing: doing,
    owner: owner
  } do
    age(card_fixture(todo), 30)
    age(card_fixture(doing, %{"completed" => true}), 30)
    snoozed = card_fixture(doing)
    {:ok, _} = Slipdock.Snooze.snooze(snoozed, owner, Date.add(Date.utc_today(), 3))
    age(snoozed, 30)

    assert find(StaleInProgress, board) == []
  end

  test "snooze is on offer instead", %{board: board, doing: doing, owner: owner} do
    card = card_fixture(doing)
    age(card, 15)
    {:ok, _} = Gardener.run(board, only: ["stale_in_progress"])
    [s] = Gardener.list_open(board)
    {:ok, _} = Gardener.apply(s, owner, choice: "snooze")
    assert Repo.reload!(card).snoozed_until
    assert Repo.reload!(card).column_id == doing.id
  end
end
