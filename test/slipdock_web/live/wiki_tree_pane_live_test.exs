defmodule SlipdockWeb.WikiTreePaneLiveTest do
  @moduledoc """
  The wiki's tree on a wide screen (#737): a button folds it away and back,
  and a handle on its edge drags it wider or narrower. Both are drawn here
  and worked by hooks (assets/js/wiki_pane.js, tested in wiki_pane.test.js),
  which keep the choice in the browser; what the server owes them is the
  markup, kept out of LiveView's patches so what the hooks set stays set.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup %{user: user} do
    board = board_fixture(%{"name" => "Wide", "code" => "widetree"}, owner: user)
    page = page_fixture(board, %{"title" => "Notes"})
    %{board: board, page: page}
  end

  test "the fold-away button is on wide screens only, and its state is the hook's", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    assert has_element?(
             view,
             "#wiki-tree-collapse-keep.hidden.lg\\:inline-flex[phx-update='ignore'] " <>
               "#wiki-tree-collapse[phx-hook='WikiTreeCollapse'][aria-controls='wiki-tree'][aria-expanded='true']"
           )

    # No phx-click: folding is the browser's business, never a round trip.
    refute has_element?(view, "#wiki-tree-collapse[phx-click]")
  end

  test "the resize handle sits between the tree and the page, as a separator", %{
    conn: conn,
    board: board,
    page: page
  } do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    assert has_element?(
             view,
             "#wiki-tree-resize-keep.hidden.lg\\:contents[phx-update='ignore'] " <>
               "#wiki-tree-resize[phx-hook='WikiTreeResize'][data-pane='wiki-tree']" <>
               "[role='separator'][aria-orientation='vertical'][tabindex='0']"
           )

    {tree, _} = :binary.match(html, ~s(id="wiki-tree"))
    {handle, _} = :binary.match(html, ~s(id="wiki-tree-resize"))
    {main, _} = :binary.match(html, ~s(id="wiki-main"))
    assert tree < handle and handle < main
  end

  test "both survive the tree's own updates and the phone drawer opening", %{
    conn: conn,
    board: board,
    page: page
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    view |> element("#wiki-tree-drawer-toggle") |> render_click()
    render_patch(view, ~p"/boards/#{board}/wiki/#{page.slug}")

    assert has_element?(view, "#wiki-tree-collapse")
    assert has_element?(view, "#wiki-tree-resize")
    # The tree pane itself carries no inline width: that comes from
    # --wiki-tree-width on <html>, which the patches cannot undo.
    refute has_element?(view, "#wiki-tree[style]")
  end

  # #748: the page read in a column or across the whole width.
  describe "the page width toggle" do
    test "is on wide screens only, worked by its hook, with the column it widens", %{
      conn: conn,
      board: board,
      page: page
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert has_element?(
               view,
               "#wiki-width-toggle-keep.hidden.lg\\:inline-flex[phx-update='ignore'] " <>
                 "#wiki-width-toggle[phx-hook='WikiWidthToggle']" <>
                 "[aria-controls='wiki-column'][aria-pressed='false']"
             )

      # The width is the browser's business, never a round trip.
      refute has_element?(view, "#wiki-width-toggle[phx-click]")
      # The column keeps its reading measure in the markup; the full width
      # comes from data-wiki-width on <html>, which the patches cannot undo.
      assert has_element?(view, "#wiki-main #wiki-column.max-w-4xl")
    end

    test "is there on the wiki's index and survives moving between pages", %{
      conn: conn,
      board: board,
      page: page
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
      assert has_element?(view, "#wiki-width-toggle")

      render_patch(view, ~p"/boards/#{board}/wiki/#{page.slug}")
      assert has_element?(view, "#wiki-width-toggle")
      assert has_element?(view, "#wiki-column.max-w-4xl")
    end

    test "is not offered while writing, which takes the whole width anyway", %{
      conn: conn,
      board: board,
      page: page
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

      refute has_element?(view, "#wiki-width-toggle")
      assert has_element?(view, "#wiki-column.max-w-none")
    end
  end
end
