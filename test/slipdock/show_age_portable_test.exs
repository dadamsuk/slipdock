defmodule Slipdock.ShowAgePortableTest do
  @moduledoc "A list's show_age setting goes out with a portable export and comes back in."
  # Sync, as the other import tests: imports derive board codes.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Portable}

  test "a list with the age chip off stays off; the rest stay on, and a list without it is on" do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Ages", "code" => unique_code()}, owner: owner)
    [_backlog, todo | _] = board.columns
    {:ok, _} = Boards.update_column(todo, %{"show_age" => false})

    document = Portable.export(owner, boards: [board])
    [tree] = document.boards
    assert Enum.map(tree.root.lists, & &1.show_age) == [true, false, true, true]

    {:ok, report} = Portable.import(owner, Jason.encode!(document))
    again = Boards.get_board!(hd(report.boards).id)
    assert Enum.map(again.columns, & &1.show_age) == [true, false, true, true]

    # A document from before the setting existed: every list shows it.
    stripped =
      update_in(document.boards, fn [t] ->
        [update_in(t.root.lists, fn ls -> Enum.map(ls, &Map.delete(&1, :show_age)) end)]
      end)

    {:ok, report} = Portable.import(owner, Jason.encode!(stripped))
    assert Enum.all?(Boards.get_board!(hd(report.boards).id).columns, & &1.show_age)
  end
end
