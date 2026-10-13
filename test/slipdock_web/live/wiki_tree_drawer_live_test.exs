defmodule SlipdockWeb.WikiTreeDrawerLiveTest do
  @moduledoc """
  The wiki's tree on a phone (W-103 R11.11): shut until "Pages" opens it as
  a drawer, and shut again by a tap outside, Esc, or opening a page.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup %{user: user} do
    board = board_fixture(%{"name" => "Phone", "code" => "phonetree"}, owner: user)
    page = page_fixture(board, %{"title" => "Notes"})
    %{board: board, page: page}
  end

  test "Pages opens the tree as a drawer over the page, and a tap outside shuts it", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    assert has_element?(view, "#wiki-tree-drawer-toggle.lg\\:hidden[aria-expanded='false']")
    assert has_element?(view, "#wiki-tree.hidden.lg\\:block")
    refute has_element?(view, "#wiki-tree-backdrop")

    view |> element("#wiki-tree-drawer-toggle") |> render_click()
    assert has_element?(view, "#wiki-tree.fixed.block")
    refute has_element?(view, "#wiki-tree.hidden")
    assert has_element?(view, "#wiki-tree-drawer-toggle[aria-expanded='true']")

    view |> element("#wiki-tree-backdrop") |> render_click()
    assert has_element?(view, "#wiki-tree.hidden")
  end

  test "Esc shuts it, and so does opening a page from it", %{conn: conn, board: board, page: page} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    view |> element("#wiki-tree-drawer-toggle") |> render_click()
    render_keydown(view, "close_tree_drawer", %{"key" => "Escape"})
    refute has_element?(view, "#wiki-tree-backdrop")

    view |> element("#wiki-tree-drawer-toggle") |> render_click()
    render_patch(view, ~p"/boards/#{board}/wiki/#{page.slug}")
    refute has_element?(view, "#wiki-tree-backdrop")
    assert has_element?(view, "#wiki-tree.hidden")
  end
end
