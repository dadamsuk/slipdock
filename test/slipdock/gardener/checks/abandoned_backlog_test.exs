defmodule Slipdock.Gardener.Checks.AbandonedBacklogTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Gardener
  alias Slipdock.Gardener.Checks.AbandonedBacklog
  alias Slipdock.Gardener.Settings

  setup do
    board = board_fixture()
    [backlog, _todo, doing, _done] = board.columns
    %{board: board, backlog: backlog, doing: doing}
  end

  test "is off unless the board turns it on", %{board: board, backlog: backlog} do
    age(card_fixture(backlog), 400)
    {:ok, run} = Gardener.run(board, only: ["abandoned_backlog"])
    assert run.counts["total"] == 0

    {:ok, board} = Settings.put(board, AbandonedBacklog, %{"enabled" => true})
    {:ok, run} = Gardener.run(board, only: ["abandoned_backlog"])
    assert run.counts["total"] == 1
  end

  test "untouched for 180 days in a to-do list is archived", %{board: board, backlog: backlog} do
    card = card_fixture(backlog, %{"title" => "Someday"})
    age(card, 180)

    assert [finding] = find(AbandonedBacklog, board)
    assert finding.proposal == [%{"op" => "archive", "card" => card.id}]
    assert finding.explanation =~ "“Someday” has waited in “Backlog” untouched since"
  end

  test "the threshold: 179 days is not abandoned", %{board: board, backlog: backlog} do
    age(card_fixture(backlog), 179)
    assert find(AbandonedBacklog, board) == []
    assert [_] = find(AbandonedBacklog, board, settings: %{"days" => 100})
  end

  test "not in a to-do list is not this check", %{board: board, doing: doing} do
    age(card_fixture(doing), 400)
    assert find(AbandonedBacklog, board) == []
  end
end
