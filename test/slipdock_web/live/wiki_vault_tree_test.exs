defmodule SlipdockWeb.WikiVaultTreeTest do
  @moduledoc """
  The wiki's tree on a board in a vault: the switch between this board's
  tree and the vault's (W-103 R11.3), and what the vault's tree sends.
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
    {:ok, acme} = Wiki.create_folder(jobs, %{"name" => "Acme"})
    {:ok, call} = Wiki.create_page(jobs, %{"title" => "Call notes"}, user: user)
    {:ok, call} = Wiki.file_page(call, acme)
    home = page_fixture(kb, %{"title" => "Home"})
    %{kb: kb, jobs: jobs, vault: vault, acme: acme, call: call, home: home}
  end

  test "a board in a vault offers both trees; one in none offers no switch", %{
    conn: conn,
    kb: kb,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")
    assert has_element?(view, "button[data-tree-scope='board'][aria-pressed='true']")
    # The owner opens the vault in its own view (#752).
    assert has_element?(view, "#open-in-vault", "Open in Brain")
    refute has_element?(view, "button[data-tree-scope='vault']")
    # Two lines at most (#739): the head, with the Tree / Recent switch in
    # it, and this switch, which needs the room for the vault's name.
    assert has_element?(view, "#wiki-tree-head #wiki-tree-view")

    assert has_element?(view, "#wiki-tree > [role='group'] #open-in-vault")
    refute has_element?(view, "#wiki-tree > [role='group'] #wiki-tree-view-tree")

    lone = board_fixture(%{"name" => "Lone", "code" => "lonevt"}, owner: user)
    {:ok, view, _html} = live(conn, ~p"/boards/#{lone}/wiki")
    refute has_element?(view, "[data-tree-scope]")
    # And asking for the vault's tree there gets the board's.
    assert tree_load(view, %{"scope" => "vault"}).scope == "board"
  end

  test "someone else reading a board of the vault keeps the switch between the trees", ctx do
    %{kb: kb, user: owner} = ctx
    reader = user_fixture("switch.reader@example.com")
    {:ok, _} = Slipdock.Access.grant(kb, reader, "read", owner)
    {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{kb}/wiki")

    assert has_element?(view, "button[data-tree-scope='vault']", "Brain")
    refute has_element?(view, "#open-in-vault")
    assert tree_load(view, %{"scope" => "vault"}).scope == "vault"
    assert has_element?(view, "button[data-tree-scope='vault'][aria-pressed='true']")
  end

  test "the vault's tree spans its boards, and links across them navigate", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    acme: acme,
    call: call
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    reply =
      tree_load(view, %{"scope" => "vault", "keys" => ["board:#{jobs.id}", "folder:#{acme.id}"]})

    assert reply.scope == "vault"
    assert reply.root == "vault"
    assert titles(reply, "vault") == ["Jobs", "Home"]
    assert %{nav: "redirect", mount: true, href: href} = row(reply, "vault", "Jobs")
    assert href == "/boards/#{jobs.id}/wiki"
    assert %{nav: "patch"} = row(reply, "vault", "Home")
    assert %{nav: "redirect", href: call_href} = row(reply, "folder:#{acme.id}", "Call notes")
    assert call_href == "/boards/#{jobs.id}/wiki/#{call.slug}"
  end

  test "in the vault's tree, the way to a page runs through the vault's folders", %{
    conn: conn,
    jobs: jobs,
    acme: acme,
    call: call
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{jobs}/wiki/#{call.slug}")

    assert tree_load(view).reveal == ["folder:#{acme.id}"]
    reply = tree_load(view, %{"scope" => "vault"})
    assert reply.reveal == ["board:#{jobs.id}", "folder:#{acme.id}"]
    assert titles(reply, "folder:#{acme.id}") == ["Call notes"]
  end

  test "organising works in the vault's tree, on what the reader can write", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    user: owner
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")
    tree_load(view, %{"scope" => "vault"})

    view |> element("button[phx-click='toggle_organise']") |> render_click()

    reply = tree_load(view, %{"scope" => "vault", "keys" => ["board:#{jobs.id}"]})
    assert reply.scope == "vault"
    assert %{writable: true} = row(reply, "vault", "Home")
    assert %{writable: true} = row(reply, "board:#{jobs.id}", "Acme")

    # A board of the vault this reader can only read has nothing to move.
    reader = user_fixture("organise.reader@example.com")
    {:ok, _} = Slipdock.Access.grant(kb, reader, "write", owner)
    {:ok, _} = Slipdock.Access.grant(jobs, reader, "read", owner)
    {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{kb}/wiki")
    reply = tree_load(view, %{"scope" => "vault", "keys" => ["board:#{jobs.id}"]})
    assert %{writable: true} = row(reply, "vault", "Home")
    refute Map.has_key?(row(reply, "board:#{jobs.id}", "Acme"), :writable)
  end

  test "a filter in the vault's tree filters every board of it", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    acme: acme
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")
    tree_load(view, %{"scope" => "vault"})

    view |> form("#wiki-search") |> render_change(%{"q" => "call"})

    reply = tree_load(view, %{"scope" => "vault"})
    assert reply.filtering
    assert titles(reply, "vault") == ["Jobs"]
    assert titles(reply, "board:#{jobs.id}") == ["Acme"]
    assert titles(reply, "folder:#{acme.id}") == ["Call notes"]

    # This board's own tree has nothing to show for it.
    reply = tree_load(view, %{"scope" => "board"})
    assert reply.filtering
    assert reply.nodes == %{}
  end

  test "the search can look inside pages too", %{conn: conn, kb: kb, user: user} do
    {:ok, _} = Wiki.create_page(kb, %{"title" => "Plain", "body" => "about tea"}, user: user)
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    view |> form("#wiki-search") |> render_change(%{"q" => "tea"})
    assert tree_load(view).nodes == %{}

    view |> element("input[phx-click='toggle_tree_contents']") |> render_click()
    assert all_titles(tree_load(view)) == ["Plain"]
  end

  test "a vault board the reader cannot open is not in their vault tree", %{
    kb: kb,
    jobs: jobs,
    user: owner
  } do
    reader = user_fixture("vault.reader@example.com")
    {:ok, _} = Slipdock.Access.grant(kb, reader, "read", owner)

    {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{kb}/wiki")
    reply = tree_load(view, %{"scope" => "vault", "keys" => ["board:#{jobs.id}"]})

    assert titles(reply, "vault") == ["Home"]
    refute Map.has_key?(reply.nodes, "board:#{jobs.id}")
  end
end
