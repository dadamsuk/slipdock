defmodule Slipdock.NotShippedPortableTest do
  @moduledoc """
  A board's not-shipped minutes (#2819) go out with a portable export and
  come back in, and an imported board with delivery metrics on counts from
  the import: nothing its copy merged before then fires.
  """
  # Sync, as the other import tests: imports derive board codes.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Portable}

  test "the minutes come back, an odd value takes the default, and the count starts at the import" do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Ships", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{"delivery_metrics" => true, "not_shipped_minutes" => 45})

    document = Portable.export(owner, boards: [board])
    [tree] = document.boards
    assert tree.root.not_shipped_minutes == 45

    {:ok, report} = Portable.import(owner, Jason.encode!(document))
    again = Boards.get_board!(hd(report.boards).id)
    assert again.not_shipped_minutes == 45
    assert DateTime.diff(DateTime.utc_now(), again.delivery_metrics_since) in 0..10

    odd =
      update_in(document.boards, fn [t] ->
        [update_in(t.root, &Map.merge(&1, %{not_shipped_minutes: -5, delivery_metrics: false}))]
      end)

    {:ok, report} = Portable.import(owner, Jason.encode!(odd))
    again = Boards.get_board!(hd(report.boards).id)
    assert again.not_shipped_minutes == 20
    assert again.delivery_metrics_since == nil

    huge =
      update_in(document.boards, fn [t] ->
        [update_in(t.root, &Map.put(&1, :not_shipped_minutes, 999_999))]
      end)

    {:ok, report} = Portable.import(owner, Jason.encode!(huge))
    assert Boards.get_board!(hd(report.boards).id).not_shipped_minutes == 10_080
  end
end
