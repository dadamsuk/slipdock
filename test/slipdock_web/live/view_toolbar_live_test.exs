defmodule SlipdockWeb.ViewToolbarLiveTest do
  @moduledoc """
  One toolbar for every board view (#1711): `view_toolbar/1` lays out the
  board's toolbar and `swim_toolbar/1` alike, in one order, with search in
  the same place on each. The view's own controls sit in a View options
  group that the `ToolbarFold` hook folds into a popover when the row would
  wrap; they stay in the `swim-config` form, so they still post. The fold
  itself, and the one-row height, are measured in Chromium by
  `tools/e2e/toolbar-one-row.sh`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.SwimlaneComponents

  @order SwimlaneComponents.toolbar_order()

  setup do
    board = board_fixture(%{"name" => "Toolbars", "code" => "vtbr"})
    [todo | _] = board.columns
    card_fixture(todo, %{"title" => "One card"})
    %{board: board}
  end

  # The toolbar's parts, in document order, by their `data-tb` marks.
  defp parts(view, toolbar \\ "[phx-hook=ToolbarFold]") do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{toolbar} [data-tb]")
    |> LazyHTML.attribute("data-tb")
  end

  defp at(board, ""), do: ~p"/boards/#{board}"
  defp at(board, suffix), do: "/boards/#{board.id}/#{suffix}"

  defp board_owner(board), do: Slipdock.Repo.get!(Slipdock.Accounts.User, board.owner_id)

  describe "the order" do
    test "toolbar_order/0 is the card's order" do
      assert @order ==
               ~w(switcher search filter nav view-options display count select views actions)
    end

    for {mode, suffix, extra} <- [
          {:board, "", ~w(select)},
          {:swimlanes, "swimlanes", ~w(view-options)},
          {:table, "table", ~w(view-options)},
          {:timeline, "timeline", ~w(nav view-options)},
          {:calendar, "calendar", ~w(nav view-options)},
          {:outline, "outline", ~w(view-options)},
          {:narrative, "narrative", ~w(view-options)},
          {:prioritise, "prioritise", ~w(view-options)}
        ] do
      test "#{mode}: switcher, search, Filter, its own, Display, then count, Views, actions",
           %{conn: conn, board: board} do
        {:ok, view, _} = live(conn, at(board, unquote(suffix)))
        got = parts(view)

        want =
          Enum.filter(
            @order,
            &(&1 in (~w(switcher search filter display count views actions) ++ unquote(extra)))
          )

        assert got == want, "#{unquote(mode)}: #{Enum.join(got, " · ")}"
        # Search is second on every view, right after the switcher.
        assert Enum.take(got, 2) == ~w(switcher search)
        assert has_element?(view, "[phx-hook=ToolbarFold][data-mode=#{unquote(mode)}]")
      end
    end

    test "the board's toolbar keeps its id, and has nothing to fold", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(view, "#board-toolbar.view-toolbar[phx-hook=ToolbarFold]")
      refute has_element?(view, "#view-options-toggle")
      refute has_element?(view, "#tools-toggle")
      # The board's search and Display each post their own form.
      assert has_element?(view, "#board-toolbar [data-tb=search] form#board-search")
      assert has_element?(view, "#board-toolbar [data-tb=display] form#swim-config")
    end

    test "every other view's middle is one swim-config form", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, at(board, "timeline"))

      for tb <- ~w(search filter nav view-options display) do
        assert has_element?(view, "#view-toolbar form#swim-config [data-tb=#{tb}]"), tb
      end

      for tb <- ~w(switcher count views actions) do
        refute has_element?(view, "#view-toolbar form#swim-config [data-tb=#{tb}]"), tb
      end
    end

    test "a reader without write has no Select on the board", %{board: board} do
      reader = user_fixture("toolbar-reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", board_owner(board))
      {:ok, view, _} = live(log_in_user(build_conn(), reader), ~p"/boards/#{board}")

      assert parts(view) == ~w(switcher search filter display count views actions)
    end

    test "a shared view's reader gets its name, no search or own controls, still in order",
         %{board: board} do
      {:ok, saved} =
        Boards.create_saved_view(board, %{
          "name" => "Just this",
          "config" => Config.to_map(Config.defaults("table"))
        })

      other = user_fixture("toolbar-sharee@example.com")
      {:ok, _} = Access.grant(saved, other, "read", board_owner(board))

      {:ok, view, html} =
        live(log_in_user(build_conn(), other), "/boards/#{board.id}/table?view=#{saved.id}")

      assert html =~ "Shared view" and html =~ "Just this"
      got = parts(view)
      assert got == Enum.filter(@order, &(&1 in got))
      refute "search" in got
      refute "view-options" in got
      refute has_element?(view, "#swim-config")
      refute has_element?(view, "#view-options-toggle")
    end
  end

  describe "View options" do
    test "holds the view's own controls inside the form, behind a toggle", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, at(board, "narrative"))

      assert has_element?(
               view,
               "#swim-config #swim-tools [data-tb=view-options] #view-options-toggle[type=button][aria-expanded=false][aria-controls=view-options]"
             )

      for name <- ~w(rows span from to sort) do
        assert has_element?(view, "#swim-config #view-options [name=#{name}]"), name
      end

      # Display sits beside View options, never in it.
      refute has_element?(view, "#view-options #display-menu")
      assert has_element?(view, "#swim-tools > [data-tb=display] #display-menu")
      # The phone's Options button opens the drawer that holds them both.
      assert has_element?(view, "#tools-toggle")
    end

    test "a folded select still posts with the form", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, at(board, "narrative"))

      view |> form("#swim-config", %{"span" => "30"}) |> render_change()

      assert_patch(view) =~ "span=30"
      assert has_element?(view, "#view-options select[name=span] option[value='30'][selected]")
    end

    test "the sort direction button posts its value from the popover", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, at(board, "outline"))
      button = "#view-options button[phx-value-key=dir]"

      [before] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(button)
        |> LazyHTML.attribute("value")

      # The button's own value matches what it pushes: a real browser sends both.
      assert has_element?(view, "#{button}[phx-value-value=#{before}]")

      view |> element(button) |> render_click()

      assert assert_patch(view) =~ "dir=#{before}"
      flipped = if before == "asc", do: "desc", else: "asc"
      assert has_element?(view, "#{button}[value=#{flipped}]")
    end

    test "searching keeps the folded controls' values", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, at(board, "narrative") <> "?span=7")

      view |> form("#swim-config", %{"q" => "One"}) |> render_change()

      patched = assert_patch(view)
      assert patched =~ "q=One" and patched =~ "span=7"
    end
  end

  describe "view_toolbar/1 on its own" do
    test "with nothing of its own: no toggle, no drawer, no form, one row on a phone" do
      html =
        render_component(&SwimlaneComponents.view_toolbar/1,
          id: "t",
          mode: :board,
          shown: 1,
          hidden: 0,
          search: [%{inner_block: fn _, _ -> "S" end}],
          display: [%{inner_block: fn _, _ -> "D" end}]
        )

      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.query(doc, "#t [data-tb]") |> LazyHTML.attribute("data-tb") ==
               ~w(search display count)

      assert LazyHTML.query(doc, "#t.max-sm\\:flex-nowrap") |> Enum.count() == 1

      assert LazyHTML.query(doc, "form, #view-options-toggle, #tools-toggle, #swim-tools")
             |> Enum.count() == 0

      assert html =~ "1 card"
      refute html =~ "hidden</span>"
    end

    test "with controls of its own: a form, the toggle, the drawer, and it may wrap to open it" do
      html =
        render_component(&SwimlaneComponents.view_toolbar/1,
          mode: :table,
          shown: 3,
          hidden: 2,
          form: "f",
          own: [%{inner_block: fn _, _ -> "O" end}]
        )

      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.query(doc, "#view-toolbar form#f #swim-tools #view-options") |> Enum.count() ==
               1

      assert LazyHTML.query(doc, "#tools-toggle[aria-label]") |> Enum.count() == 1
      assert LazyHTML.query(doc, "#view-toolbar.max-sm\\:flex-nowrap") |> Enum.count() == 0
      # No Display given: none drawn, in the drawer or out of it.
      assert LazyHTML.query(doc, "[data-tb=display]") |> Enum.count() == 0
      assert html =~ "3 cards" and html =~ "2 hidden"
    end
  end
end
