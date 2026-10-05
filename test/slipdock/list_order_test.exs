defmodule Slipdock.ListOrderTest do
  @moduledoc """
  A list's own order and groups (`Slipdock.ListOrder`), and the list
  settings that hold them (`Slipdock.Boards.Column`).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, ListOrder}
  alias Slipdock.Boards.{Card, Column, Tag}
  alias Slipdock.Wiki.Page

  # Monday 5 October 2026: its week ends on Sunday the 11th.
  @today ~D[2026-10-05]

  defp card(title, attrs \\ []) do
    struct(
      %Card{
        title: title,
        tags: [],
        inserted_at: ~U[2026-01-01 00:00:00Z],
        updated_at: ~U[2026-01-01 00:00:00Z]
      },
      attrs
    )
  end

  defp column(attrs), do: struct(%Column{name: "L"}, attrs)
  defp titles(items), do: Enum.map(items, & &1.title)
  defp arranged(groups), do: Enum.map(groups, &{&1.label, titles(&1.items)})

  @board %{tags: [%Tag{id: 1, name: "ux", color: "sky"}, %Tag{id: 2, name: "bug", color: "rose"}]}

  describe "sorting" do
    setup do
      %{
        items: [
          card("A", position: 0, priority: "low", due_date: ~D[2026-10-20]),
          card("B", position: 1, priority: "critical", due_date: nil),
          card("C", position: 2, priority: "high", due_date: ~D[2026-10-06]),
          card("D", position: 3, priority: "high", due_date: ~D[2026-10-06])
        ]
      }
    end

    test "board order leaves the items as they came", %{items: items} do
      assert items |> ListOrder.sort(column(sort_by: nil)) |> titles() == ~w(A B C D)
    end

    test "by due date, earliest first, undated last, ties in board order", %{items: items} do
      assert items |> ListOrder.sort(column(sort_by: "due_date")) |> titles() == ~w(C D A B)
    end

    test "descending turns the dated ones round; undated stay last", %{items: items} do
      assert items |> ListOrder.sort(column(sort_by: "due_date", sort_dir: "desc")) |> titles() ==
               ~w(A C D B)
    end

    test "by priority, highest first when descending", %{items: items} do
      assert items |> ListOrder.sort(column(sort_by: "priority", sort_dir: "desc")) |> titles() ==
               ~w(B C D A)
    end

    test "by created and last updated" do
      old =
        card("Old",
          position: 1,
          inserted_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-09-01 00:00:00Z]
        )

      new =
        card("New",
          position: 0,
          inserted_at: ~U[2026-06-01 00:00:00Z],
          updated_at: ~U[2026-07-01 00:00:00Z]
        )

      assert [new, old] |> ListOrder.sort(column(sort_by: "created")) |> titles() == ~w(Old New)
      assert [old, new] |> ListOrder.sort(column(sort_by: "updated")) |> titles() == ~w(New Old)
    end

    test "by start date, where a card without one starts when it is due" do
      items = [
        card("Due first", position: 0, due_date: ~D[2026-10-07]),
        card("Starts later", position: 1, start_date: ~D[2026-10-09], due_date: ~D[2026-10-30]),
        card("Starts now", position: 2, start_date: ~D[2026-10-05])
      ]

      assert items |> ListOrder.sort(column(sort_by: "start_date")) |> titles() ==
               ["Starts now", "Due first", "Starts later"]
    end

    test "a wiki page placed in the list sorts beside the cards" do
      page = struct(%Page{title: "Doc", tags: [], board_position: 1}, due_date: ~D[2026-10-01])
      items = [card("Card", position: 0, due_date: ~D[2026-10-09]), page]

      assert items |> ListOrder.sort(column(sort_by: "due_date")) |> titles() == ~w(Doc Card)
    end
  end

  describe "grouping" do
    test "ungrouped is one group without a heading" do
      assert ListOrder.arrange([card("A")], column(group_by: nil), @board, @today) == [
               %{key: "all", label: nil, color: nil, items: [card("A")]}
             ]
    end

    test "by flag: flag order, a card under the first it has, empty groups left out" do
      items = [
        card("Plain"),
        card("Both", flags: ["waiting", "blocked"]),
        card("Waiting", flags: ["waiting"])
      ]

      assert items |> ListOrder.arrange(column(group_by: "flag"), @board, @today) |> arranged() ==
               [{"Blocked", ["Both"]}, {"Waiting", ["Waiting"]}, {"No flag", ["Plain"]}]
    end

    test "by tag: the board's tag order, the tag's colour, untagged last" do
      [ux, bug] = @board.tags

      items = [
        card("None"),
        card("Bug", tags: [bug]),
        card("Both", tags: [bug, ux])
      ]

      groups = ListOrder.arrange(items, column(group_by: "tag"), @board, @today)

      assert arranged(groups) == [{"ux", ["Both"]}, {"bug", ["Bug"]}, {"No tag", ["None"]}]
      assert Enum.map(groups, & &1.color) == ["sky", "rose", nil]
    end

    test "inside each group the list's sort holds" do
      items = [
        card("Late", position: 0, flags: ["blocked"], due_date: ~D[2026-12-01]),
        card("Soon", position: 1, flags: ["blocked"], due_date: ~D[2026-10-06])
      ]

      groups =
        ListOrder.arrange(items, column(group_by: "flag", sort_by: "due_date"), @board, @today)

      assert arranged(groups) == [{"Blocked", ["Soon", "Late"]}]
    end

    test "by due date: relative to today, in time order" do
      items = [
        card("None"),
        card("Later", due_date: ~D[2026-10-19]),
        card("Next week", due_date: ~D[2026-10-18]),
        card("This week", due_date: ~D[2026-10-11]),
        card("Today", due_date: @today),
        card("Overdue", due_date: ~D[2026-10-04])
      ]

      groups = ListOrder.arrange(items, column(group_by: "due_date"), @board, @today)

      assert arranged(groups) == [
               {"Overdue", ["Overdue"]},
               {"Due today", ["Today"]},
               {"This week", ["This week"]},
               {"Next week", ["Next week"]},
               {"Later", ["Later"]},
               {"No due date", ["None"]}
             ]

      assert Enum.map(groups, & &1.tone) == [:past, :current, nil, nil, nil, nil]
    end

    test "by start date reads as starting, and the past is not an alarm" do
      items = [card("Begun", start_date: ~D[2026-09-01]), card("Unset")]
      groups = ListOrder.arrange(items, column(group_by: "start_date"), @board, @today)

      assert arranged(groups) == [{"Started", ["Begun"]}, {"No start date", ["Unset"]}]
      assert hd(groups).tone == nil
    end

    test "on a Sunday, this week is only today" do
      sunday = ~D[2026-10-11]
      assert ListOrder.date_group(~D[2026-10-12], sunday) == "next_week"
      assert ListOrder.date_group(~D[2026-10-18], sunday) == "next_week"
      assert ListOrder.date_group(~D[2026-10-19], sunday) == "later"
    end
  end

  test "label says how a list is arranged, and nothing for the default" do
    assert ListOrder.label(column(sort_by: nil, group_by: nil)) == nil
    assert ListOrder.label(column(sort_by: "due_date", sort_dir: "asc")) == "by due date"

    assert ListOrder.label(column(sort_by: "priority", sort_dir: "desc", group_by: "tag")) ==
             "by priority, descending, grouped by tags"

    assert ListOrder.label(column(group_by: "flag")) == "grouped by flags"
    refute ListOrder.sorted?(column(group_by: "flag"))
    assert ListOrder.sorted?(column(sort_by: "created"))
  end

  describe "the list settings" do
    setup do
      %{column: hd(board_fixture().columns)}
    end

    test "a new list is in board order, ungrouped", %{column: column} do
      assert %Column{sort_by: nil, sort_dir: "asc", group_by: nil} = column
    end

    test "save and clear; position, none and blank all mean the default", %{column: column} do
      {:ok, column} =
        Boards.update_column(column, %{
          "sort_by" => "due_date",
          "sort_dir" => "desc",
          "group_by" => "tag"
        })

      assert %Column{sort_by: "due_date", sort_dir: "desc", group_by: "tag"} =
               Repo.get!(Column, column.id)

      {:ok, column} =
        Boards.update_column(column, %{"sort_by" => "position", "group_by" => "none"})

      assert %Column{sort_by: nil, group_by: nil} = column

      {:ok, column} =
        Boards.update_column(column, %{"sort_by" => "", "sort_dir" => "", "group_by" => ""})

      assert %Column{sort_by: nil, sort_dir: "asc", group_by: nil} = Repo.get!(Column, column.id)
    end

    test "anything else is refused, and nothing changes", %{column: column} do
      for attrs <- [%{"sort_by" => "title"}, %{"sort_dir" => "up"}, %{"group_by" => "assignee"}] do
        assert {:error, cs} = Boards.update_column(column, attrs)
        [{field, _}] = Enum.to_list(attrs)

        assert %{^field => ["is invalid"]} =
                 errors_on(cs) |> Map.new(fn {k, v} -> {to_string(k), v} end)
      end

      assert %Column{sort_by: nil, group_by: nil} = Repo.get!(Column, column.id)
    end
  end
end
