defmodule SlipdockWeb.ViewFieldFiltersLiveTest do
  @moduledoc """
  Custom-field filters kept in the address and a saved view (#3608): the
  board's toolbar and a view's Filter menu put them in the URL, a reload
  keeps them, a saved view reopens with them, and a filter on a field since
  deleted is dropped without an error.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields}
  alias Slipdock.Swimlanes.Config

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Contacts"}, owner: user)
    [_backlog, todo | _] = board.columns

    {:ok, stage} =
      Fields.create_field(board, %{
        "name" => "Stage",
        "kind" => "select",
        "options" => ["Lead", "Won"]
      })

    {:ok, size} = Fields.create_field(board, %{"name" => "Size", "kind" => "number"})

    won = card_fixture(todo, %{"title" => "Acme deal"})
    lead = card_fixture(todo, %{"title" => "Globex deal"})
    {:ok, _} = Fields.set_value(won, stage, "won")
    {:ok, _} = Fields.set_value(won, size, "40")
    {:ok, _} = Fields.set_value(lead, stage, "lead")
    {:ok, _} = Fields.set_value(lead, size, "5")

    %{conn: conn, board: board, stage: stage, size: size}
  end

  test "the board's field filter goes in the address, and a reload keeps it",
       %{conn: conn, board: board, stage: stage} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    view |> element(~s|[data-field-filter="stage"] button|, "Won") |> render_click()
    path = assert_patch(view)
    assert path =~ "field_filters"
    assert render(view) =~ "Acme deal"
    refute render(view) =~ "Globex deal"

    # The same address in a new tab.
    {:ok, reloaded, html} = live(conn, path)
    assert html =~ "Acme deal"
    refute html =~ "Globex deal"
    assert has_element?(reloaded, ~s|[data-field-filter="stage"] button.btn-primary|, "Won")

    # Clear all takes it out of the address too.
    render_click(reloaded, "clear_filters", %{})
    refute assert_patch(reloaded) =~ "field_filters"
    assert render(reloaded) =~ "Globex deal"
  end

  test "a table's field filter is saved with its view, which reopens with it",
       %{conn: conn, board: board, stage: stage, size: size} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    assert has_element?(view, ~s|#swim-config [data-field-filter="stage"]|)

    assert has_element?(
             view,
             ~s|#swim-config [data-field-filter="size"] input[name="field_filters[#{size.id}][min]"]|
           )

    view
    |> form("#swim-config", %{
      "field_filters" => %{to_string(size.id) => %{"min" => "10", "max" => ""}}
    })
    |> render_change()

    path = assert_patch(view)
    assert path =~ "field_filters"
    assert has_element?(view, "#card-table", "Acme deal")
    refute has_element?(view, "#card-table", "Globex deal")

    # A reload of the address keeps it.
    {:ok, reloaded, _} = live(conn, path)
    refute has_element?(reloaded, "#card-table", "Globex deal")

    render_hook(view, "swim_save_view", %{"name" => "Big ones"})

    [saved] =
      Boards.SavedViews.list_saved_views(board.id) |> Enum.filter(&(&1.name == "Big ones"))

    assert saved.config["field_filters"] == %{to_string(size.id) => %{"min" => 10}}

    {:ok, reopened, _} = live(conn, ~p"/boards/#{board}/table?view=#{saved.id}")
    assert has_element?(reopened, "#card-table", "Acme deal")
    refute has_element?(reopened, "#card-table", "Globex deal")

    assert has_element?(
             reopened,
             ~s|input[name="field_filters[#{size.id}][min]"][value="10"]|
           )

    # Unticking every control clears them, and the view shows as changed.
    reopened
    |> form("#swim-config", %{"field_filters" => %{to_string(stage.id) => %{"options" => []}}})
    |> render_change(%{"field_filters" => %{to_string(size.id) => %{"min" => "", "max" => ""}}})

    assert_patch(reopened)
    assert has_element?(reopened, "#card-table", "Globex deal")
  end

  test "a saved view filtering a field since deleted opens without it",
       %{conn: conn, board: board, stage: stage} do
    config =
      Config.from_query(
        %{"field_filters" => %{to_string(stage.id) => %{"options" => ["won"]}}},
        Config.defaults("table")
      )

    {:ok, saved} =
      Boards.SavedViews.create_saved_view(board, %{
        "name" => "Won",
        "config" => Config.to_map(config)
      })

    {:ok, _} = Fields.delete_field(stage)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?view=#{saved.id}")
    assert has_element?(view, "#card-table", "Acme deal")
    assert has_element?(view, "#card-table", "Globex deal")

    # And an address naming it, on the board itself.
    {:ok, board_view, html} =
      live(conn, "/boards/#{board.id}?field_filters[#{stage.id}][options][]=won")

    assert html =~ "Globex deal"
    refute has_element?(board_view, ~s|[data-field-filter="stage"]|)
  end
end
