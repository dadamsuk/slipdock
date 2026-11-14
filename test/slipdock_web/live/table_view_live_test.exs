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
      for col <- board.columns, do: {:ok, _} = Boards.Columns.delete_column(col)

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

      {:ok, card} = Boards.Cards.update_card(card, %{"assignee_id" => user.id})
      Boards.Tags.toggle_card_tag(card, bug)
      {:ok, card} = Boards.Cards.toggle_flag(card, "blocked")
      {:ok, item} = Boards.Checklists.add_checklist_item(card, "one")
      {:ok, _} = Boards.Checklists.add_checklist_item(card, "two")
      Boards.Checklists.toggle_checklist_item(item)
      {:ok, _} = Boards.Comments.add_comment(card, "A remark")
      {:ok, _} = Votes.set(card, user, 2)
      {:ok, _} = Boards.Links.add_link(card, goal, "contributes")
      {:ok, _} = Boards.Links.add_link(twin, card, "duplicates")
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
      assert has_element?(view, "#{row} [role=link][title=Loaded]")
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

      assert has_element?(
               view,
               "#{row} button[data-role=complete-toggle][aria-label='Mark complete']"
             )

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

    test "a long title truncates inside its column instead of widening it",
         %{conn: conn, todo: todo} = ctx do
      long = String.duplicate("a very long card title ", 8) |> String.trim()
      card = card_fixture(todo, %{"title" => long})
      {:ok, view, _} = live(conn, everything(ctx))
      row = "#row-all-#{card.id}"

      # Only the title cell gives up its content width; the full title is on
      # hover, and the column keeps its 40% share of the header.
      assert has_element?(
               view,
               "#{row} td.max-w-0 [role=link].truncate[title='#{long}']"
             )

      assert has_element?(view, "#{row} td.max-w-0 div.min-w-0")
      refute has_element?(view, "#{row} td.max-w-0 input")
      refute has_element?(view, "#{row} td.max-w-0 select")
      assert has_element?(view, "#card-table thead th.w-\\[40\\%\\]", "Title")
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
      assert Boards.Cards.get_card!(card.id).start_date == ~D[2031-05-06]
      view |> form("#percent-#{card.id}", %{"value" => "75"}) |> render_change()
      assert Boards.Cards.get_card!(card.id).percent_complete == 75

      view |> form("#start-#{card.id}", %{"value" => ""}) |> render_change()
      assert is_nil(Boards.Cards.get_card!(card.id).start_date)
    end

    test "a list that isn't a number moves nothing", %{conn: conn, card: card} = ctx do
      {:ok, view, _} = live(conn, everything(ctx))
      before = Boards.Cards.get_card!(card.id).column_id

      render_change(view, "table_update", %{
        "card_id" => to_string(card.id),
        "field" => "column_id",
        "value" => "nope"
      })

      assert Boards.Cards.get_card!(card.id).column_id == before
    end

    test "a completed card is dimmed and offers to reopen", %{conn: conn, card: card} = ctx do
      {:ok, _} = Boards.Cards.update_card(card, %{"completed" => true})
      {:ok, view, _} = live(conn, everything(ctx))

      assert has_element?(view, "tr#row-all-#{card.id}.opacity-60")
      assert has_element?(view, "#row-all-#{card.id} button[aria-label='Mark incomplete']")
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
      assert Boards.Cards.get_card!(card.id).priority != "critical"
    end

    test "a reader still sorts: the heading is a real button outside every disabled fieldset",
         %{conn: conn, board: board, card: card} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

      assert has_element?(view, "#card-table thead button[type=button][phx-value-sort=title]")
      refute has_element?(view, "fieldset[disabled] thead")
      refute has_element?(view, "thead [role=button]")

      # The cells' controls are still disabled for a reader.
      assert has_element?(view, "#row-all-#{card.id} td fieldset[disabled]")

      view |> element("thead button[phx-value-sort=title]") |> render_click()
      assert_patch(view, ~p"/boards/#{board}/table?sort=title")
      assert has_element?(view, "thead button[phx-value-sort=title].text-primary .hero-arrow-up")
    end

    test "a writer's cells are not disabled", %{conn: conn} do
      board = board_fixture(%{"name" => "Mine"})
      card = card_fixture(hd(board.columns), %{"title" => "Touch me"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
      assert has_element?(view, "#row-all-#{card.id} td fieldset")
      refute has_element?(view, "fieldset[disabled]")
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

      assert has_element?(view, "#prio-#{a.id} select[aria-label=Priority]")
      view |> form("#prio-#{a.id}", %{"value" => "low"}) |> render_change()
      assert Boards.Cards.get_card!(a.id).priority == "low"
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
      refute has_element?(view, "#row-all-#{a.id} [data-role=complete-toggle]")
    end

    test "an empty board says so", %{conn: conn} do
      board = board_fixture()
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}/table?q=zzz")
      assert render(view) =~ "This board has no cards yet."
      assert has_element?(view, "#table-scroll button[phx-click=swim_clear_filters]")
    end
  end

  describe "cells read as text (#1731)" do
    setup do
      board = board_fixture(%{"name" => "Restful"})
      [backlog | _] = board.columns
      today = Date.utc_today()
      tags = for n <- ~w(alpha bravo charlie delta echo), do: tag_fixture(board, "t-" <> n)

      many =
        card_fixture(backlog, %{
          "title" => "Many tags",
          "due_date" => Date.to_iso8601(Date.add(today, -2))
        })

      for tag <- tags, do: Boards.Tags.toggle_card_tag(many, tag)

      two = card_fixture(backlog, %{"title" => "Two tags", "due_date" => Date.add(today, 1)})
      for tag <- Enum.take(tags, 2), do: Boards.Tags.toggle_card_tag(two, tag)

      later = card_fixture(backlog, %{"title" => "Later", "due_date" => Date.add(today, 30)})

      done =
        card_fixture(backlog, %{
          "title" => "Finished",
          "completed" => true,
          "due_date" => Date.add(today, -9)
        })

      plain = card_fixture(backlog, %{"title" => "Plain"})

      %{board: board, many: many, two: two, later: later, done: done, plain: plain}
    end

    defp due_cell(card), do: "#row-all-#{card.id} form#due-#{card.id}"

    test "Assignee is a default column, and the chooser hides it", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

      thead = render(element(view, "#card-table thead"))
      label = ~r/<th[^>]*>.*?<(?:span|button)[^>]*>\s*([^<\s][^<]*?)\s*</s

      headers =
        Regex.scan(label, thead, capture: :all_but_first)
        |> List.flatten()

      assert headers == ~w(Title List Priority Assignee Tags Due Done)

      assert has_element?(view, "#swim-config input[name='fields[]'][value=assignee][checked]")

      view
      |> form("#swim-config", %{"fields" => ~w(title column priority tags due_date completed)})
      |> render_change()

      assert_patch(
        view,
        ~p"/boards/#{board}/table?fields=title%2Ccolumn%2Cpriority%2Ctags%2Cdue_date%2Ccompleted"
      )

      refute has_element?(view, "#card-table thead th", "Assignee")
      assert has_element?(view, "#card-table thead th", "Tags")
    end

    test "an assignee shows in the default table, one line",
         %{conn: conn, board: board, user: user, plain: plain} do
      {:ok, _} = Boards.Cards.update_card(plain, %{"assignee_id" => user.id})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

      assert has_element?(
               view,
               "#row-all-#{plain.id} .flex-nowrap",
               Slipdock.Accounts.User.display_name(user)
             )
    end

    test "tags keep to one line: two chips, +N, every name in the tooltip",
         %{conn: conn, board: board, many: many, two: two, plain: plain} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

      row = "#row-all-#{many.id} .table-tags"

      assert has_element?(
               view,
               "#{row}.flex-nowrap[title='t-alpha, t-bravo, t-charlie, t-delta, t-echo']"
             )

      assert view
             |> element(row)
             |> render()
             |> then(&Regex.scan(~r/class="table-tag"/, &1))
             |> length() == 2

      assert has_element?(view, "#{row} [data-role=more-tags]", "+3")
      refute has_element?(view, "#{row} .table-tag", "t-charlie")

      # Exactly two: both drawn, nothing more to count.
      assert has_element?(view, "#row-all-#{two.id} .table-tags[title='t-alpha, t-bravo']")
      refute has_element?(view, "#row-all-#{two.id} [data-role=more-tags]")

      # None: an empty cell, not an empty tooltip.
      refute has_element?(view, "#row-all-#{plain.id} .table-tags")
    end

    test "each row has one due value, marked with its state", %{conn: conn, board: board} = ctx do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

      for {card, state} <- [
            {ctx.many, "overdue"},
            {ctx.two, "soon"},
            {ctx.later, "later"},
            {ctx.done, "done"}
          ] do
        assert has_element?(view, "#{due_cell(card)}[data-due=#{state}]")

        assert view
               |> element(due_cell(card))
               |> render()
               |> then(&Regex.scan(~r/data-date-field/, &1))
               |> length() == 1

        refute has_element?(view, "#{due_cell(card)} .hero-clock")
        refute has_element?(view, "#{due_cell(card)} .chip")
      end

      # No date: no state, no rolled-up date, and the field says "Add date"
      # (which the stylesheet hides until the row is hovered or focused).
      refute has_element?(view, "#{due_cell(ctx.plain)}[data-due]")
      refute has_element?(view, "#{due_cell(ctx.plain)}[data-derived]")

      assert has_element?(
               view,
               "#{due_cell(ctx.plain)} .table-due[data-empty] .date-field-placeholder",
               "Add date"
             )
    end

    test "the controls stay in the tab order: title, list, priority, due, done",
         %{conn: conn, board: board, many: many} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
      row = view |> element("#row-all-#{many.id}") |> render()

      stops =
        for pattern <- [
              ~r/role="link"/,
              ~r/id="col-#{many.id}"/,
              ~r/id="prio-#{many.id}"/,
              ~r/data-role="date-display"/,
              ~r/data-role="complete-toggle"/
            ] do
          [{at, _}] = Regex.run(pattern, row, return: :index)
          at
        end

      assert stops == Enum.sort(stops)
      refute has_element?(view, "#row-all-#{many.id} select[tabindex]")
      refute has_element?(view, "#row-all-#{many.id} [data-role=date-display][tabindex]")
      refute has_element?(view, "#row-all-#{many.id} [data-role=complete-toggle][tabindex]")
    end

    test "list, priority and due still save from the text cells",
         %{conn: conn, board: board, plain: plain} do
      [_, todo | _] = reload(board).columns
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

      view |> form("#prio-#{plain.id}", %{"value" => "high"}) |> render_change()
      view |> form("#due-#{plain.id}", %{"value" => "2031-04-05"}) |> render_change()
      view |> form("#col-#{plain.id}", %{"value" => to_string(todo.id)}) |> render_change()

      card = Boards.Cards.get_card!(plain.id)
      assert {card.priority, card.due_date, card.column_id} == {"high", ~D[2031-04-05], todo.id}
      assert has_element?(view, "#due-#{plain.id}[data-due=later]")

      assert has_element?(
               view,
               "#due-#{plain.id} [data-role=date-text]",
               SlipdockWeb.Dates.short(~D[2031-04-05])
             )

      # A date that isn't one leaves the card as it was.
      view |> form("#due-#{plain.id}", %{"value" => "not a date"}) |> render_change()
      assert Boards.Cards.get_card!(plain.id).due_date == ~D[2031-04-05]
    end

    test "an epic shows its subcards' due date muted, and a slip as an icon",
         %{conn: conn, board: board} do
      [backlog | _] = board.columns
      {:ok, simple} = Boards.Templates.find_template(nil, "Simple")

      rolled = card_fixture(backlog, %{"title" => "Rolled"})
      {:ok, sub} = sub_board(rolled, simple)

      card_fixture(hd(Boards.get_board!(sub.id).columns), %{
        "title" => "r1",
        "due_date" => "2030-03-01"
      })

      slipping = card_fixture(backlog, %{"title" => "Slipping", "due_date" => "2030-01-15"})
      {:ok, sub} = sub_board(slipping, simple)

      card_fixture(hd(Boards.get_board!(sub.id).columns), %{
        "title" => "s1",
        "due_date" => "2030-02-01"
      })

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

      # No date of its own: the rolled-up one is the placeholder, not a value.
      assert has_element?(view, "#due-#{rolled.id}[data-derived]")

      assert has_element?(
               view,
               "#due-#{rolled.id} .date-field-placeholder",
               SlipdockWeb.Dates.short(~D[2030-03-01])
             )

      assert has_element?(view, "#due-#{rolled.id} input[type=date]:not([value])")
      refute has_element?(view, "#due-#{rolled.id} .table-slip")

      # Its own date, and the subcards past it: one date, one icon saying so.
      refute has_element?(view, "#due-#{slipping.id}[data-derived]")
      assert has_element?(view, "#due-#{slipping.id} input[type=date][value='2030-01-15']")
      assert has_element?(view, "#due-#{slipping.id} .table-slip[title*='17 days past due date']")
      refute has_element?(view, "#due-#{slipping.id} .chip")
    end

    test "a finished epic shows no slip", %{conn: conn, board: board} do
      [backlog | _] = board.columns
      {:ok, simple} = Boards.Templates.find_template(nil, "Simple")
      epic = card_fixture(backlog, %{"title" => "Closed epic", "due_date" => "2030-01-15"})
      {:ok, sub} = sub_board(epic, simple)

      card_fixture(hd(Boards.get_board!(sub.id).columns), %{
        "title" => "x",
        "due_date" => "2030-02-01"
      })

      {:ok, _} = Boards.Cards.update_card(Boards.Cards.get_card!(epic.id), %{"completed" => true})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
      assert has_element?(view, "#due-#{epic.id}[data-due=done]")
      refute has_element?(view, "#due-#{epic.id} .table-slip")
    end
  end
end
