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

  test "a sub-board's document can't set them: it imports and keeps the defaults", %{
    user: user,
    board: board
  } do
    [_backlog, todo | _] = board.columns
    {:ok, template} = Boards.Templates.find_template(nil, "Simple")
    {:ok, _sub} = sub_board(card_fixture(todo, %{"title" => "Epic"}), template)

    document = Slipdock.Portable.export(user, boards: [Boards.get_board!(board.id)])
    [tree] = document.boards
    assert Enum.any?(tree.boards, & &1[:inside_card])

    # A document edited by hand, or from an older export: every sub-board
    # claims to be batched with a cap.
    odd =
      update_in(document.boards, fn [t] ->
        boards =
          Enum.map(t.boards, fn b ->
            if b[:inside_card],
              do: Map.merge(b, %{release_mode: "batched", release_age_cap_hours: 12}),
              else: b
          end)

        [%{t | boards: boards}]
      end)

    assert {:ok, report} = Slipdock.Portable.import(user, Jason.encode!(odd))
    root = Boards.get_board!(hd(report.boards).id)
    assert {root.release_mode, root.release_age_cap_hours} == {"on_merge", nil}

    [sub] =
      Slipdock.Repo.all(Ecto.Query.from(b in Slipdock.Boards.Board, where: b.root_id == ^root.id))

    assert {sub.release_mode, sub.release_age_cap_hours} == {"on_merge", nil}
  end
end
