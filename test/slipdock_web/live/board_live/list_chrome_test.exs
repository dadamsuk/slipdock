defmodule SlipdockWeb.BoardLive.ListChromeTest do
  @moduledoc """
  The list's own chrome recedes (#1710): a heart only on a favourite list,
  favouriting in the ⋯ menu, a labelled footer, one count badge style and a
  ghost "Add another list" as wide as a list.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Favourites}

  setup do
    board = board_fixture(%{"name" => "Plan"})
    [backlog, todo | _] = board.columns
    %{board: board, backlog: backlog, todo: todo}
  end

  defp header_heart(id),
    do: "#column-#{id} .column-handle > button[phx-click=toggle_favourite]"

  defp menu_item(id), do: "#favourite-list-#{id}"

  describe "favourite heart" do
    test "no list header carries a heart until the list is a favourite", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      for column <- board.columns do
        refute has_element?(view, header_heart(column.id))

        assert has_element?(
                 view,
                 "#{menu_item(column.id)}[aria-pressed=false]",
                 "Favourite this list"
               )
      end
    end

    test "favouriting from the ⋯ menu puts the heart on that header alone, and unfavouriting takes it off",
         %{conn: conn, board: board, todo: todo, backlog: backlog, user: user} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      view |> element(menu_item(todo.id)) |> render_click()

      assert Favourites.favourite?(Favourites.marks(user), :column, todo.id)
      assert has_element?(view, "#{header_heart(todo.id)}[aria-pressed=true]")

      assert has_element?(
               view,
               "#{menu_item(todo.id)}[aria-pressed=true]",
               "Remove from favourites"
             )

      refute has_element?(view, header_heart(backlog.id))

      # The header heart itself takes it off again, as before.
      view |> element(header_heart(todo.id)) |> render_click()

      refute Favourites.favourite?(Favourites.marks(user), :column, todo.id)
      refute has_element?(view, header_heart(todo.id))
      assert has_element?(view, menu_item(todo.id), "Favourite this list")
    end

    test "a list already favourited shows its heart when the board opens", %{
      conn: conn,
      board: board,
      todo: todo,
      user: user
    } do
      {:ok, :added} = Favourites.toggle(user, :column, todo.id)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      assert has_element?(view, "#{header_heart(todo.id)}[aria-pressed=true]")
    end

    test "a read-only member gets the ⋯ menu with favouriting and nothing that changes the list",
         %{board: board, todo: todo} do
      reader = user_fixture("list-chrome-reader@example.com")
      share_fixture(board, reader, "read")
      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}")

      assert has_element?(view, menu_item(todo.id), "Favourite this list")
      refute has_element?(view, "#column-#{todo.id} button[phx-click=edit_column]")
      refute has_element?(view, "#column-#{todo.id} button[phx-click=delete_column]")

      view |> element(menu_item(todo.id)) |> render_click()
      assert Favourites.favourite?(Favourites.marks(reader), :column, todo.id)
      assert has_element?(view, header_heart(todo.id))
    end

    test "a writer's ⋯ menu keeps its list actions beside favouriting", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      for action <- ~w(start_add_card edit_column delete_column),
          do: assert(has_element?(view, "#column-#{todo.id} li button[phx-click=#{action}]"))
    end
  end

  describe "count badge" do
    test "an empty list's count is a plain badge, not monospaced", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      badge = "#column-#{todo.id} [data-role=list-count]"

      assert has_element?(view, "#{badge}.badge-ghost", "0")
      refute has_element?(view, "#{badge}.font-mono")
    end

    test "a WIP limit tints the same badge at and over the limit", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      {:ok, _} = Boards.Columns.update_column(todo, %{"wip_limit" => 1})
      card_fixture(todo, %{"title" => "One"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      badge = "#column-#{todo.id} [data-role=list-count]"
      assert has_element?(view, "#{badge}.badge-warning.tabular-nums", "1/1")

      card_fixture(todo, %{"title" => "Two"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      assert has_element?(view, "#{badge}.badge-error.tabular-nums", "2/1")
      refute has_element?(view, "#{badge}.font-mono")
    end
  end

  describe "list footer" do
    test "Add card is labelled, and the page and file icons carry tooltips and names", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      {:ok, _} = Boards.update_board(board, %{"add_page" => true, "add_document" => true})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      footer = "#column-#{todo.id} [data-role=list-footer]"

      assert has_element?(
               view,
               ~s|#{footer} button[aria-label="Add a card to #{todo.name}"][title]|,
               "Add card"
             )

      assert has_element?(
               view,
               ~s|#{footer} a[aria-label="Add a page to #{todo.name}"][title^="Add page"]|
             )

      assert has_element?(
               view,
               ~s|#{footer} button[aria-label="Add a document to #{todo.name}"][title^="Attach file"]|
             )
    end

    test "a read-only member gets no footer at all", %{board: board, todo: todo} do
      reader = user_fixture("list-chrome-footer@example.com")
      share_fixture(board, reader, "read")
      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}")
      refute has_element?(view, "#column-#{todo.id} [data-role=list-footer]")
      refute has_element?(view, "[data-role=add-list]")
    end
  end

  describe "add another list" do
    test "is a ghost list as wide as the lists, inside a row that keeps its padding", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(view, "#columns.w-max.p-4")
      assert has_element?(view, "div.w-72 > button[data-role=add-list].border-dashed.text-sm")
      refute has_element?(view, "button[data-role=add-list].btn")
    end

    test "follows the lists' width when the Display width changes", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}?width=wide")

      assert has_element?(view, "#column-#{hd(board.columns).id}.w-96")
      assert has_element?(view, "div.w-96 > button[data-role=add-list]")
    end

    test "opens the new-list form and closes it again", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      view |> element("[data-role=add-list]") |> render_click()
      assert has_element?(view, "#add-column-input")
      refute has_element?(view, "[data-role=add-list]")

      render_keydown(view, "cancel_add_column", %{"key" => "Escape"})
      assert has_element?(view, "[data-role=add-list]")
    end
  end
end
