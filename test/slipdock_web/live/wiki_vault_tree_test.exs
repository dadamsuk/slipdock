defmodule SlipdockWeb.WikiVaultTreeTest do
  @moduledoc """
  The wiki's tree on a board in a vault (W-103 R11.3, #758): the board's
  wiki is the vault from where the board is mounted down, so what is
  mounted below it shows among its folders, and a page on another board
  opened from it keeps this board's tree. No switch between trees.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.{Vaults, Wiki}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kbvt"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobsvt"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})
    {:ok, _} = Wiki.create_folder(kb, %{"name" => "Archive"})
    {:ok, _} = Wiki.create_folder(kb, %{"name" => "Projects"})
    {:ok, acme} = Wiki.create_folder(jobs, %{"name" => "Acme"})
    {:ok, call} = Wiki.create_page(jobs, %{"title" => "Call notes"}, user: user)
    {:ok, call} = Wiki.file_page(call, acme)
    home = page_fixture(kb, %{"title" => "Home"})
    %{kb: kb, jobs: jobs, vault: vault, acme: acme, call: call, home: home}
  end

  test "the board at the vault's root shows what is mounted below it, among its folders", %{
    conn: conn,
    kb: kb,
    jobs: jobs
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    # No switch between trees, and no way out to the vault's: this is it.
    refute has_element?(view, "[data-tree-scope]")
    refute has_element?(view, "#open-in-vault")

    reply = tree_load(view)
    assert reply.scope == "board"
    assert reply.root == "root"
    assert titles(reply, "root") == ["Archive", "Jobs", "Projects", "Home"]

    # Jobs is Job Hunt's wiki, opened in this board's tree.
    assert %{nav: "redirect", mount: true, href: href} = row(reply, "root", "Jobs")
    assert href == "/boards/#{jobs.id}/wiki?in=#{kb.id}"
    assert %{nav: "patch", href: home_href} = row(reply, "root", "Home")
    refute home_href =~ "in="
  end

  test "a board mounted below the root shows only its part of the vault", %{
    conn: conn,
    jobs: jobs,
    acme: acme
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{jobs}/wiki")

    reply = tree_load(view, %{"keys" => ["folder:#{acme.id}"]})
    assert reply.root == "root"
    assert titles(reply, "root") == ["Acme"]
    assert titles(reply, "folder:#{acme.id}") == ["Call notes"]
    refute "Home" in all_titles(reply)
    refute "Archive" in all_titles(reply)
  end

  test "a board in no vault is its own wiki, as ever", %{conn: conn, user: user} do
    lone = board_fixture(%{"name" => "Lone", "code" => "lonevt"}, owner: user)
    page_fixture(lone, %{"title" => "Alone"})
    {:ok, view, _html} = live(conn, ~p"/boards/#{lone}/wiki")

    refute has_element?(view, "[data-tree-scope]")
    # Asking for the vault's tree there gets the board's.
    reply = tree_load(view, %{"scope" => "vault"})
    assert reply.scope == "board"
    assert titles(reply, "root") == ["Alone"]
  end

  test "a page on a mounted board opens in the tree it was opened from", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    acme: acme,
    call: call
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{jobs}/wiki/#{call.slug}?in=#{kb.id}")

    # KnowledgeBase's breadcrumbs, and quietly, the board it is on.
    assert has_element?(view, "#context-crumbs", "KnowledgeBase")
    assert has_element?(view, "#context-board[href='/boards/#{jobs.id}/wiki/#{call.slug}']")
    assert has_element?(view, "#context-board", "on Job Hunt")

    reply = tree_load(view)
    assert reply.root == "board:#{kb.id}"
    assert titles(reply, "board:#{kb.id}") == ["Archive", "Jobs", "Projects", "Home"]
    assert reply.reveal == ["board:#{jobs.id}", "folder:#{acme.id}"]

    # Job Hunt's rows stay in this tree; KnowledgeBase's go back to its own.
    assert %{nav: "patch", href: href} = row(reply, "folder:#{acme.id}", "Call notes")
    assert href == "/boards/#{jobs.id}/wiki/#{call.slug}?in=#{kb.id}"
    assert %{nav: "redirect", href: home} = row(reply, "board:#{kb.id}", "Home")
    assert home =~ ~r{^/boards/#{kb.id}/wiki/[^?]+$}
  end

  test "an ?in= that names no tree this page is in is ignored", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    home: home,
    user: user
  } do
    # Knowledgebase is not below Job Hunt's mount.
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki/#{home.slug}?in=#{jobs.id}")
    refute has_element?(view, "#context-crumbs")
    assert tree_load(view).root == "root"

    # A board in no vault, and nonsense.
    other = board_fixture(%{"name" => "Other", "code" => "othervt"}, owner: user)
    {:ok, view, _html} = live(conn, ~p"/boards/#{jobs}/wiki?in=#{other.id}")
    refute has_element?(view, "#context-crumbs")
    {:ok, view, _html} = live(conn, ~p"/boards/#{jobs}/wiki?in=junk")
    assert tree_load(view).root == "root"
  end

  test "a board the reader can't open gives no context, and no mount", %{
    kb: kb,
    jobs: jobs,
    call: call,
    user: owner
  } do
    reader = user_fixture("vault.reader@example.com")
    {:ok, _} = Slipdock.Access.grant(kb, reader, "read", owner)

    {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{kb}/wiki")
    reply = tree_load(view, %{"keys" => ["board:#{jobs.id}"]})
    assert titles(reply, "root") == ["Archive", "Projects", "Home"]
    refute Map.has_key?(reply.nodes, "board:#{jobs.id}")

    # And Job Hunt's reader can't see KnowledgeBase through it.
    other = user_fixture("jobs.reader@example.com")
    {:ok, _} = Slipdock.Access.grant(jobs, other, "read", owner)
    {:ok, view, _html} = live(conn_as(other), ~p"/boards/#{jobs}/wiki/#{call.slug}?in=#{kb.id}")
    refute has_element?(view, "#context-crumbs")
  end

  test "organising works across the mounts, on what the reader can write", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    user: owner
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")
    view |> element("button[phx-click='toggle_organise']") |> render_click()

    reply = tree_load(view, %{"keys" => ["board:#{jobs.id}"]})
    assert %{writable: true} = row(reply, "root", "Home")
    assert %{writable: true} = row(reply, "board:#{jobs.id}", "Acme")

    # A board of the vault this reader can only read has nothing to move.
    reader = user_fixture("organise.reader@example.com")
    {:ok, _} = Slipdock.Access.grant(kb, reader, "write", owner)
    {:ok, _} = Slipdock.Access.grant(jobs, reader, "read", owner)
    {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{kb}/wiki")
    reply = tree_load(view, %{"keys" => ["board:#{jobs.id}"]})
    assert %{writable: true} = row(reply, "root", "Home")
    refute Map.has_key?(row(reply, "board:#{jobs.id}", "Acme"), :writable)
  end

  test "a filter covers what the board's tree shows, and no more", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    acme: acme
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")
    view |> form("#wiki-search") |> render_change(%{"q" => "call"})

    reply = tree_load(view)
    assert reply.filtering
    assert titles(reply, "root") == ["Jobs"]
    assert titles(reply, "board:#{jobs.id}") == ["Acme"]
    assert titles(reply, "folder:#{acme.id}") == ["Call notes"]

    # From Job Hunt, KnowledgeBase's pages are above it, so out of reach.
    {:ok, view, _html} = live(conn, ~p"/boards/#{jobs}/wiki")
    view |> form("#wiki-search") |> render_change(%{"q" => "home"})
    assert tree_load(view).nodes == %{}

    view |> form("#wiki-search") |> render_change(%{"q" => "call"})
    reply = tree_load(view)
    assert titles(reply, "root") == ["Acme"]
  end

  test "the search can look inside pages too", %{conn: conn, kb: kb, user: user} do
    {:ok, _} = Wiki.create_page(kb, %{"title" => "Plain", "body" => "about tea"}, user: user)
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    view |> form("#wiki-search") |> render_change(%{"q" => "tea"})
    assert tree_load(view).nodes == %{}

    view |> element("input[phx-click='toggle_tree_contents']") |> render_click()
    assert all_titles(tree_load(view)) == ["Plain"]
  end
end
