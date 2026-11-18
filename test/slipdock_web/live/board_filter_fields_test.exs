defmodule SlipdockWeb.BoardFilterFieldsTest do
  @moduledoc """
  The board's Filter menu offers the tree's custom fields (#3369), each with a
  control that suits its kind, and setting one hides the cards whose value
  doesn't meet it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Fields

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Fielded"}, owner: user)
    [_backlog, todo | _] = board.columns

    {:ok, size} =
      Fields.create_field(board, %{"name" => "Size", "kind" => "select", "options" => ["S", "L"]})

    {:ok, effort} = Fields.create_field(board, %{"name" => "Effort", "kind" => "number"})
    {:ok, note} = Fields.create_field(board, %{"name" => "Note", "kind" => "text"})

    small = card_fixture(todo, %{"title" => "Small job"})
    large = card_fixture(todo, %{"title" => "Large job"})
    card_fixture(todo, %{"title" => "Unsized job"})

    {:ok, _} = Fields.set_value(small, size, "s")
    {:ok, _} = Fields.set_value(small, effort, "1")
    {:ok, _} = Fields.set_value(large, size, "l")
    {:ok, _} = Fields.set_value(large, effort, "8")
    {:ok, _} = Fields.set_value(large, note, "Needs the backend")

    %{conn: conn, board: board, size: size, effort: effort, note: note}
  end

  test "each field shows a control suited to its kind", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

    assert has_element?(view, ~s|[data-field-filter="size"] button|, "S")
    assert has_element?(view, ~s|[data-field-filter="size"] button|, "L")

    assert has_element?(
             view,
             ~s|form[data-field-filter="effort"] input[type="number"][name="min"]|
           )

    assert has_element?(
             view,
             ~s|form[data-field-filter="effort"] input[type="number"][name="max"]|
           )

    assert has_element?(view, ~s|form[data-field-filter="note"] input[type="text"][name="text"]|)
  end

  test "a board with no fields has no Fields section", %{conn: conn, user: user} do
    bare = board_fixture(%{"name" => "Bare"}, owner: user)
    {:ok, view, _html} = live(conn, ~p"/boards/#{bare}")
    refute has_element?(view, ~s|[data-role="filter-fields"]|)
  end

  test "a choice filter hides the cards without that option, and Clear brings them back",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

    view |> element(~s|[data-field-filter="size"] button|, "L") |> render_click()
    html = render(view)
    assert html =~ "Large job"
    refute html =~ "Small job"
    refute html =~ "Unsized job"

    render_click(view, "clear_filters", %{})
    html = render(view)
    assert html =~ "Small job" and html =~ "Unsized job"
  end

  test "a number range and a text filter narrow the cards together",
       %{conn: conn, board: board, effort: effort, note: note} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

    view
    |> form(~s|form[data-field-filter="effort"]|, %{"min" => "", "max" => "5"})
    |> render_change(%{"field" => effort.id})

    html = render(view)
    assert html =~ "Small job"
    refute html =~ "Large job"

    view
    |> form(~s|form[data-field-filter="note"]|, %{"text" => "backend"})
    |> render_change(%{"field" => note.id})

    html = render(view)
    refute html =~ "Small job"
    refute html =~ "Large job"
  end

  test "a date filter takes a from date, drawn as the app's date field",
       %{conn: conn, board: board} do
    {:ok, launch} = Fields.create_field(board, %{"name" => "Launch", "kind" => "date"})
    [_backlog, todo | _] = board.columns
    early = card_fixture(todo, %{"title" => "Early launch"})
    late = card_fixture(todo, %{"title" => "Late launch"})
    {:ok, _} = Fields.set_value(early, launch, "2026-01-10")
    {:ok, _} = Fields.set_value(late, launch, "2027-06-01")

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, ~s|form[data-field-filter="launch"] [phx-hook="DateField"]|)

    view
    |> form(~s|form[data-field-filter="launch"]|, %{"from" => "2027-01-01", "to" => ""})
    |> render_change()

    html = render(view)
    assert html =~ "Late launch"
    refute html =~ "Early launch"
    refute html =~ "Small job"
  end

  test "a field from another board is ignored", %{conn: conn, board: board, user: user} do
    other = board_fixture(%{"name" => "Other"}, owner: user)
    {:ok, foreign} = Fields.create_field(other, %{"name" => "Foreign", "kind" => "text"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_click(view, "filter_field", %{"field" => foreign.id, "text" => "x"})
    assert render(view) =~ "Unsized job"
  end
end
