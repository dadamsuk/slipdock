defmodule SlipdockWeb.SwimlanesLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Favourites
  alias Slipdock.Boards
  alias Slipdock.Swimlanes.Config

  setup do
    board = board_fixture(%{"name" => "Swim"})
    [backlog, todo | _] = board.columns
    bug = tag_fixture(board, "bug", "red")
    a = card_fixture(backlog, %{"title" => "Alpha card", "priority" => "high"})

    b =
      card_fixture(todo, %{
        "title" => "Bravo card",
        "priority" => "low",
        "due_date" => "2030-01-15"
      })

    Boards.toggle_card_tag(a, bug)
    %{board: reload(board), a: a, b: b, bug: bug, backlog: backlog, todo: todo}
  end

  test "renders the default priority x list grid", %{conn: conn, board: board} do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/swimlanes")
    assert html =~ "Alpha card" and html =~ "Bravo card"
    assert has_element?(view, "#swim-grid")
    assert has_element?(view, "#swim-config select[name=rows] option[selected][value=priority]")
    assert has_element?(view, "#swim-config select[name=cols] option[selected][value=column]")
    # Row headers for the two priorities in use, column headers for the two lists in use.
    grid = view |> element("#swim-grid") |> render()
    assert grid =~ "High" and grid =~ "Low"
    refute grid =~ "Critical"
  end

  test "changing the configuration patches the URL and re-renders", %{
    conn: conn,
    board: board,
    bug: bug
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes")

    view |> form("#swim-config", %{"rows" => "tag", "cols" => "due_date"}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}/swimlanes?cols=due_date&rows=tag")
    assert render(view) =~ "14–20 Jan 2030"

    # The date unit selector appears once a date axis is in use.
    view
    |> form("#swim-config", %{"rows" => "tag", "cols" => "due_date", "unit" => "month"})
    |> render_change()

    assert_patch(view, ~p"/boards/#{board}/swimlanes?cols=due_date&rows=tag&unit=month")
    html = render(view)
    assert html =~ "No tag" and html =~ "Jan 2030" and html =~ "No due date"
    assert has_element?(view, "select[name=unit] option[selected][value=month]")

    # Filters: only the bug-tagged card remains, and the row for it shows.
    view
    |> form("#swim-config", %{
      "rows" => "tag",
      "cols" => "due_date",
      "tags" => [to_string(bug.id)]
    })
    |> render_change()

    assert_patch(
      view,
      ~p"/boards/#{board}/swimlanes?cols=due_date&rows=tag&tags=#{bug.id}&unit=month"
    )

    html = render(view)
    assert html =~ "Alpha card"
    refute html =~ "Bravo card"
    assert html =~ "1 hidden"

    view |> element("button", "Clear all filters") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/swimlanes?cols=due_date&rows=tag&unit=month")
  end

  test "opening a card keeps the configuration in the URL", %{conn: conn, board: board, a: a} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes?rows=tag")
    view |> element("#swim-grid [id$='-card-#{a.id}']") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/swimlanes/cards/#{a.id}?rows=tag")
    assert has_element?(view, "#card-modal")
    assert has_element?(view, "#card-modal a[href='/boards/#{board.id}/swimlanes/tags?rows=tag']")
  end

  test "dragging between cells updates the card's attributes", %{
    conn: conn,
    board: board,
    a: a,
    todo: todo
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes?empty=show")
    # rows = priorities in fixed order (critical, high, medium, low, none); cols = lists.
    # Alpha is high (row 1) in Backlog (col 0); drop it into critical (row 0) / To Do (col 1).
    render_hook(view, "swim_move", %{
      "id" => to_string(a.id),
      "from" => "1:0",
      "to" => "0:1",
      "before" => nil
    })

    card = Boards.get_card!(a.id)
    assert card.priority == "critical"
    assert card.column_id == todo.id
  end

  test "dragging onto a created-date bucket is refused", %{conn: conn, board: board, a: a} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes?rows=created&cols=none&unit=year")

    html =
      render_hook(view, "swim_move", %{"id" => to_string(a.id), "from" => "0:0", "to" => "0:0"})

    refute html =~ "can&#39;t be moved"

    {:ok, view, _} =
      live(conn, ~p"/boards/#{board}/swimlanes?rows=created&cols=none&unit=year&empty=show")

    render_hook(view, "swim_move", %{"id" => to_string(a.id), "from" => "0:0", "to" => "0:0"})
    assert Boards.get_card!(a.id).priority == "high"
  end

  test "quick add inside a cell sets the axis attributes", %{conn: conn, board: board, todo: todo} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes?rows=flag&cols=column&empty=show")
    # rows: flagged, blocked, review, waiting, starred, none; cols: the four lists.
    view |> element("#swim-cell-1-1 button", "Add") |> render_click()
    view |> form("#swim-cell-1-1 form", %{"title" => "Fresh card"}) |> render_submit()

    card =
      board
      |> reload()
      |> Map.get(:columns)
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(&1.title == "Fresh card"))

    assert card.flags == ["blocked"]
    assert card.column_id == todo.id
  end

  test "saving, loading, updating and deleting a view", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes?rows=tag&sort=title")

    view
    |> form("#swim-config", %{"rows" => "tag", "cols" => "column", "sort" => "title"})
    |> render_change()

    view |> form("form[phx-submit=swim_save_view]", %{"name" => "By tag"}) |> render_submit()
    [saved] = Boards.list_saved_views(board.id)
    assert Config.from_map(saved.config) == %Config{rows: "tag", sort: "title"}
    assert_patch(view, ~p"/boards/#{board}/swimlanes?view=#{saved.id}")
    assert render(view) =~ "By tag"
    refute render(view) =~ "modified"

    # Tweaking a loaded view marks it modified and only the delta goes in the URL.
    view
    |> form("#swim-config", %{"rows" => "tag", "cols" => "column", "sort" => "due_date"})
    |> render_change()

    assert_patch(view, ~p"/boards/#{board}/swimlanes?sort=due_date&view=#{saved.id}")
    assert render(view) =~ "modified"

    view |> element("button[title='Save these settings to the view']") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/swimlanes?view=#{saved.id}")
    assert Config.from_map(Boards.get_saved_view!(saved.id).config).sort == "due_date"
    refute render(view) =~ "modified"

    view |> form("form[phx-submit=swim_rename_view]", %{"name" => "Renamed"}) |> render_submit()
    assert Boards.get_saved_view!(saved.id).name == "Renamed"
    assert render(view) =~ "Renamed"

    view |> element("button[phx-click=swim_delete_view]") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/swimlanes?rows=tag&sort=due_date")
    assert Boards.list_saved_views(board.id) == []
  end

  test "favourite views are listed in the view switcher", %{conn: conn, board: board, user: user} do
    {:ok, saved} =
      Boards.create_saved_view(board, %{
        "name" => "By tag",
        "config" => %{"mode" => "swimlanes", "rows" => "tag"}
      })

    href = "/boards/#{board.id}/swimlanes?view=#{saved.id}"
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes?view=#{saved.id}")
    refute has_element?(view, "#view-menu a[href='#{href}']")

    heart = "button[phx-click=toggle_favourite][phx-value-kind=view][phx-value-id='#{saved.id}']"
    view |> element(heart) |> render_click()
    assert Favourites.favourite?(Favourites.marks(user), :view, saved.id)
    assert has_element?(view, "#view-menu a[href='#{href}']", "By tag")
    assert has_element?(view, "#{heart}[aria-pressed=true]")

    # Every mode's switcher lists it, opening it in the mode it was saved from.
    {:ok, board_view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(board_view, "#view-menu a[href='#{href}']", "By tag")

    view |> element(heart) |> render_click()
    refute Favourites.favourite?(Favourites.marks(user), :view, saved.id)
    refute has_element?(view, "#view-menu a[href='#{href}']")
  end

  test "Reset to defaults drops the loaded view and every changed option", %{
    conn: conn,
    board: board
  } do
    {:ok, saved} =
      Boards.create_saved_view(board, %{
        "name" => "By tag",
        "config" => %{"mode" => "swimlanes", "rows" => "tag"}
      })

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes?view=#{saved.id}&sort=title")
    assert has_element?(view, "#swim-config select[name=rows] option[selected][value=tag]")

    view |> element("a", "Reset to defaults") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/swimlanes")
    assert has_element?(view, "#swim-config select[name=rows] option[selected][value=priority]")
    assert has_element?(view, "#swim-config select[name=sort] option[selected][value=position]")
    refute render(view) =~ "hero-bookmark-solid"

    # The board view resets to its own defaults.
    {:ok, board_view, _} = live(conn, ~p"/boards/#{board}?density=compact")
    board_view |> element("a", "Reset to defaults") |> render_click()
    assert_patch(board_view, ~p"/boards/#{board}")
  end

  test "a missing view falls back to the defaults with a flash", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes")
    render_patch(view, ~p"/boards/#{board}/swimlanes?view=999")
    assert_patch(view, ~p"/boards/#{board}/swimlanes")
    assert render(view) =~ "no longer exists"
    assert has_element?(view, "#swim-grid")
  end

  test "the board view still works and links to swimlanes", %{conn: conn, board: board} do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}")
    assert html =~ "Alpha card"
    assert has_element?(view, "a[href='/boards/#{board.id}/swimlanes']", "Swimlanes")
    refute has_element?(view, "#swim-grid")
  end
end
