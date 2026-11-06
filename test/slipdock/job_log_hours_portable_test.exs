defmodule Slipdock.JobLogHoursPortableTest do
  @moduledoc "A board's two job log times (#1872) go out with a portable export and come back in."
  # Sync, as the other import tests: imports derive board codes.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Portable}

  test "the times come back; missing or out-of-range ones take the defaults" do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Logs", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"job_log_hours" => 6, "failure_log_hours" => 72})

    document = Portable.export(owner, boards: [board])
    [tree] = document.boards
    assert {tree.root.job_log_hours, tree.root.failure_log_hours} == {6, 72}

    {:ok, report} = Portable.import(owner, Jason.encode!(document))
    again = Boards.get_board!(hd(report.boards).id)
    assert {again.job_log_hours, again.failure_log_hours} == {6, 72}

    odd =
      update_in(document.boards, fn [t] ->
        [update_in(t.root, &(&1 |> Map.delete(:job_log_hours) |> Map.put(:failure_log_hours, 0)))]
      end)

    {:ok, report} = Portable.import(owner, Jason.encode!(odd))
    again = Boards.get_board!(hd(report.boards).id)
    assert {again.job_log_hours, again.failure_log_hours} == {24, 168}
  end
end
