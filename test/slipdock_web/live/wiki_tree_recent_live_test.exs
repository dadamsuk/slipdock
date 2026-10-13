defmodule SlipdockWeb.WikiTreeRecentLiveTest do
  @moduledoc """
  The wiki tree's Recent view (#738): a switch over the tree turns it into a
  flat list of the board's pages, the most recently edited first, up to 100.
  The server draws and switches it; the WikiTreeView hook (wiki_pane.js,
  tested in wiki_pane.test.js) only remembers the choice.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Repo
  alias Slipdock.Wiki.Page

  setup %{user: user} do
    board = board_fixture(%{"name" => "Recent", "code" => "recenttree"}, owner: user)
    old = page_fixture(board, %{"title" => "Old notes"}) |> edited(~U[2026-01-01 09:00:00Z])
    mid = page_fixture(board, %{"title" => "Middle notes"}) |> edited(~U[2026-03-01 09:00:00Z])
    new = page_fixture(board, %{"title" => "New plan"}) |> edited(~U[2026-06-01 09:00:00Z])
    %{board: board, old: old, mid: mid, new: new}
  end

  defp edited(page, at) do
    Repo.update_all(from(p in Page, where: p.id == ^page.id), set: [updated_at: at])
    %{page | updated_at: at}
  end

  defp recent_ids(view) do
    Regex.scan(~r/id="wiki-recent-(\d+)"/, render(view))
    |> Enum.map(fn [_, id] -> String.to_integer(id) end)
  end

  # The top of the tree is one line (#739): the switch sits beside All pages
  # and the tree's own buttons rather than on a row of its own, as icons with
  # their names for screen readers and in the tooltip.
  test "the Tree / Recent switch shares the tree's first line", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    assert has_element?(view, "#wiki-tree-head a", "All pages")
    assert has_element?(view, "#wiki-tree-head #wiki-tree-view")
    assert has_element?(view, "#wiki-tree-head button[phx-click='toggle_organise']")

    assert has_element?(
             view,
             "#wiki-tree-view-tree[aria-label='Tree'][title='Pages in their folders'] .hero-folder"
           )

    assert has_element?(
             view,
             "#wiki-tree-view-recent[aria-label='Recent'][title='The most recently edited pages first'] .hero-clock"
           )

    # Nothing else is stacked above the tree, in either view.
    refute has_element?(view, "#wiki-tree > [role='group']")
    view |> element("#wiki-tree-view-recent") |> render_click()
    assert has_element?(view, "#wiki-tree-head #wiki-tree-view-recent[aria-pressed='true']")
    refute has_element?(view, "#wiki-tree > [role='group']")
  end

  test "the tree is the default, and Recent lists pages newest edit first", %{
    conn: conn,
    board: board,
    old: old,
    mid: mid,
    new: new
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    assert has_element?(view, "#wiki-tree-view[phx-hook='WikiTreeView']")
    assert has_element?(view, "#wiki-tree-view-tree[aria-pressed='true']")
    refute has_element?(view, "#wiki-tree-recent")

    view |> element("#wiki-tree-view-recent") |> render_click()

    assert_push_event(view, "wiki-tree:view", %{view: "recent"})
    assert has_element?(view, "#wiki-tree-view-recent[aria-pressed='true']")
    assert recent_ids(view) == [new.id, mid.id, old.id]

    assert has_element?(
             view,
             "#wiki-recent-#{new.id} a[href='/boards/#{board.id}/wiki/#{new.slug}']",
             "New plan"
           )

    # The hook's rows stay mounted, hidden, and the tree-only buttons go.
    assert has_element?(view, "div.hidden #wiki-tree-rows")
    refute has_element?(view, "button[phx-click='toggle_organise']")

    view |> element("#wiki-tree-view-tree") |> render_click()
    assert_push_event(view, "wiki-tree:view", %{view: "tree"})
    refute has_element?(view, "#wiki-tree-recent")
    refute has_element?(view, "div.hidden #wiki-tree-rows")
    assert has_element?(view, "button[phx-click='toggle_organise']")
  end

  test "an edit elsewhere puts that page at the top when the wiki reloads", %{
    conn: conn,
    board: board,
    old: old,
    mid: mid,
    new: new
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
    render_hook(view, "tree_view", %{"view" => "recent"})

    edited(old, ~U[2026-09-01 09:00:00Z])
    send(view.pid, :reload_wiki)

    assert recent_ids(view) == [old.id, new.id, mid.id]
  end

  test "the page being read is marked in the list", %{conn: conn, board: board, mid: mid} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{mid.slug}")
    render_hook(view, "tree_view", %{"view" => "recent"})

    assert has_element?(view, "#wiki-recent-#{mid.id} a.bg-base-200")
  end

  test "the filter bar narrows it as it narrows the tree", %{
    conn: conn,
    board: board,
    old: old,
    mid: mid
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
    render_hook(view, "tree_view", %{"view" => "recent"})
    render_hook(view, "search", %{"q" => "notes"})

    assert recent_ids(view) == [mid.id, old.id]

    render_hook(view, "search", %{"q" => "zzz-nothing"})
    assert recent_ids(view) == []
    assert has_element?(view, "#wiki-tree-recent li", "No page matches that.")
  end

  test "archived pages stay out, as they do in the tree", %{
    conn: conn,
    board: board,
    new: new
  } do
    {:ok, _} = Slipdock.Wiki.archive_page(new)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
    render_hook(view, "tree_view", %{"view" => "recent"})

    refute new.id in recent_ids(view)
    assert length(recent_ids(view)) == 2
  end

  test "it stops at 100 pages, the newest ones", %{conn: conn, board: board, old: old} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for n <- 1..100 do
      page_fixture(board, %{"title" => "Bulk #{n}"}) |> edited(DateTime.add(now, n, :second))
    end

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
    render_hook(view, "tree_view", %{"view" => "recent"})

    ids = recent_ids(view)
    assert length(ids) == 100
    refute old.id in ids
    # Edited today, so the time rather than the day.
    assert render(view) =~ Calendar.strftime(DateTime.add(now, 100, :second), "%H:%M")
  end

  test "switching to Recent ends organising, and a view it doesn't know changes nothing", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    render_hook(view, "toggle_organise", %{})
    assert render(view) =~ "Drag to rearrange"

    render_hook(view, "tree_view", %{"view" => "recent"})
    refute render(view) =~ "Drag to rearrange"

    render_hook(view, "tree_view", %{"view" => "sideways"})
    render_hook(view, "tree_view", %{})
    assert has_element?(view, "#wiki-tree-view-recent[aria-pressed='true']")
  end
end
