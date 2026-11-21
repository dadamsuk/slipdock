defmodule SlipdockWeb.CheckboxFieldLiveTest do
  @moduledoc """
  A checkbox custom field in the board's pages (#3612): the toolbar's On and
  Off, a view's Any / On / Off, the swimlane axis and a drag between its
  lanes, the table's editor, and the card front's chip. An empty checkbox
  counts as off in each.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Invoices"}, owner: user)
    [_backlog, todo | _] = board.columns

    {:ok, paid} = Fields.create_field(board, %{"name" => "Paid", "kind" => "checkbox"})

    checked = card_fixture(todo, %{"title" => "Checked invoice"})
    empty = card_fixture(todo, %{"title" => "Empty invoice"})
    {:ok, _} = Fields.set_value(checked, paid, "true")

    %{conn: conn, board: board, paid: paid, checked: checked, empty: empty}
  end

  defp paid?(card, paid), do: Fields.value(Boards.Cards.get_card!(card.id), paid) == 1.0

  test "the toolbar's Off keeps the empty card, a reload keeps it, and Off again clears it",
       %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    view |> element(~s|[data-field-filter="paid"] button|, "Off") |> render_click()
    path = assert_patch(view)
    assert render(view) =~ "Empty invoice"
    refute render(view) =~ "Checked invoice"

    # Off survives the address, which says false.
    {:ok, reloaded, html} = live(conn, path)
    assert html =~ "Empty invoice"
    refute html =~ "Checked invoice"
    assert has_element?(reloaded, ~s|[data-field-filter="paid"] button.btn-primary|, "Off")

    reloaded |> element(~s|[data-field-filter="paid"] button|, "Off") |> render_click()
    assert_patch(reloaded)
    assert render(reloaded) =~ "Checked invoice"

    reloaded |> element(~s|[data-field-filter="paid"] button|, "On") |> render_click()
    assert_patch(reloaded)
    assert render(reloaded) =~ "Checked invoice"
    refute render(reloaded) =~ "Empty invoice"
  end

  test "a view's Filter menu offers Any, On and Off; Off keeps the empty card",
       %{conn: conn, board: board, paid: paid} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    radio = ~s|#swim-config [data-field-filter="paid"] input[type="radio"]|
    name = "field_filters[#{paid.id}][checked]"
    assert has_element?(view, ~s|#{radio}[name="#{name}"][value=""][checked]|)
    assert has_element?(view, ~s|#{radio}[name="#{name}"][value="true"]|)

    view
    |> form("#swim-config", %{"field_filters" => %{to_string(paid.id) => %{"checked" => "false"}}})
    |> render_change()

    path = assert_patch(view)
    assert has_element?(view, "#card-table", "Empty invoice")
    refute has_element?(view, "#card-table", "Checked invoice")

    {:ok, reloaded, _} = live(conn, path)
    assert has_element?(reloaded, ~s|#{radio}[value="false"][checked]|)
    refute has_element?(reloaded, "#card-table", "Checked invoice")

    # Any clears it.
    reloaded
    |> form("#swim-config", %{"field_filters" => %{to_string(paid.id) => %{"checked" => ""}}})
    |> render_change()

    assert_patch(reloaded)
    assert has_element?(reloaded, "#card-table", "Checked invoice")
  end

  test "as a swimlane axis the empty card is in the Not lane, and a drag sets and clears it",
       %{conn: conn, board: board, paid: paid, checked: checked, empty: empty} do
    {:ok, view, html} =
      live(conn, ~p"/boards/#{board}/swimlanes?rows=f:#{paid.id}&cols=none&empty=show")

    assert html =~ "✓ Paid"
    assert html =~ "Not Paid"
    refute html =~ "No paid"

    # Rows: ✓ Paid (0), Not Paid (1). The empty card is dragged up to on.
    render_hook(view, "swim_move", %{"id" => to_string(empty.id), "from" => "1:0", "to" => "0:0"})
    assert paid?(empty, paid)

    render_hook(view, "swim_move", %{
      "id" => to_string(checked.id),
      "from" => "0:0",
      "to" => "1:0"
    })

    refute paid?(checked, paid)
    assert Boards.Cards.get_card!(checked.id).field_values == []
  end

  test "the table's editor is a checkbox that sets and clears it",
       %{conn: conn, board: board, paid: paid, empty: empty} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,f:#{paid.id}")
    cell = "#row-all-#{empty.id} [data-field-cell=paid]"
    assert has_element?(view, ~s|#{cell} input[type="hidden"][name="value"][value="false"]|)
    refute has_element?(view, ~s|#{cell} input[type="checkbox"][checked]|)

    view |> element("#{cell} form") |> render_change(%{"value" => "true"})
    assert paid?(empty, paid)
    assert has_element?(view, ~s|#{cell} input[type="checkbox"][checked]|)

    view |> element("#{cell} form") |> render_change(%{"value" => "false"})
    refute paid?(empty, paid)
  end

  test "the card front shows ✓ Paid on a checked card only",
       %{conn: conn, board: board, paid: paid, checked: checked, empty: empty} do
    {:ok, _} = Fields.update_field(paid, %{"show_on_cards" => true})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    assert has_element?(
             view,
             ~s|#card-#{checked.id} [data-role="card-fields"] [data-field="paid"]|,
             "✓ Paid"
           )

    refute has_element?(view, ~s|#card-#{empty.id} [data-field="paid"]|)
  end
end
