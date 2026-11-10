defmodule SlipdockWeb.BoardLive.SelectionTest do
  use ExUnit.Case, async: true

  alias Slipdock.Boards.Card
  alias SlipdockWeb.BoardLive.Selection

  # Two lists as the board draws them: list 1 with cards 1, 2 and 3 (and a
  # placed page numbered 2, which is not a card), in two groups; list 2 with
  # cards 4 and 5 and a stand-in, 6.
  defp columns do
    [
      %{
        column: %{id: 1},
        groups: [
          %{items: [{:card, %Card{id: 1}}, {:page, %Slipdock.Wiki.Page{id: 2}}]},
          %{items: [{:card, %Card{id: 2}}, {:card, %Card{id: 3}}]}
        ]
      },
      %{
        column: %{id: 2},
        groups: [
          %{
            items: [
              {:card, %Card{id: 4}},
              {:card, %Card{id: 6, stand_in_for_id: 1}},
              {:card, %Card{id: 5}}
            ]
          }
        ]
      },
      %{column: %{id: 3}, groups: [%{items: []}]}
    ]
  end

  defp set(ids), do: MapSet.new(ids)

  test "the board's cards in drawing order, without pages or stand-ins" do
    assert Selection.shown_ids(columns()) == [1, 2, 3, 4, 5]
  end

  describe "pick/5" do
    test "a plain click toggles the card and makes it the starting point" do
      assert Selection.pick(set([]), nil, columns(), 2, false) == {set([2]), 2}
      assert Selection.pick(set([2, 3]), 3, columns(), 2, false) == {set([3]), 2}
    end

    test "a shift-click picks the run within a list, either way round" do
      assert Selection.pick(set([1]), 1, columns(), 3, true) == {set([1, 2, 3]), 1}
      assert Selection.pick(set([3]), 3, columns(), 1, true) == {set([1, 2, 3]), 3}
    end

    test "a run goes down a list and across to the next, leaving stand-ins out" do
      assert Selection.pick(set([2]), 2, columns(), 5, true) == {set([2, 3, 4, 5]), 2}
      assert Selection.pick(set([5]), 5, columns(), 2, true) == {set([2, 3, 4, 5]), 5}
    end

    test "a run adds to what was already selected" do
      assert Selection.pick(set([5, 1]), 1, columns(), 2, true) == {set([1, 2, 5]), 1}
    end

    test "with no starting point a shift-click is a plain click" do
      assert Selection.pick(set([]), nil, columns(), 4, true) == {set([4]), 4}
    end

    test "a starting point no longer shown makes a shift-click a plain click" do
      assert Selection.pick(set([99]), 99, columns(), 4, true) == {set([4, 99]), 4}
    end

    test "a clicked card that isn't shown is toggled on its own" do
      assert Selection.pick(set([1]), 1, columns(), 77, true) == {set([1, 77]), 77}
    end
  end

  describe "toggle_list/3" do
    test "selects every card the list shows, and keeps the rest" do
      assert Selection.toggle_list(set([4]), columns(), 1) == set([1, 2, 3, 4])
    end

    test "a list partly selected is filled in" do
      assert Selection.toggle_list(set([2]), columns(), 1) == set([1, 2, 3])
    end

    test "deselects them when they are all selected already" do
      assert Selection.toggle_list(set([1, 2, 3, 4]), columns(), 1) == set([4])
    end

    test "never picks a stand-in or a page" do
      assert Selection.toggle_list(set([]), columns(), 2) == set([4, 5])
      assert Selection.toggle_list(set([4, 5]), columns(), 2) == set([])
    end

    test "an empty list or one not on the board changes nothing" do
      assert Selection.toggle_list(set([1]), columns(), 3) == set([1])
      assert Selection.toggle_list(set([1]), columns(), 42) == set([1])
    end
  end

  describe "add_list/3 (#2702)" do
    test "adds every card the list shows, and keeps the rest" do
      assert Selection.add_list(set([4]), columns(), 1) == set([1, 2, 3, 4])
    end

    test "never takes cards out, even when they are all selected already" do
      assert Selection.add_list(set([1, 2, 3, 4]), columns(), 1) == set([1, 2, 3, 4])
    end

    test "never picks a stand-in or a page" do
      assert Selection.add_list(set([]), columns(), 2) == set([4, 5])
    end

    test "an empty list or one not on the board changes nothing" do
      assert Selection.add_list(set([1]), columns(), 3) == set([1])
      assert Selection.add_list(set([1]), columns(), 42) == set([1])
    end
  end

  test "all_selected?/2" do
    [one, two, empty] = columns()
    assert Selection.all_selected?(set([1, 2, 3]), one)
    refute Selection.all_selected?(set([1, 2]), one)
    assert Selection.all_selected?(set([4, 5]), two)
    refute Selection.all_selected?(set([]), empty)
  end
end
