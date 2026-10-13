defmodule SlipdockWeb.VaultViewLiveTest do
  @moduledoc "The vault view: its own page, tree and pages at their vault paths (#752)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.{Vaults, Wiki}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kbv"}, owner: user)
    hunt = board_fixture(%{"name" => "Job Hunt", "code" => "huntv"}, owner: user)
    {:ok, notes} = Wiki.create_folder(kb, %{"name" => "Big Ideas"})

    {:ok, idea} =
      Wiki.create_page(kb, %{
        "title" => "Plain text",
        "body" => "Write it down.",
        "folder_id" => notes.id
      })

    {:ok, questions} =
      Wiki.create_page(hunt, %{"title" => "Interview Questions", "body" => "Why us?"})

    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: hunt})
    %{kb: kb, hunt: hunt, notes: notes, idea: idea, questions: questions, vault: vault}
  end

  test "a page opens at its vault path, spaces and all, with the vault's breadcrumbs", ctx do
    %{conn: conn, hunt: hunt} = ctx
    {:ok, view, html} = live(conn, "/vaults/GMinds/Jobs/Interview%20Questions")

    assert html =~ "Why us?"
    assert has_element?(view, "#vault-crumbs a", "GMinds")
    assert has_element?(view, "#vault-crumbs a[href='/vaults/GMinds/Jobs']", "Jobs")
    assert has_element?(view, "#vault-board", "on Job Hunt")
    assert has_element?(view, "#vault-board[href='/boards/#{hunt.id}/wiki/interview-questions']")
    assert has_element?(view, "#vault-settings[href='/vaults/GMinds/.settings']")
  end

  test "a page in a folder of the board mounted at the top, case aside, .md or not", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/vaults/gminds/big%20ideas/PLAIN%20TEXT.md")
    assert html =~ "Write it down."
  end

  test "the vault's top shows the board mounted at /, and a folder its listing", ctx do
    %{conn: conn} = ctx
    {:ok, _view, html} = live(conn, "/vaults/GMinds")
    assert html =~ "Big Ideas"

    {:ok, view, _html} = live(conn, "/vaults/GMinds/Big%20Ideas")
    assert has_element?(view, "#vault-crumbs a", "Big Ideas")
    assert render(view) =~ "Plain text"
  end

  test "the tree is the vault's, and its rows open at their vault addresses", ctx do
    %{conn: conn, hunt: hunt} = ctx
    {:ok, view, _} = live(conn, "/vaults/GMinds/Jobs/Interview%20Questions")

    # Whatever the hook remembers, the vault view's tree is the vault's.
    reply = tree_load(view, %{"scope" => "board", "keys" => ["board:#{hunt.id}"]})
    assert reply.scope == "vault"
    row = row(reply, "vault", "Big Ideas")
    assert row.href == "/vaults/GMinds/Big%20Ideas"
    assert row.nav == "redirect"

    assert row(reply, "board:#{hunt.id}", "Interview Questions").href ==
             "/vaults/GMinds/Jobs/Interview%20Questions"
  end

  test "a page on a board the owner can now only read opens, read-only", ctx do
    %{conn: conn, user: user} = ctx
    lender = user_fixture("lender-view@example.com")
    lent = board_fixture(%{"name" => "Lent", "code" => "lentv"}, owner: lender)
    share_fixture(lent, user, "write")
    {:ok, _} = Wiki.create_page(lent, %{"title" => "Borrowed", "body" => "Read me."})
    {:ok, _} = Vaults.add_mapping(ctx.vault, user, %{path: "/Lent", board: lent})
    share_fixture(lent, user, "read")

    {:ok, view, html} = live(conn, "/vaults/GMinds/Lent/Borrowed")
    assert html =~ "Read me."
    refute has_element?(view, "a[href$='/borrowed/edit']")
  end

  test "an address with nothing there, or someone else's vault, goes home", ctx do
    %{conn: conn} = ctx
    assert {:error, {:live_redirect, %{to: "/", flash: _}}} = live(conn, "/vaults/GMinds/Nope")

    stranger = user_fixture("stranger-view@example.com")
    {:ok, _} = Vaults.create_vault(stranger, %{"name" => "Theirs"})
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/vaults/Theirs")
  end

  test "an empty vault sends you to its settings to mount a board", %{conn: conn, user: user} do
    {:ok, _} = Vaults.create_vault(user, %{"name" => "Empty"})

    assert {:error, {:live_redirect, %{to: "/vaults/Empty/.settings"}}} =
             live(conn, "/vaults/Empty")
  end

  test "a board's wiki opens the same page in the vault view", ctx do
    %{conn: conn, hunt: hunt, questions: questions} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{hunt}/wiki/#{questions.slug}")

    assert has_element?(
             view,
             "#open-in-vault[href='/vaults/GMinds?page=#{questions.id}']",
             "Open in GMinds"
           )

    # By id, it settles on the page's own address.
    assert {:error, {:live_redirect, %{to: "/vaults/GMinds/Jobs/Interview%20Questions"}}} =
             live(conn, "/vaults/GMinds?page=#{questions.id}")
  end

  test "settings: one vault, its mount form, and Open from the list", ctx do
    %{conn: conn, user: user} = ctx
    {:ok, _} = Vaults.create_vault(user, %{"name" => "Other"})
    {:ok, view, html} = live(conn, "/vaults/GMinds/.settings")

    assert html =~ "Vault settings"
    assert html =~ "Mount a board&#39;s wiki at a path"
    refute html =~ "Other"
    assert has_element?(view, "#open-vault-#{ctx.vault.id}[href='/vaults/GMinds']")

    {:ok, home, _} = live(conn, ~p"/")
    assert has_element?(home, "#vault-tile-#{ctx.vault.id}[href='/vaults/GMinds']")
  end

  test "a new note made in a folder of the vault lands on the board mapped there", ctx do
    %{conn: conn, kb: kb, notes: notes} = ctx
    {:ok, view, _} = live(conn, "/vaults/GMinds/Big%20Ideas")
    reply = tree_load(view, %{"scope" => "vault", "keys" => ["folder:#{notes.id}"]})
    assert row(reply, "vault", "Big Ideas").board_id == kb.id
  end
end
