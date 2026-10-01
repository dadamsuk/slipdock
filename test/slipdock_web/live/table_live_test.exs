defmodule SlipdockWeb.TableLiveTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Table

  setup do
    board = board_fixture(%{"name" => "Tabular"})
    [backlog, todo | _] = board.columns
    bug = tag_fixture(board, "bug", "red")

    a =
      card_fixture(backlog, %{
        "title" => "Alpha",
        "priority" => "high",
        "due_date" => "2030-01-15"
      })

    b = card_fixture(todo, %{"title" => "Bravo", "priority" => "low"})
    Boards.toggle_card_tag(a, bug)
    %{board: reload(board), a: a, b: b, todo: todo}
  end

  test "Table.rows and Config defaults", %{board: board} do
    assert %Config{mode: "table", rows: "none", cols: "none"} = Config.defaults("table")
    rows = Table.rows(board, Config.defaults("table"))
    assert rows.grouped == false and rows.shown == 2
    assert [%{label: "All cards", cards: [%{title: "Alpha"}, %{title: "Bravo"}]}] = rows.groups

    rows = Table.rows(board, %{Config.defaults("table") | rows: "priority"})

    assert Enum.map(rows.groups, &{&1.label, Enum.map(&1.cards, fn c -> c.title end)}) == [
             {"High", ["Alpha"]},
             {"Low", ["Bravo"]}
           ]

    assert Enum.map(Table.visible_fields(%Config{fields: ["due_date", "id"]}), &elem(&1, 0)) == [
             "title",
             "due_date",
             "id"
           ]

    assert Config.from_query(%{"fields" => "id,bogus,tags"}).fields == ["tags", "id"]
    # A submitted form without a fields chooser keeps the current fields.
    assert Config.from_form(%{"rows" => "tag"}, %Config{fields: ["id"]}).fields == ["id"]
  end

  test "renders, sorts by header, groups, and edits inline", %{
    conn: conn,
    board: board,
    a: a,
    todo: todo
  } do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/table")
    assert html =~ "Alpha" and html =~ "Bravo"
    assert has_element?(view, "#card-table thead th [role=button]", "Title")
    refute has_element?(view, "#card-table tbody tr td button", "All cards")

    # Click the Title header twice: ascending, then descending.
    view |> element("th [phx-value-sort=title]") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/table?sort=title")
    view |> element("th [phx-value-sort=title]") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/table?dir=desc&sort=title")
    rows = view |> element("#card-table") |> render()
    assert :binary.match(rows, "Bravo") |> elem(0) < :binary.match(rows, "Alpha") |> elem(0)

    # Group by list.
    view |> form("#swim-config", %{"rows" => "column"}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}/table?dir=desc&rows=column&sort=title")
    assert has_element?(view, "#group-#{todo.id} [role=button]", "To Do")

    # Columns chooser: drop tags, add id.
    view
    |> form("#swim-config", %{"rows" => "column", "fields" => ["title", "id"]})
    |> render_change()

    assert_patch(
      view,
      ~p"/boards/#{board}/table?dir=desc&fields=title%2Cid&rows=column&sort=title"
    )

    refute has_element?(view, "#card-table thead th", "Tags")
    assert has_element?(view, "#card-table thead th", "ID")

    # Inline edits: priority select, due date, list, done.
    view
    |> form("#swim-config", %{
      "rows" => "none",
      "fields" => ["title", "column", "priority", "due_date", "completed"]
    })
    |> render_change()

    view |> form("#prio-#{a.id}", %{"value" => "critical"}) |> render_change()
    assert Boards.get_card!(a.id).priority == "critical"
    view |> form("#due-#{a.id}", %{"value" => ""}) |> render_change()
    assert is_nil(Boards.get_card!(a.id).due_date)
    view |> form("#col-#{a.id}", %{"value" => to_string(todo.id)}) |> render_change()
    assert Boards.get_card!(a.id).column_id == todo.id
    view |> element("#row-all-#{a.id} input[type=checkbox]") |> render_click()
    assert Boards.get_card!(a.id).completed

    # Quick add at the bottom and opening a card keep the table URL.
    view |> form("form[id^=table-add]", %{"title" => "Charlie"}) |> render_submit()

    assert board
           |> reload()
           |> Map.get(:columns)
           |> Enum.flat_map(& &1.cards)
           |> Enum.any?(&(&1.title == "Charlie"))

    view
    |> element("#card-table [phx-click=open_card][phx-value-id='#{a.id}']")
    |> render_click()

    assert_patch(
      view,
      ~p"/boards/#{board}/table/cards/#{a.id}?dir=desc&fields=title%2Ccolumn%2Cpriority%2Cdue_date%2Ccompleted&sort=title"
    )

    assert has_element?(view, "#card-modal")
  end

  test "saved views remember the table mode", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?rows=priority")
    view |> form("form[phx-submit=swim_save_view]", %{"name" => "By priority"}) |> render_submit()
    [saved] = Boards.list_saved_views(board.id)
    assert saved.config["mode"] == "table" and saved.config["rows"] == "priority"
    assert_patch(view, ~p"/boards/#{board}/table?view=#{saved.id}")

    # From the swimlane page the view's link points back at the table.
    {:ok, swim, _} = live(conn, ~p"/boards/#{board}/swimlanes")

    assert has_element?(
             swim,
             "a[href='/boards/#{board.id}/table?view=#{saved.id}']",
             "By priority"
           )
  end
end
