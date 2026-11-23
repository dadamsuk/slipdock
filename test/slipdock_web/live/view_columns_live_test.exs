defmodule SlipdockWeb.ViewColumnsLiveTest do
  @moduledoc """
  Reordering, hiding and resizing the columns of the table, the outline and
  Prioritise (#3665), through the Display menu's Columns and the headings'
  edges. The order, what is hidden and the widths are the view's: in the URL.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Fields}

  # The keys of the headings in `selector`, in the order they are drawn.
  defp heading_keys(view, selector) do
    # The resize handles (spans) name their column too; the cells are what count.
    ~r/<(?:th|td|div)\b[^>]*?\sdata-col="([^"]+)"/
    |> Regex.scan(view |> element(selector) |> render())
    |> Enum.map(fn [_, key] -> key end)
  end

  # The keys of a view's Columns list in the Display menu, in order.
  defp menu_keys(view, view_name) do
    list =
      if view_name == "table",
        do: "#display-menu ul[data-id=table]",
        else: "#display-cols-#{view_name}-list"

    ~r/<li[^>]*data-id="([^"]+)"/
    |> Regex.scan(view |> element(list) |> render())
    |> Enum.map(fn [_, key] -> key end)
  end

  describe "the table" do
    setup do
      board = board_fixture(%{"name" => "Cols"})
      card = card_fixture(hd(board.columns), %{"title" => "Row one", "priority" => "high"})
      %{board: board, card: card}
    end

    test "draws its columns in the order the Display menu lists them", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,tags,priority")

      assert heading_keys(view, "#card-table thead") == ~w(title tags priority)
      # The menu: the shown columns in order, then the hidden ones in their own.
      assert ["tags", "priority", "column" | _] = menu_keys(view, "table")
      assert has_element?(view, "#col-table-tags input[type=checkbox][checked]")
      refute has_element?(view, "#col-table-column input[type=checkbox][checked]")
    end

    test "a column dragged in the menu moves in the table and the URL", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,column,priority,tags")

      render_hook(view, "col_move", %{
        "id" => "tags",
        "from" => "table",
        "to" => "table",
        "before" => "column"
      })

      assert_patch(view, ~p"/boards/#{board}/table?fields=title%2Ctags%2Ccolumn%2Cpriority")
      assert heading_keys(view, "#card-table thead") == ~w(title tags column priority)

      # Dropped at the end (no column after it).
      render_hook(view, "col_move", %{
        "id" => "tags",
        "from" => "table",
        "to" => "table",
        "before" => nil
      })

      assert heading_keys(view, "#card-table thead") == ~w(title column priority tags)
    end

    test "the arrow keys on a column's grip move it a place", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,column,priority,tags")

      view |> element("#col-grip-table-priority") |> render_keydown(%{"key" => "ArrowUp"})
      assert heading_keys(view, "#card-table thead") == ~w(title priority column tags)

      view |> element("#col-grip-table-priority") |> render_keydown(%{"key" => "ArrowDown"})
      view |> element("#col-grip-table-priority") |> render_keydown(%{"key" => "ArrowDown"})
      assert heading_keys(view, "#card-table thead") == ~w(title column tags priority)

      # Past the end, and any other key, change nothing.
      view |> element("#col-grip-table-priority") |> render_keydown(%{"key" => "ArrowDown"})
      view |> element("#col-grip-table-priority") |> render_keydown(%{"key" => "x"})
      assert heading_keys(view, "#card-table thead") == ~w(title column tags priority)
    end

    test "the Display form sends its boxes in the order drawn, and the table follows", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,tags,priority")

      view
      |> form("#swim-config", %{"fields" => ["title", "priority", "tags"]})
      |> render_change()

      assert heading_keys(view, "#card-table thead") == ~w(title priority tags)
    end

    test "a heading's edge sets the column's width, and a double-click puts it back", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,priority")

      assert has_element?(
               view,
               "#col-resize-table-priority[phx-hook=ColumnResize][data-var='--cw-priority']"
             )

      refute has_element?(view, "#card-table[style*='--cw-priority']")

      render_hook(view, "col_width", %{"view" => "table", "col" => "priority", "width" => 210})
      assert_patch(view, ~p"/boards/#{board}/table?fields=title%2Cpriority&widths=priority%3A210")
      assert has_element?(view, "#card-table[style*='--cw-priority: 210px']")
      # The cell gives up its content's width for the one chosen.
      assert has_element?(view, "#row-all-#{card.id} td.overflow-hidden.max-w-0")

      render_hook(view, "col_width", %{"view" => "table", "col" => "priority", "width" => nil})
      refute has_element?(view, "#card-table[style*='--cw-priority']")
    end

    test "a width outside the limits is held to them; a column or view it doesn't have is ignored",
         %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,priority")

      render_hook(view, "col_width", %{"view" => "table", "col" => "title", "width" => 5})
      assert has_element?(view, "#card-table[style*='--cw-title: 48px']")

      render_hook(view, "col_width", %{"view" => "table", "col" => "bogus", "width" => 200})
      render_hook(view, "col_width", %{"view" => "board", "col" => "title", "width" => 200})
      render_hook(view, "col_move", %{"id" => "title", "to" => "nowhere", "before" => nil})
      assert has_element?(view, "#card-table[style*='--cw-title: 48px']")
      refute render(view) =~ "--cw-bogus"
    end

    test "comfortable and compact tables keep their own widths", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?widths=title%3A300&density=compact")
      refute has_element?(view, "#card-table[style*='--cw-title']")

      render_hook(view, "col_width", %{"view" => "table", "col" => "title", "width" => 200})
      assert has_element?(view, "#card-table[style*='--cw-title: 200px']")

      {:ok, view, _} =
        live(conn, ~p"/boards/#{board}/table?widths=title%3A300&widths_compact=title%3A200")

      assert has_element?(view, "#card-table[style*='--cw-title: 300px']")
    end

    test "a reader can rearrange and resize: it changes only their view", %{
      conn: conn,
      user: user
    } do
      owner = user_fixture("cols-owner@example.com")
      board = board_fixture(%{"name" => "Theirs"}, owner: owner)
      card_fixture(hd(board.columns), %{"title" => "Look"})
      {:ok, _} = Access.grant(board, user, "read", owner)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,column,priority")
      render_hook(view, "col_move", %{"id" => "priority", "to" => "table", "before" => "column"})
      render_hook(view, "col_width", %{"view" => "table", "col" => "column", "width" => 150})

      assert heading_keys(view, "#card-table thead") == ~w(title priority column)
      assert has_element?(view, "#card-table[style*='--cw-column: 150px']")
      refute render(view) =~ "read-only access"
    end
  end

  describe "the outline" do
    setup do
      board = board_fixture(%{"name" => "Tree"})
      epic = card_fixture(hd(board.columns), %{"title" => "Epic"})
      %{board: board, epic: epic}
    end

    test "draws every column until the reader changes them", %{
      conn: conn,
      board: board,
      epic: epic
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/outline")

      assert heading_keys(view, "#outline .ol-head") ==
               ~w(card list progress schedule health actions)

      assert heading_keys(view, "#ol-#{epic.id}") ==
               ~w(card list progress schedule health actions)

      assert menu_keys(view, "outline") == ~w(list progress schedule health)
    end

    test "hides a column unticked in the Display menu, keeping its place", %{
      conn: conn,
      board: board,
      epic: epic
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/outline")

      view
      |> form("#swim-config", %{
        "outline_cols" => [
          "-list",
          "list",
          "-progress",
          "-schedule",
          "schedule",
          "-health",
          "health"
        ]
      })
      |> render_change()

      assert_patch(
        view,
        ~p"/boards/#{board}/outline?outline_cols=list%2C-progress%2Cschedule%2Chealth"
      )

      assert heading_keys(view, "#outline .ol-head") == ~w(card list schedule health actions)
      refute has_element?(view, "#ol-#{epic.id} [data-col=progress]")
      assert menu_keys(view, "outline") == ~w(list progress schedule health)
      refute has_element?(view, "#col-outline-progress input[type=checkbox][checked]")
      # The grid has a track per column drawn.
      refute has_element?(view, "#outline[style*='--cw-progress']")
    end

    test "moves a column, and its cells move with it", %{conn: conn, board: board, epic: epic} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/outline")

      render_hook(view, "col_move", %{"id" => "health", "to" => "outline", "before" => "list"})

      assert heading_keys(view, "#outline .ol-head") ==
               ~w(card health list progress schedule actions)

      assert heading_keys(view, "#ol-#{epic.id}") ==
               ~w(card health list progress schedule actions)

      assert has_element?(
               view,
               "#outline[style*='--ol-cols: var(--cw-card, minmax(0, 1fr)) var(--cw-health, 6.5rem) var(--cw-list, 8rem)']"
             )

      # Moved back to its own place, the URL has no list at all.
      render_hook(view, "col_move", %{"id" => "health", "to" => "outline", "before" => nil})
      assert_patch(view, ~p"/boards/#{board}/outline")
    end

    test "a heading's edge sets a column's width", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/outline")

      render_hook(view, "col_width", %{"view" => "outline", "col" => "card", "width" => 420})
      assert has_element?(view, "#outline[style*='--cw-card: 420px']")
      assert_patch(view, ~p"/boards/#{board}/outline?outline_widths=card%3A420")
    end
  end

  describe "Prioritise" do
    setup do
      board = board_fixture(%{"name" => "Bets"})
      card_fixture(hd(board.columns), %{"title" => "Alpha"})
      {:ok, _} = Fields.install_preset(board, "rice")
      board = reload(board)
      rice = Enum.find(board.fields, &(&1.kind == "formula"))
      reach = hd(board.fields)
      %{board: board, rice: rice, reach: reach}
    end

    test "draws priority, votes and the scoring fields after the card", %{
      conn: conn,
      board: board,
      rice: rice,
      reach: reach
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/prioritise")
      keys = heading_keys(view, "#prioritise-table thead")

      assert Enum.take(keys, 3) == ["priority", "votes", "f:#{reach.id}"]
      assert List.last(keys) == "f:#{rice.id}"
      assert menu_keys(view, "prioritise") == keys
    end

    test "hides and moves its columns", %{conn: conn, board: board, rice: rice} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/prioritise")

      render_hook(view, "col_move", %{
        "id" => "f:#{rice.id}",
        "to" => "prioritise",
        "before" => "priority"
      })

      assert view |> heading_keys("#prioritise-table thead") |> Enum.take(3) ==
               ["f:#{rice.id}", "priority", "votes"]

      # Unticking Votes in the menu hides the column and its vote buttons.
      sent =
        for key <- menu_keys(view, "prioritise"),
            item <- if(key == "votes", do: ["-votes"], else: ["-" <> key, key]),
            do: item

      view |> form("#swim-config", %{"prio_cols" => sent}) |> render_change()
      refute "votes" in heading_keys(view, "#prioritise-table thead")
      refute has_element?(view, "#prioritise-table tbody [phx-click=prio_vote]")
    end

    test "a heading's edge sets a column's width", %{conn: conn, board: board, rice: rice} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/prioritise")

      render_hook(view, "col_width", %{
        "view" => "prioritise",
        "col" => "f:#{rice.id}",
        "width" => 140
      })

      assert has_element?(view, "#prioritise-table[style*='--cw-f-#{rice.id}: 140px']")
      assert has_element?(view, "#col-resize-prioritise-f-#{rice.id}")
    end
  end
end
