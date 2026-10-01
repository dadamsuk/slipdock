defmodule Slipdock.WikiFacetsTest do
  @moduledoc """
  A page carrying the card's facets, and standing beside the cards in the
  views because of it.

  The line these tests hold is the one the design draws: a page takes the
  attributes that say *where it stands* — priority, flags, dates, assignee —
  because those are what the views group, filter and sort by. It does not take
  the card's contents, and the virtual empties that stand in for them are what
  let one component draw either.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Calendar, Swimlanes, Table, Timeline, Wiki}
  alias Slipdock.Boards.Card
  alias Slipdock.Swimlanes.Config

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Faceted", "code" => "faceted"}, owner: user)
    [todo | _] = board.columns
    %{user: user, board: board, todo: todo}
  end

  defp placed(board, todo, user, attrs) do
    {:ok, page} = Wiki.create_page(board, Map.merge(%{"title" => "The spec"}, attrs), user: user)
    {:ok, placed} = Wiki.place(page, todo)
    placed
  end

  describe "the facets themselves" do
    test "a page takes the card's vocabularies, and refuses what a card would", %{
      board: board,
      user: user
    } do
      {:ok, page} =
        Wiki.create_page(
          board,
          %{
            "title" => "The spec",
            "priority" => "critical",
            "flags" => ["blocked", "review"],
            "due_date" => "2026-10-09",
            "percent_complete" => 40,
            "color" => "amber"
          },
          user: user
        )

      assert page.priority == "critical"
      assert page.flags == ["blocked", "review"]
      assert page.percent_complete == 40
      assert page.color == "amber"

      assert {:error, changeset} = Wiki.update_page(page, %{"priority" => "urgent"}, user: user)
      assert "is invalid" in errors_on(changeset).priority

      assert {:error, changeset} = Wiki.update_page(page, %{"flags" => ["nonsense"]}, user: user)
      assert errors_on(changeset).flags != []

      assert {:error, changeset} =
               Wiki.update_page(page, %{"percent_complete" => 500}, user: user)

      assert errors_on(changeset).percent_complete != []
    end

    test "dates snap to whole buckets exactly as a card's do", %{board: board, user: user} do
      attrs = %{
        "date_precision" => "quarter",
        "start_date" => "2026-05-14",
        "due_date" => "2026-05-14"
      }

      {:ok, page} = Wiki.create_page(board, Map.put(attrs, "title", "The spec"), user: user)
      [column | _] = Boards.get_board!(board.id).columns
      {:ok, card} = Boards.create_card(column, Map.put(attrs, "title", "The work"))

      assert page.start_date == card.start_date
      assert page.due_date == card.due_date
      assert Card.fuzzy?(page)
    end

    test "a start after the due date is refused, as on a card", %{board: board, user: user} do
      assert {:error, changeset} =
               Wiki.create_page(
                 board,
                 %{
                   "title" => "The spec",
                   "start_date" => "2026-10-10",
                   "due_date" => "2026-10-01"
                 },
                 user: user
               )

      assert "must be on or before the due date" in errors_on(changeset).start_date
    end

    test "what a page has not got reads as empty rather than blowing up", %{
      board: board,
      user: user
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)

      refute Card.blocked?(page)
      assert Card.open_blockers(page) == []
      assert Card.vote_total(page) == 0
      assert Card.subcard_progress(page) == nil
      assert Card.progress(page) == nil
      assert Card.health(page) == nil
      assert Card.stated_health(page) == nil
      assert Card.slip(page) == 0
      assert Card.goals(page) == []
      assert Card.violated_blockers(page) == []
      refute Card.start_derived?(page)
    end

    test "its own dates are its effective dates", %{board: board, user: user} do
      {:ok, page} =
        Wiki.create_page(
          board,
          %{"title" => "The spec", "start_date" => "2026-10-01", "due_date" => "2026-10-09"},
          user: user
        )

      assert Card.effective_start(page) == ~D[2026-10-01]
      assert Card.effective_due(page) == ~D[2026-10-09]
      assert Card.starts_on(page) == ~D[2026-10-01]
      assert Card.ends_on(page) == ~D[2026-10-09]
    end
  end

  describe "standing beside the cards" do
    setup %{board: board, todo: todo, user: user} do
      card =
        card_fixture(todo, %{
          "title" => "The work",
          "priority" => "high",
          "due_date" => "2026-10-08"
        })

      page =
        placed(board, todo, user, %{
          "priority" => "critical",
          "flags" => ["blocked"],
          "due_date" => "2026-10-02"
        })

      %{card: card, page: page, loaded: Boards.get_board!(board.id)}
    end

    test "a swimlane groups it on the same axes", %{loaded: board} do
      grid =
        Swimlanes.grid(board, %{Config.defaults("swimlanes") | rows: "priority", cols: "none"})

      assert grid.shown == 2

      by_row =
        Map.new(grid.rows, &{&1.label, Enum.map(List.flatten(&1.cells), fn c -> c.title end)})

      assert by_row["Critical"] == ["The spec"]
      assert by_row["High"] == ["The work"]
    end

    test "a flag axis puts it under its flag", %{loaded: board} do
      grid = Swimlanes.grid(board, %{Config.defaults("swimlanes") | rows: "flag", cols: "none"})

      by_row =
        Map.new(grid.rows, &{&1.label, Enum.map(List.flatten(&1.cells), fn c -> c.title end)})

      assert by_row["Blocked"] == ["The spec"]
    end

    test "a filter that excludes it excludes it", %{loaded: board} do
      config = %{Config.defaults("table") | priorities: ["high"]}
      rows = Table.rows(board, config)
      titles = rows.groups |> Enum.flat_map(& &1.cards) |> Enum.map(& &1.title)

      assert titles == ["The work"]
    end

    test "a table sorts it among the cards by due date", %{loaded: board} do
      config = %{Config.defaults("table") | sort: "due_date", dir: "asc"}
      rows = Table.rows(board, config)
      titles = rows.groups |> Enum.flat_map(& &1.cards) |> Enum.map(& &1.title)

      assert titles == ["The spec", "The work"]
    end

    test "a timeline gives it a bar", %{loaded: board} do
      timeline = Timeline.build(board, %{Config.defaults("timeline") | date: "2026-10-05"})
      titles = timeline.groups |> Enum.flat_map(& &1.bars) |> Enum.map(& &1.card.title)

      assert "The spec" in titles
      assert "The work" in titles
    end

    test "a calendar puts it on its day", %{loaded: board} do
      calendar = Calendar.build(board, %{Config.defaults("calendar") | date: "2026-10-05"})

      titles =
        calendar.weeks
        |> List.flatten()
        |> Enum.flat_map(& &1.cards)
        |> Enum.map(& &1.title)

      assert "The spec" in titles
    end

    test "a page and a card with the same number stay apart", %{board: board, todo: todo} do
      # Two id spaces, one list: the refs are what keep them straight.
      assert Boards.item_ref("page-1") == {:page, 1}
      assert Boards.item_ref("1") == {:card, 1}

      items = Boards.active_items(todo.id)
      assert length(items) == 2
      assert Enum.any?(items, &match?({:card, _}, &1))
      assert Enum.any?(items, &match?({:page, _}, &1))
      assert board
    end
  end

  describe "dropping a page on an axis" do
    test "setting a facet through the swimlane vocabulary works on either", %{
      board: board,
      todo: todo,
      user: user
    } do
      page = placed(board, todo, user, %{})
      config = Config.defaults("swimlanes")

      # What the grid would do when the page is dragged into the "high" row.
      ops = Swimlanes.move_ops("priority", page, "none", "high", config)
      assert ops == [{:attrs, %{"priority" => "high"}}]

      {:ok, updated} = Wiki.update_page(page, %{"priority" => "high"}, user: user)
      assert updated.priority == "high"

      # And into a flag row, which reads the page's current flags.
      ops = Swimlanes.move_ops("flag", updated, "none", "review", config)
      assert ops == [{:attrs, %{"flags" => ["review"]}}]
    end
  end
end
