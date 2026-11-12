defmodule SlipdockWeb.CardFaceDocsTest do
  @moduledoc """
  The manual describes the calmer card face (#1706): the toolbar's one
  order and View options (#1711), search on the phone's toolbar row, a list
  favourited from its `⋯` menu with the heart only on a favourite's header
  (#1710), and priority as signal bars with the start in words (#1709).
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @manual Path.expand("../../docs/manual.md", __DIR__)

  setup_all do
    %{manual: Slipdock.DocsText.read!(@manual)}
  end

  test "the board toolbar's one order, in every view, and View options", %{manual: manual} do
    [_, paragraph] =
      String.split(manual, "Every view of the board lays it out in the same order", parts: 2)

    [paragraph | _] = String.split(paragraph, "\n\n", parts: 2)

    # The order the manual gives is the order the toolbar draws.
    order = [
      "switcher, search, **Filter**",
      "**Display**",
      "the card count, **Select**, **Views**"
    ]

    positions =
      Enum.map(order, fn part -> :binary.match(String.replace(paragraph, "\n", " "), part) end)

    refute :nomatch in positions, "the manual is missing part of the toolbar order"
    assert positions == Enum.sort(positions)

    assert paragraph =~ "**View options**"

    assert SlipdockWeb.SwimlaneComponents.toolbar_order() |> Enum.take(3) ==
             ~w(switcher search filter)
  end

  test "the phone toolbar row includes search", %{manual: manual} do
    assert_states(manual, "keeps the view switcher, search, the date navigator")
    refute manual =~ "keeps the view switcher, the date navigator, Filter"
  end

  test "a list is favourited from its menu, and only a favourite wears the heart", %{
    manual: manual
  } do
    assert_states(manual, "**Favourite this\nlist** in a list's `⋯` menu")
    assert_states(manual, "Only a favourite list shows a heart on its\n  header")
    refute manual =~ "Press the heart on a **saved view** (in the Views menu), a **list header**"
  end

  test "priority is signal bars and a start is said in words", %{manual: manual} do
    assert_states(manual, "Priority is drawn as signal bars everywhere it appears")
    assert_states(manual, "*Starts in 11 days* or *Started 11 days late*")
    refute manual =~ "priority chevron"
  end
end
