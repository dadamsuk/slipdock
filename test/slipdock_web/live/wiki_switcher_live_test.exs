defmodule SlipdockWeb.WikiSwitcherLiveTest do
  @moduledoc """
  Ctrl/Cmd-O on a wiki is the quick switcher (W-103 R11.4); anywhere else it
  is still the card finder.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KB", "code" => "kbswl"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobswl"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: jobs})
    {:ok, acme} = Wiki.create_folder(jobs, %{"name" => "Acme"})
    {:ok, call} = Wiki.create_page(jobs, %{"title" => "Call"}, user: user)
    {:ok, call} = Wiki.file_page(call, acme)
    page_fixture(kb, %{"title" => "Home"})
    %{kb: kb, jobs: jobs, call: call}
  end

  test "on a wiki, Ctrl-O opens a note from anywhere in the vault", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    call: call
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    html = render_hook(view, "shortcut_panel", %{"panel" => "find"})
    assert html =~ "Open a note"
    assert has_element?(view, ~s{#palette-q-notes[placeholder*="alias or path"]})
    # Nothing typed: the latest changed.
    assert has_element?(view, "#palette-rows a", "Home")

    render_hook(view, "palette_filter", %{"q" => "acmcal"})
    assert has_element?(view, ~s{#palette-rows a[href="/boards/#{jobs.id}/wiki/#{call.slug}"]})
    assert render(view) =~ "Journal/Acme/Call"
    refute has_element?(view, "#palette-rows a", "Home")

    assert render_hook(view, "palette_filter", %{"q" => "qqqq"}) =~
             "No note&#39;s title, alias or path matches."

    # The same key again shuts it.
    render_hook(view, "shortcut_panel", %{"panel" => "find"})
    refute has_element?(view, "#key-palette")
  end

  test "the arrows walk the matches", %{conn: conn, kb: kb} do
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    render_hook(view, "shortcut_panel", %{"panel" => "find"})

    assert has_element?(view, "#palette-rows li:first-child a[data-on]")
    render_hook(view, "palette_move", %{"dir" => "down"})
    assert has_element?(view, "#palette-rows li:nth-child(2) a[data-on]")
  end

  test "elsewhere, Ctrl-O is still the card finder", %{conn: conn, kb: kb} do
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}")
    assert render_hook(view, "shortcut_panel", %{"panel" => "find"}) =~ "Find a card"
  end
end
