defmodule Slipdock.DependenciesTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Card
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config

  setup do
    board = board_fixture()
    [backlog, todo | _] = board.columns
    a = card_fixture(backlog, %{"title" => "A"})
    b = card_fixture(backlog, %{"title" => "B"})
    c = card_fixture(todo, %{"title" => "C"})
    %{board: board, a: a, b: b, c: c}
  end

  test "adding and removing dependencies, blocked state", %{a: a, b: b, c: c, board: board} do
    assert {:ok, a} = Boards.add_dependency(a, b)
    assert Enum.map(a.blocked_by, & &1.title) == ["B"]
    assert Card.blocked?(a)
    assert Enum.map(Boards.get_card!(b.id).blocks, & &1.title) == ["A"]

    # Completing the blocker unblocks the card; archiving it does too.
    {:ok, _} = Boards.toggle_completed(b)
    refute Card.blocked?(Boards.get_card!(a.id))
    {:ok, _} = Boards.toggle_completed(Boards.get_card!(b.id))
    assert Card.blocked?(Boards.get_card!(a.id))
    {:ok, _} = Boards.archive_card(Boards.get_card!(b.id))
    refute Card.blocked?(Boards.get_card!(a.id))
    {:ok, _} = Boards.unarchive_card(Boards.get_card!(b.id))

    assert {:error, "That dependency already exists."} =
             Boards.add_dependency(Boards.get_card!(a.id), b)

    assert {:error, msg} = Boards.add_dependency(a, a)
    assert msg =~ "itself"

    # Board cards carry dependency stubs too.
    board = reload(board)
    loaded_a = board.columns |> Enum.flat_map(& &1.cards) |> Enum.find(&(&1.id == a.id))
    assert [%{title: "B"}] = loaded_a.blocked_by

    {:ok, _} = Boards.remove_dependency(Boards.get_card!(b.id), Boards.get_card!(a.id))
    assert Boards.get_card!(a.id).blocked_by == []
    assert Enum.any?(Boards.list_activities(board.id), &(&1.message =~ "depend on"))

    # Deleting a card removes its links.
    {:ok, _} = Boards.add_dependency(Boards.get_card!(a.id), c)
    {:ok, _} = Boards.delete_card(Boards.get_card!(c.id))
    assert Boards.get_card!(a.id).blocked_by == []
  end

  test "cycles and cross-board links are rejected", %{a: a, b: b, c: c} do
    {:ok, _} = Boards.add_dependency(a, b)
    {:ok, _} = Boards.add_dependency(b, c)
    assert {:error, msg} = Boards.add_dependency(c, a)
    assert msg =~ "circular"

    other = board_fixture()
    foreign = card_fixture(hd(other.columns), %{"title" => "Elsewhere"})
    assert {:error, msg} = Boards.add_dependency(a, foreign)
    assert msg =~ "same board"
  end

  test "search excludes the card itself and given ids", %{board: board, a: a, b: b} do
    assert Enum.map(Boards.search_cards(board.id, "", [a.id]), & &1.title) == ["B", "C"]
    assert Enum.map(Boards.search_cards(board.id, "c", [a.id, b.id]), & &1.title) == ["C"]
  end

  test "swimlane dependencies axis and filter", %{board: board, a: a, b: b} do
    {:ok, _} = Boards.add_dependency(a, b)
    board = reload(board)

    grid = Swimlanes.grid(board, %Config{rows: "dependencies", cols: "none"})

    assert Enum.map(grid.rows, &{&1.label, Enum.map(hd(&1.cells), fn c -> c.title end)}) ==
             [{"Blocked", ["A"]}, {"Blocks others", ["B"]}, {"No dependencies", ["C"]}]

    titles = fn deps ->
      Swimlanes.grid(board, %Config{rows: "none", cols: "none", deps: deps}).rows
      |> hd()
      |> Map.get(:cells)
      |> hd()
      |> Enum.map(& &1.title)
    end

    assert titles.("blocked") == ["A"]
    assert titles.("ready") == ["B", "C"]
    assert titles.("blocking") == ["B"]
    assert titles.("free") == ["C"]

    assert [{:error, _}] = Swimlanes.move_ops("dependencies", a, "free", "blocked", %Config{})
    assert Config.from_query(%{"deps" => "blocked"}).deps == "blocked"
    assert Config.from_query(%{"deps" => "bogus"}).deps == nil
  end
end
