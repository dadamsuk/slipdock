defmodule Slipdock.OutlineTest do
  use Slipdock.DataCase, async: true

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

  describe "page/3" do
    # A node as build/4 shapes it, enough for paging: a card id and children.
    defp n(id, children \\ []), do: %{card: %{id: id, title: id}, children: children}
    defp ids(nodes), do: Enum.map(nodes, &{&1.card.id, ids(&1.children)})
    defp tops(n), do: for(i <- 1..n//1, do: n("t#{i}"))

    test "caps a page at its rows, not its top-level cards" do
      # Three top-level cards of three rows each: nine rows.
      outline = %{nodes: for(t <- ~w(a b c), do: n(t, [n("#{t}1"), n("#{t}2")]))}

      assert %{page: 1, pages: 2, from: 1, to: 6, count: 9, nodes: nodes} =
               Outline.page(outline, 1, per_page: 7)

      assert ids(nodes) == [{"a", [{"a1", []}, {"a2", []}]}, {"b", [{"b1", []}, {"b2", []}]}]

      assert %{from: 7, to: 9, nodes: [%{card: %{id: "c"}}]} =
               Outline.page(outline, 2, per_page: 7)
    end

    test "a subtree that fits a page but not what is left starts the next, whole" do
      outline = %{nodes: for(t <- ~w(a b c), do: n(t, [n("#{t}1"), n("#{t}2")]))}
      assert %{pages: 3} = Outline.page(outline, 1, per_page: 4)

      for {t, page} <- [{"a", 1}, {"b", 2}, {"c", 3}] do
        %{nodes: [node]} = Outline.page(outline, page, per_page: 4)
        assert ids([node]) == [{t, [{"#{t}1", []}, {"#{t}2", []}]}]
        refute node.continued
      end
    end

    test "only a subtree bigger than a page is split, its cards above repeated" do
      # a > b > b1, b2; a > c > c1: six rows, then z.
      outline = %{nodes: [n("a", [n("b", [n("b1"), n("b2")]), n("c", [n("c1")])]), n("z")]}

      assert %{pages: 2, from: 1, to: 4, count: 7, nodes: nodes} =
               Outline.page(outline, 1, per_page: 4)

      assert ids(nodes) == [{"a", [{"b", [{"b1", []}, {"b2", []}]}]}]

      # Page 2 carries on under a (shown again as context) and fills with z.
      assert %{from: 5, to: 7, nodes: [a, z]} = Outline.page(outline, 2, per_page: 4)
      assert ids([a, z]) == [{"a", [{"c", [{"c1", []}]}]}, {"z", []}]
      assert a.continued
      refute hd(a.children).continued or z.continued

      # Context counts towards the page: with three rows, b2's page repeats a and b.
      assert %{pages: 4} = Outline.page(outline, 1, per_page: 3)
      %{nodes: [a], from: 4, to: 4} = Outline.page(outline, 2, per_page: 3)
      assert ids([a]) == [{"a", [{"b", [{"b2", []}]}]}]
      assert a.continued and hd(a.children).continued
      %{nodes: [a]} = Outline.page(outline, 3, per_page: 3)
      assert ids([a]) == [{"a", [{"c", [{"c1", []}]}]}]
      assert %{nodes: [%{card: %{id: "z"}}], from: 7} = Outline.page(outline, 4, per_page: 3)
    end

    test "a collapsed card is one row and keeps what is beneath it" do
      outline = %{nodes: [n("a", [n("b", [n("b1"), n("b2")]), n("c", [n("c1")])])]}
      collapsed = MapSet.new(["card-b"])

      assert %{pages: 1, count: 4, nodes: nodes} =
               Outline.page(outline, 1, per_page: 4, collapsed: collapsed)

      assert ids(nodes) == [{"a", [{"b", [{"b1", []}, {"b2", []}]}, {"c", [{"c1", []}]}]}]
    end

    test "holds the page to the pages there are" do
      outline = %{nodes: tops(5)}
      assert %{nodes: [%{card: %{id: "t5"}}], page: 3} = Outline.page(outline, 99, per_page: 2)
      assert %{from: 1, to: 2, page: 1} = Outline.page(outline, 0, per_page: 2)
      assert %{page: 1} = Outline.page(outline, -4, per_page: 2)
    end

    test "an empty outline is one empty page" do
      assert %{nodes: [], page: 1, pages: 1, from: 0, to: 0, count: 0} =
               Outline.page(%{nodes: []}, 3, per_page: 2)
    end

    test "250 rows to a page by default, on a built outline too", ctx do
      assert Outline.per_page() == 250
      assert %{pages: 1} = Outline.page(%{nodes: tops(250)}, 1)
      assert %{pages: 2, nodes: [%{card: %{id: "t251"}}]} = Outline.page(%{nodes: tops(251)}, 2)

      board = Boards.get_board!(ctx.board.id)
      o = Outline.build(board, board.rollup, Config.defaults("outline"), @today)
      # The epic is five rows: on a page of five it stays whole, alone.
      %{nodes: [epic], to: 5, count: 8} = Outline.page(o, 1, per_page: 5)
      assert titles([epic]) == [{"Epic", [{"B", []}, {"C", [{"D", []}, {"E", []}]}]}]
      assert %{nodes: nodes, from: 6} = Outline.page(o, 2, per_page: 5)
      assert titles(nodes) == [{"Late", []}, {"Stuck", []}, {"Loose", []}]
    end
  end
end
