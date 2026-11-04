defmodule SlipdockWeb.Components.CardTitleTest do
  @moduledoc """
  The card face's title (#1707): 14px on a comfortable card and 12px on a
  compact one, and flush with the tags and the meta row. The complete toggle
  comes after the title, so neither hiding it (until hover or focus) nor
  showing it (on a touch screen) moves the title. The same `card/1` draws the
  board, the swimlanes and a sub-board. tools/e2e/card-title.sh measures the
  x positions in a browser.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{user: user} do
    board = board_fixture(%{"name" => "Titles", "code" => "ttl1707"}, owner: user)
    [todo | _] = board.columns
    tag = tag_fixture(board, "Design")
    card = card_fixture(todo, %{"title" => "Paint the shed", "due_date" => "2030-01-15"})
    {:ok, _} = Boards.set_card_tags(card, [tag])
    done = card_fixture(todo, %{"title" => "Buy the paint", "completed" => true})
    %{board: board, card: card, done: done}
  end

  defp card_node(html, card) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#card-#{card.id}")
  end

  defp classes(node, selector) do
    node
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> Enum.flat_map(&String.split/1)
  end

  # The children of the comfortable card's title row, in order, by data-role.
  defp title_row_roles(node) do
    node
    |> LazyHTML.query(":has(> [data-role=card-title]) > *")
    |> Enum.map(fn child ->
      case LazyHTML.attribute(child, "data-role") do
        [role] -> role
        [] -> LazyHTML.tag(child) |> hd()
      end
    end)
  end

  describe "a comfortable card" do
    test "draws the title at text-sm, not the old 12px or 11px", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")
      title = classes(card_node(html, card), "[data-role=card-title]")

      assert "text-sm" in title
      refute "text-xs" in title
      refute "text-2xs" in title
    end

    test "starts the title row with the title: the toggle comes after it", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")
      roles = title_row_roles(card_node(html, card))

      assert hd(roles) == "card-title"
      assert "complete-toggle" in roles
      assert Enum.find_index(roles, &(&1 == "complete-toggle")) > 0
    end

    test "hides an open card's toggle until hover or focus, and always shows it on touch", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")
      toggle = classes(card_node(html, card), "[data-role=complete-toggle]")

      assert "opacity-0" in toggle
      assert "group-hover:opacity-100" in toggle
      assert "focus-visible:opacity-100" in toggle
      assert "group-focus-within:opacity-100" in toggle
      assert "no-hover:opacity-100" in toggle
    end

    test "a done card keeps its check, always visible, and a muted title", %{
      conn: conn,
      board: board,
      done: done
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}?completed=show")
      node = card_node(html, done)
      toggle = classes(node, "[data-role=complete-toggle]")

      assert "text-success" in toggle
      refute "opacity-0" in toggle
      assert "text-base-content/70" in classes(node, "[data-role=card-title]")
      assert LazyHTML.query(node, "[aria-label='Mark incomplete']") |> Enum.count() == 1
    end

    test "the toggle still completes the card", %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      view
      |> element("#card-#{card.id} [data-role=complete-toggle]")
      |> render_click()

      assert Boards.get_card!(card.id).completed
    end
  end

  describe "the same face elsewhere" do
    test "swimlanes draw the title at text-sm, title first", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/swimlanes")

      node =
        html |> LazyHTML.from_document() |> LazyHTML.query("[id^=swim-][id$='-card-#{card.id}']")

      assert Enum.count(node) == 1

      assert "text-sm" in classes(node, "[data-role=card-title]")
      assert hd(title_row_roles(node)) == "card-title"
    end

    test "a sub-board draws the title at text-sm, title first", %{conn: conn, card: card} do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card, t)
      sub = Boards.get_board!(sub.id)
      child = card_fixture(hd(sub.columns), %{"title" => "Sand the boards"})

      {:ok, _view, html} = live(conn, ~p"/boards/#{sub}")
      node = card_node(html, child)

      assert "text-sm" in classes(node, "[data-role=card-title]")
      assert hd(title_row_roles(node)) == "card-title"
    end
  end

  describe "a compact card" do
    test "draws the title at 12px (text-xs)", %{conn: conn, board: board, card: card} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}?density=compact")
      title = classes(card_node(html, card), "[data-role=card-title]")

      assert "text-xs" in title
      refute "text-2xs" in title
      refute "text-sm" in title
    end

    test "keeps a labelled toggle that completes the card", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, view, html} = live(conn, ~p"/boards/#{board}?density=compact")
      node = card_node(html, card)
      assert LazyHTML.query(node, "[aria-label='Mark complete']") |> Enum.count() == 1

      view
      |> element("#card-#{card.id} [data-role=complete-toggle]")
      |> render_click()

      assert Boards.get_card!(card.id).completed
    end
  end
end
