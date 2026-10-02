defmodule Slipdock.OutlineTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Outline
  alias Slipdock.Swimlanes.Config

  @today ~D[2030-01-15]

  setup do
    tree_fixture()
  end

  defp titles(nodes), do: Enum.map(nodes, &{&1.card.title, titles(&1.children)})

  test "the whole tree, then one and two levels", ctx do
    board = Boards.get_board!(ctx.board.id)
    config = Config.defaults("outline")

    o = Outline.build(board, board.rollup, config, @today)
    assert o.levels == 3 and o.depth == :all
    assert o.done == 2 and o.total == 6
    assert o.shown == 8 and o.hidden == 0

    assert titles(o.nodes) == [
             {"Epic", [{"B", []}, {"C", [{"D", []}, {"E", []}]}]},
             {"Late", []},
             {"Stuck", []},
             {"Loose", []}
           ]

    [epic | _] = o.nodes
    assert epic.list == "Backlog" and epic.sub_board_id == ctx.sub.id and epic.level == 0
    [_, c] = epic.children
    assert c.list == "To Do" and c.level == 1 and not c.more
    assert %{health: :late, due_slip: 12} = c.stats

    o = Outline.build(board, board.rollup, %{config | depth: "1"}, @today)
    assert titles(o.nodes) == [{"Epic", []}, {"Late", []}, {"Stuck", []}, {"Loose", []}]
    # A cut-off node says there is more beneath it.
    assert hd(o.nodes).more and o.shown == 4

    o = Outline.build(board, board.rollup, %{config | depth: "2"}, @today)

    assert titles(o.nodes) == [
             {"Epic", [{"B", []}, {"C", []}]},
             {"Late", []},
             {"Stuck", []},
             {"Loose", []}
           ]

    [_, c] = hd(o.nodes).children
    assert c.more

    assert Outline.depths(3) == [
             {"all", "All levels"},
             {"1", "1 level"},
             {"2", "2 levels"},
             {"3", "3 levels"}
           ]

    assert length(Outline.depths(1, 4)) == 5
  end

  test "filters keep the ancestors of a match, muted; sorting applies per level", ctx do
    board = Boards.get_board!(ctx.board.id)
    config = Config.defaults("outline")

    o = Outline.build(board, board.rollup, %{config | q: "D"}, @today)
    # Only D matches; Epic and C are kept as its context.
    assert titles(o.nodes) == [{"Epic", [{"C", [{"D", []}]}]}]
    [epic] = o.nodes
    refute epic.match
    [c] = epic.children
    refute c.match
    assert hd(c.children).match
    assert o.shown == 1 and o.hidden == 7

    o = Outline.build(board, board.rollup, %{config | done: "hide"}, @today)

    assert titles(o.nodes) == [
             {"Epic", [{"C", [{"E", []}]}]},
             {"Late", []},
             {"Stuck", []},
             {"Loose", []}
           ]

    o = Outline.build(board, board.rollup, %{config | deps: "blocked"}, @today)
    assert titles(o.nodes) == [{"Stuck", []}]

    o = Outline.build(board, board.rollup, %{config | sort: "title", dir: "desc"}, @today)
    assert Enum.map(o.nodes, & &1.card.title) == ["Stuck", "Loose", "Late", "Epic"]
    assert Enum.map(List.last(o.nodes).children, & &1.card.title) == ["C", "B"]

    # Filtering everything out leaves nothing, with the hidden count.
    o = Outline.build(board, board.rollup, %{config | q: "zzz"}, @today)
    assert o.nodes == [] and o.hidden == 8
  end
end
