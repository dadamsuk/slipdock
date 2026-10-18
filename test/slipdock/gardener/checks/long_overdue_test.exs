defmodule Slipdock.Gardener.Checks.LongOverdueTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Boards
  alias Slipdock.Gardener
  alias Slipdock.Gardener.Checks.LongOverdue

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, _doing, done] = board.columns
    %{owner: owner, board: board, todo: todo, done: done}
  end

  defp due(days_ago), do: Date.utc_today() |> Date.add(-days_ago) |> Date.to_iso8601()

  test "due more than 30 days ago and open is re-dated a week out", %{board: board, todo: todo} do
    card = card_fixture(todo, %{"title" => "Report", "due_date" => due(31)})
    week = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

    assert [finding] = find(LongOverdue, board)
    assert finding.proposal == [%{"op" => "redate", "card" => card.id, "due" => week}]
    assert Map.keys(finding.alternatives) |> Enum.sort() == ["archive", "snooze"]
    assert finding.explanation =~ "31 days ago"
  end

  test "the threshold: exactly 30 days is not long overdue", %{board: board, todo: todo} do
    card_fixture(todo, %{"due_date" => due(30)})
    assert find(LongOverdue, board) == []
    assert [_] = find(LongOverdue, board, settings: %{"days" => 29})
  end

  test "complete, in Done, or with no date: not overdue", %{board: board, todo: todo, done: done} do
    card_fixture(todo, %{"due_date" => due(60), "completed" => true})
    card_fixture(todo)
    c = card_fixture(todo, %{"due_date" => due(60)})
    :ok = Boards.move_card(c.id, done.id)
    {:ok, _} = Boards.update_card(Boards.get_card!(c.id), %{"completed" => false})
    assert find(LongOverdue, board) == []
  end

  test "re-dating applies and undoes", %{board: board, todo: todo, owner: owner} do
    card = card_fixture(todo, %{"due_date" => due(45)})
    {:ok, _} = Gardener.run(board, only: ["long_overdue"])
    [s] = Gardener.list_open(board)
    {:ok, s} = Gardener.apply(s, owner)
    assert Repo.reload!(card).due_date == Date.add(Date.utc_today(), 7)

    {:ok, _} = Gardener.undo(s, owner)
    assert Repo.reload!(card).due_date == Date.add(Date.utc_today(), -45)
  end

  test "undoing a re-date after somebody else re-dated it refuses", %{
    board: board,
    todo: todo,
    owner: owner
  } do
    card = card_fixture(todo, %{"due_date" => due(45)})
    {:ok, _} = Gardener.run(board, only: ["long_overdue"])
    [s] = Gardener.list_open(board)
    {:ok, s} = Gardener.apply(s, owner)
    {:ok, _} = Boards.update_card(Repo.reload!(card), %{"due_date" => due(-30)})

    assert {:error, msg} = Gardener.undo(s, owner)
    assert msg =~ "has been given another due date since"
  end
end
