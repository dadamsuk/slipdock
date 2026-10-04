defmodule SlipdockWeb.TableViewLiveTest do
  @moduledoc """
  `SlipdockWeb.TableComponents` driven through the board's table page: the
  empty states, per-group add rows, collapsing, group tones and sums, the
  sort header, every kind of cell, the read-only table and the phone's
  stacked layout.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Fields, Votes}

  defp all_cards(board),
    do: board |> reload() |> Map.get(:columns) |> Enum.flat_map(& &1.cards)

  describe "an empty table" do
    test "a board with no cards says so and adds to its first list", %{conn: conn} do
      board = board_fixture(%{"name" => "Bare"})
      [first | _] = board.columns

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
      assert render(view) =~ "This board has no cards yet."
      refute has_element?(view, "#card-table")
      refute has_element?(view, "#table-scroll button[phx-click=swim_clear_filters]")

      assert has_element?(
               view,
               "form#table-add input[placeholder='Add a card to #{first.name}…']"
             )

      view |> form("form#table-add", %{"title" => "First one"}) |> render_submit()
      assert [%{title: "First one", column_id: column_id}] = all_cards(board)
      assert column_id == first.id
      assert has_element?(view, "#card-table", "First one")
    end

    test "filters that hide every card offer to clear them, not to add", %{conn: conn} do
      board = board_fixture()
      card_fixture(hd(board.columns), %{"title" => "Hidden by the search"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?q=nothing-matches-this")
      html = render(view)
      assert html =~ "No cards match the current filters."
      refute html =~ "This board has no cards yet."
      # Adding while filtered would make a card the filters then hide.
      refute has_element?(view, "form#table-add")

      view |> element("#table-scroll button[phx-click=swim_clear_filters]") |> render_click()
      assert has_element?(view, "#card-table", "Hidden by the search")
    end

    test "a board with no lists has nowhere to add", %{conn: conn} do
      board = board_fixture()
      for col <- board.columns, do: {:ok, _} = Boards.delete_column(col)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
      assert render(view) =~ "This board has no cards yet."
      refute has_element?(view, "form#table-add")
    end
  end

  describe "groups" do
    setup do
      board = board_fixture(%{"name" => "Grouped"})
      [backlog | _] = board.columns
      high = card_fixture(backlog, %{"title" => "Urgent thing", "priority" => "high"})
      low = card_fixture(backlog, %{"title" => "Someday thing", "priority" => "low"})
      %{board: board, high: high, low: low}
    end

    test "each group gets its own add row, which sets what the group stands for", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?rows=priority")

      assert has_element?(view, "form#table-add-high input[placeholder='Add a card to High…']")
      assert has_element?(view, "form#table-add-low")
      # With an add row per group, there is no catch-all at the bottom.
      refute has_element?(view, "form#table-add")

      view |> form("form#table-add-low", %{"title" => "Also someday"}) |> render_submit()
      assert %{priority: "low"} = Enum.find(all_cards(board), &(&1.title == "Also someday"))
      assert has_element?(view, "#group-low", "Also someday")
    end

    test "groups whose value a new card can't take fall back to one add row", %{
      conn: conn,
      board: board
    } do
      for axis <- ~w(created updated dependencies goal) do
        {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?rows=#{axis}")
        refute has_element?(view, "form[id^='table-add-']"), "rows=#{axis} has a group add row"
        assert has_element?(view, "form#table-add"), "rows=#{axis} has no add row"
      end
    end

    test "collapsing a group hides its rows and its add row", %{
      conn: conn,
      board: board,
      high: high,
      low: low
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?rows=priority")
      assert has_element?(view, "#group-high .hero-chevron-down")

      view |> element("#group-high [phx-click=swim_toggle_row]") |> render_click()
      refute has_element?(view, "#row-high-#{high.id}")
      refute has_element?(view, "form#table-add-high")
      assert has_element?(view, "#group-high .hero-chevron-right")
      # The header and its count stay, and the other group is untouched.
      assert has_element?(view, "#group-high", "High")
      assert has_element?(view, "#row-low-#{low.id}")

      view |> element("#group-high [phx-click=swim_toggle_row]") |> render_click()
      assert has_element?(view, "#row-high-#{high.id}")
      assert has_element?(view, "form#table-add-high")
    end

    test "date groups mark this period and the overdue ones", %{conn: conn} do
      board = board_fixture()
      [backlog | _] = board.columns
      today = Date.utc_today()
      card_fixture(backlog, %{"title" => "Due now", "due_date" => Date.to_iso8601(today)})
      card_fixture(backlog, %{"title" => "Long overdue", "due_date" => "2001-02-14"})
      card_fixture(backlog, %{"title" => "Undated"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?rows=due_date&unit=month")

      now_key = today |> Date.beginning_of_month() |> Date.to_iso8601()
      assert has_element?(view, "#group-#{now_key} tr.text-primary .badge-primary", "now")
      assert has_element?(view, "#group-2001-02-01 tr.text-error\\/80")
      refute has_element?(view, "#group-2001-02-01 .badge-primary")
      assert has_element?(view, "#group-none", "No due date")
    end

    test "a summed field totals each group in its header", %{conn: conn, board: board} = ctx do
      {:ok, points} =
        Fields.create_field(board, %{"name" => "Points", "kind" => "number", "sum" => true})

      {:ok, _} = Fields.set_value(ctx.high, points, 3)
      {:ok, _} = Fields.set_value(ctx.low, points, 5)
      urgent2 = card_fixture(hd(board.columns), %{"title" => "Also urgent", "priority" => "high"})
      {:ok, _} = Fields.set_value(urgent2, points, 4)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?rows=priority")
      assert has_element?(view, "#group-high [title='Total Points in this group']", "Σ Points 7")
      assert has_element?(view, "#group-low [title='Total Points in this group']", "Σ Points 5")
    end
  end

  describe "the header" do
    test "the sorted column is marked with its direction; unsortable ones are plain", %{
      conn: conn
    } do
      board = board_fixture()
      card_fixture(hd(board.columns), %{"title" => "Only"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?sort=due_date&dir=asc")
      assert has_element?(view, "th [phx-value-sort=due_date].text-primary .hero-arrow-up")
      refute has_element?(view, "th [phx-value-sort=title].text-primary")
      # Tags can't be sorted on: a plain label, no button.
      assert has_element?(view, "#card-table thead th span", "Tags")
      refute has_element?(view, "#card-table thead th [role=button]", "Tags")

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?sort=due_date&dir=desc")
      assert has_element?(view, "th [phx-value-sort=due_date] .hero-arrow-down")
    end

    test "compact density uses its own columns and the small table", %{conn: conn} do
      board = board_fixture()
      card = card_fixture(hd(board.columns), %{"title" => "Small"})

      {:ok, view, _} =
        live(conn, ~p"/boards/#{board}/table?density=compact&fields_compact=id&fields=tags")

      assert has_element?(view, "table#card-table.table-xs")
      assert has_element?(view, "#card-table thead th", "ID")
      refute has_element?(view, "#card-table thead th", "Tags")
      assert has_element?(view, "#row-all-#{card.id}", "##{card.id}")
    end
  end

  describe "cells" do
    setup %{user: user} do
      board = board_fixture(%{"name" => "Every field"})
      [backlog, todo | _] = board.columns
      bug = tag_fixture(board, "bug", "red")

      {:ok, rating} =
        Fields.create_field(board, %{
          "name" => "Stars",
          "kind" => "rating",
          "config" => %{"max" => 5}
        })

      {:ok, size} =
        Fields.create_field(board, %{
          "name" => "Size",
          "kind" => "select",
          "options" => [
            %{"key" => "s", "label" => "Small", "weight" => 1, "color" => "lime"},
            %{"key" => "l", "label" => "Large", "weight" => 3}
          ]
        })

      {:ok, notes} = Fields.create_field(board, %{"name" => "Notes", "kind" => "text"})

      goal = card_fixture(todo, %{"title" => "Ship the thing"})
      twin = card_fixture(todo, %{"title" => "Its twin"})

      card =
        card_fixture(backlog, %{
          "title" => "Loaded",
          "description" => "Has words",
          "color" => "violet",
          "start_date" => "2030-01-01",
          "percent_complete" => 40
        })

      {:ok, card} = Boards.update_card(card, %{"assignee_id" => user.id})
      Boards.toggle_card_tag(card, bug)
      {:ok, card} = Boards.toggle_flag(card, "blocked")
      {:ok, item} = Boards.add_checklist_item(card, "one")
      {:ok, _} = Boards.add_checklist_item(card, "two")
      Boards.toggle_checklist_item(item)
      {:ok, _} = Boards.add_comment(card, "A remark")
      {:ok, _} = Votes.set(card, user, 2)
      {:ok, _} = Boards.add_link(card, goal, "contributes")
      {:ok, _} = Boards.add_link(twin, card, "duplicates")
      {:ok, _} = Fields.set_value(card, rating, 3)
      {:ok, _} = Fields.set_value(card, size, "s")
      {:ok, _} = Fields.set_value(card, notes, "free text")

      plain = card_fixture(backlog, %{"title" => "Plain"})

      %{
        board: board,
        card: card,
        plain: plain,
        goal: goal,
        todo: todo,
        rating: rating,
        size: size,
        notes: notes
      }
    end

    defp everything(ctx), do: ~p"/boards/#{ctx.board}/table?#{query(ctx)}"

    test "every column renders, including Goal and Links", %{conn: conn, card: card} = ctx do
      {:ok, view, _} = live(conn, everything(ctx))
      row = "#row-all-#{card.id}"

      assert has_element?(view, "#{row} [title='Has description']")
      assert has_element?(view, "#{row} [phx-click=open_card][title=Loaded]")
      assert has_element?(view, "#{row} select[name=value] option[selected]", "Backlog")
      assert has_element?(view, "#{row} input[type=date][value='2030-01-01']")
      assert has_element?(view, "#{row} input[type=number][value='40']")
      assert has_element?(view, "#{row} .font-mono", "1/2")
      assert has_element?(view, "#{row} .hero-chat-bubble-left")
      assert has_element?(view, "#{row} span", "Violet")
      assert has_element?(view, "#{row} [title=Votes]", "2")
      assert has_element?(view, "#{row} span", "##{card.id}")
      assert has_element?(view, "#{row} [title='3 of 5']", "★★★")
      assert has_element?(view, "#{row} .chip:not(.chip-line)", "Small")
      assert has_element?(view, "#{row} span", "free text")
      assert has_element?(view, "#{row} input[type=checkbox][title='Mark complete']")

      # The goal it contributes to, which opens that card.
      assert has_element?(view, "#{row} [phx-click=open_card][title='Ship the thing']")

      # Links both ways, each in its own direction's words.
      links = "#{row} [title='Contributes to Ship the thing; Duplicated by Its twin']"
      assert has_element?(view, links, "2")

      view |> element("#{row} [phx-click=open_card][title='Ship the thing']") |> render_click()
      assert_patch(view, ~p"/boards/#{ctx.board}/table/cards/#{ctx.goal.id}?#{query(ctx)}")
    end

    test "the chooser's Votes box adds the Votes column", %{conn: conn, card: card} = ctx do
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/table")
      assert has_element?(view, "#swim-config input[value=votes]")
      refute has_element?(view, "#card-table thead th", "Votes")

      view |> form("#swim-config", %{"fields" => ["title", "votes"]}) |> render_change()
      assert has_element?(view, "#card-table thead th", "Votes")
      assert has_element?(view, "#row-all-#{card.id} [title=Votes]", "2")
    end

    test "a card with nothing set leaves its cells empty", %{conn: conn, plain: plain} = ctx do
      {:ok, view, _} = live(conn, everything(ctx))
      row = "#row-all-#{plain.id}"

      assert has_element?(view, row, "Plain")
      refute has_element?(view, "#{row} [title='Has description']")
      refute has_element?(view, "#{row} .hero-chat-bubble-left")
      refute has_element?(view, "#{row} .hero-arrows-right-left")
      refute has_element?(view, "#{row} [title=Votes]")
      refute has_element?(view, "#{row} [phx-click=open_card].chip")
      refute has_element?(view, "#{row} .font-mono", "/")
    end

    test "inline edits set start date and percent, and clear them",
         %{conn: conn, card: card} = ctx do
      {:ok, view, _} = live(conn, everything(ctx))

      view |> form("#start-#{card.id}", %{"value" => "2031-05-06"}) |> render_change()
      assert Boards.get_card!(card.id).start_date == ~D[2031-05-06]
      view |> form("#percent-#{card.id}", %{"value" => "75"}) |> render_change()
      assert Boards.get_card!(card.id).percent_complete == 75

      view |> form("#start-#{card.id}", %{"value" => ""}) |> render_change()
      assert is_nil(Boards.get_card!(card.id).start_date)
    end

    test "a list that isn't a number moves nothing", %{conn: conn, card: card} = ctx do
      {:ok, view, _} = live(conn, everything(ctx))
      before = Boards.get_card!(card.id).column_id

      render_change(view, "table_update", %{
        "card_id" => to_string(card.id),
        "field" => "column_id",
        "value" => "nope"
      })

      assert Boards.get_card!(card.id).column_id == before
    end

    test "a completed card is dimmed and offers to reopen", %{conn: conn, card: card} = ctx do
      {:ok, _} = Boards.update_card(card, %{"completed" => true})
      {:ok, view, _} = live(conn, everything(ctx))

      assert has_element?(view, "tr#row-all-#{card.id}.opacity-60")
      assert has_element?(view, "#row-all-#{card.id} input[title='Mark incomplete']")
    end
  end

  # Every built-in column and the three custom ones.
  defp query(ctx) do
    custom = ["f:#{ctx.rating.id}", "f:#{ctx.size.id}", "f:#{ctx.notes.id}"]
    %{"fields" => Enum.join(Slipdock.Table.field_keys() ++ custom, ",")}
  end

  describe "read-only" do
    setup %{user: user} do
      owner = user_fixture("table-owner@example.com")
      board = board_fixture(%{"name" => "Theirs"}, owner: owner)
      card = card_fixture(hd(board.columns), %{"title" => "Look, don't touch"})
      {:ok, _} = Access.grant(board, user, "read", owner)
      %{board: board, card: card}
    end

    test "the table is disabled and has no add rows", %{conn: conn, board: board, card: card} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?rows=priority")
      assert has_element?(view, "fieldset[disabled]")
      refute has_element?(view, "form[id^=table-add]")

      html =
        render_change(view, "table_update", %{
          "card_id" => to_string(card.id),
          "field" => "priority",
          "value" => "critical"
        })

      assert html =~ "read-only access"
      assert Boards.get_card!(card.id).priority != "critical"
    end

    test "an empty board offers no add row either", %{conn: conn, user: user} do
      owner = user_fixture("empty-owner@example.com")
      board = board_fixture(%{"name" => "Empty theirs"}, owner: owner)
      {:ok, _} = Access.grant(board, user, "read", owner)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
      assert render(view) =~ "This board has no cards yet."
      refute has_element?(view, "form#table-add")
    end
  end

  describe "on a phone" do
    setup do
      board = board_fixture(%{"name" => "Pocket"})
      [backlog | _] = board.columns
      a = card_fixture(backlog, %{"title" => "Thumb me", "priority" => "high"})
      %{board: board, a: a}
    end

    test "each card is a stack of labelled fields, still editable", %{
      conn: conn,
      board: board,
      a: a
    } do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}/table")

      refute has_element?(view, "table#card-table")
      assert has_element?(view, "div#card-table li#row-all-#{a.id}", "Thumb me")
      # Title and Done sit on the top line; the rest are labelled below.
      assert has_element?(view, "#row-all-#{a.id} dt", "Priority")
      refute has_element?(view, "#row-all-#{a.id} dt", "Title")
      refute has_element?(view, "#row-all-#{a.id} dt", "Done")
      # Ungrouped: no group header, one add row at the bottom.
      refute has_element?(view, "#card-table button[phx-click=swim_toggle_row]")
      assert has_element?(view, "form#table-add")

      view |> form("#prio-#{a.id}", %{"value" => "low"}) |> render_change()
      assert Boards.get_card!(a.id).priority == "low"
    end

    test "groups fold and keep their own add rows", %{conn: conn, board: board, a: a} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}/table?rows=priority")

      header = "#group-high button[phx-click=swim_toggle_row]"
      assert has_element?(view, "#{header}[aria-expanded=true]", "High")
      assert has_element?(view, "form#table-add-high")
      refute has_element?(view, "form#table-add")

      view |> element(header) |> render_click()
      assert has_element?(view, "#{header}[aria-expanded=false]")
      refute has_element?(view, "#row-high-#{a.id}")
      refute has_element?(view, "form#table-add-high")
    end

    test "a title-only table has no labelled lines", %{conn: conn, board: board, a: a} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}/table?fields=")
      assert has_element?(view, "#row-all-#{a.id}", "Thumb me")
      refute has_element?(view, "#row-all-#{a.id} dl")
      refute has_element?(view, "#row-all-#{a.id} input[type=checkbox]")
    end

    test "an empty board says so", %{conn: conn} do
      board = board_fixture()
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}/table?q=zzz")
      assert render(view) =~ "This board has no cards yet."
      assert has_element?(view, "#table-scroll button[phx-click=swim_clear_filters]")
    end
  end
end
