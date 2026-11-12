defmodule Slipdock.ReleaseModePortableTest do
  @moduledoc "A root board's release settings (#2834) go out with a portable export and come back in."
  # Sync, as the other import tests: imports derive board codes.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup do
    user = user_fixture("release-port-#{System.unique_integer([:positive])}@example.com")
    %{user: user, board: board_fixture(%{"name" => "Rel", "code" => unique_code()}, owner: user)}
  end

  test "a root's settings come back; a bad mode or cap takes the default", %{
    user: user,
    board: board
  } do
    {:ok, board} =
      Boards.update_board(board, %{"release_mode" => "batched", "release_age_cap_hours" => 36})

    document = Slipdock.Portable.export(user, boards: [board])
    [tree] = document.boards
    assert {tree.root.release_mode, tree.root.release_age_cap_hours} == {"batched", 36}

    {:ok, report} = Slipdock.Portable.import(user, Jason.encode!(document))
    again = Boards.get_board!(hd(report.boards).id)
    assert {again.release_mode, again.release_age_cap_hours} == {"batched", 36}

    odd =
      update_in(document.boards, fn [t] ->
        [update_in(t.root, &Map.merge(&1, %{release_mode: "weekly", release_age_cap_hours: 0}))]
      end)

    {:ok, report} = Slipdock.Portable.import(user, Jason.encode!(odd))
    again = Boards.get_board!(hd(report.boards).id)
    assert {again.release_mode, again.release_age_cap_hours} == {"on_merge", nil}
  end
end
