defmodule SlipdockWeb.VaultViewLiveTest do
  @moduledoc "The vault view: its own page, tree and pages at their vault paths (#752)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.{Vaults, Wiki}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbv"}, owner: user)
    hunt = board_fixture(%{"name" => "Journal Desk", "code" => "huntv"}, owner: user)
    {:ok, notes} = Wiki.create_folder(kb, %{"name" => "Big Ideas"})

    {:ok, idea} =
      Wiki.create_page(kb, %{
        "title" => "Plain text",
        "body" => "Write it down.",
        "folder_id" => notes.id
      })

    {:ok, questions} =
      Wiki.create_page(hunt, %{"title" => "Intake Questions", "body" => "Why us?"})

    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: hunt})
    %{kb: kb, hunt: hunt, notes: notes, idea: idea, questions: questions, vault: vault}
  end

  test "a page opens at its vault path, spaces and all, with the vault's breadcrumbs", ctx do
    %{conn: conn, hunt: hunt} = ctx
    {:ok, view, html} = live(conn, "/vaults/Notes/Journal/Intake%20Questions")

    assert html =~ "Why us?"
    assert has_element?(view, "#vault-crumbs a", "Notes")
    assert has_element?(view, "#vault-crumbs a[href='/vaults/Notes/Journal']", "Journal")
    assert has_element?(view, "#vault-board", "on Journal Desk")
    assert has_element?(view, "#vault-board[href='/boards/#{hunt.id}/wiki/intake-questions']")
    assert has_element?(view, "#vault-settings[href='/vaults/Notes/.settings']")
  end

  test "a page in a folder of the board mounted at the top, case aside, .md or not", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/vaults/notes/big%20ideas/PLAIN%20TEXT.md")
    assert html =~ "Write it down."
  end

  test "the vault's top shows the board mounted at /, and a folder its listing", ctx do
    %{conn: conn} = ctx
    {:ok, _view, html} = live(conn, "/vaults/Notes")
    assert html =~ "Big Ideas"

    {:ok, view, _html} = live(conn, "/vaults/Notes/Big%20Ideas")
    assert has_element?(view, "#vault-crumbs a", "Big Ideas")
    assert render(view) =~ "Plain text"
  end

  test "the tree is the vault's, and its rows open at their vault addresses", ctx do
    %{conn: conn, hunt: hunt} = ctx
    {:ok, view, _} = live(conn, "/vaults/Notes/Journal/Intake%20Questions")

    # Whatever the hook remembers, the vault view's tree is the vault's.
    reply = tree_load(view, %{"scope" => "board", "keys" => ["board:#{hunt.id}"]})
    assert reply.scope == "vault"
    row = row(reply, "vault", "Big Ideas")
    assert row.href == "/vaults/Notes/Big%20Ideas"
    assert row.nav == "patch"

    assert row(reply, "board:#{hunt.id}", "Intake Questions").href ==
             "/vaults/Notes/Journal/Intake%20Questions"
  end

  # The tree's rows open by patching (none of them by a fresh view, which
  # would tear the tree down and draw it again from nothing on every click).
  test "a row opens by patching, onto another board too, in the same view", ctx do
    %{conn: conn, kb: kb, hunt: hunt, questions: questions} = ctx
    {:ok, view, _} = live(conn, "/vaults/Notes/Big%20Ideas/Plain%20text")
    render_hook(view, "tree_view", %{"view" => "recent"})
    before = version(view)
    assert topics(view) == ["wiki:#{kb.id}"]

    # A page on another board: its board's wiki, under the vault's tree.
    html = render_patch(view, "/vaults/Notes/Journal/Intake%20Questions")
    assert html =~ "Why us?"
    assert has_element?(view, "#vault-board", "on Journal Desk")
    assert has_element?(view, "#vault-crumbs a[href='/vaults/Notes/Journal']", "Journal")
    assert has_element?(view, "#wiki-tree[data-current='page:#{questions.id}']")
    assert tree_load(view).scope == "vault"
    # The hook is told to ask for the rows again; the reader's choice of
    # list is kept; and it now hears about this board's changes, not the last.
    assert version(view) > before
    assert has_element?(view, "#wiki-tree-view-recent[aria-pressed='true']")
    assert topics(view) == ["wiki:#{hunt.id}"]

    # Another page of the same board changes only what is shown.
    after_switch = version(view)
    assert render_patch(view, "/vaults/Notes/Journal") =~ "Intake Questions"
    assert version(view) == after_switch
  end

  test "patched to an address with nothing there, the view starts afresh", %{conn: conn} do
    {:ok, view, _} = live(conn, "/vaults/Notes/Big%20Ideas")

    assert {:error, {:live_redirect, %{to: "/vaults/Notes/Nope"}}} =
             render_patch(view, "/vaults/Notes/Nope")
  end

  test "a page on a board the owner can now only read opens, read-only", ctx do
    %{conn: conn, user: user} = ctx
    lender = user_fixture("lender-view@example.com")
    lent = board_fixture(%{"name" => "Lent", "code" => "lentv"}, owner: lender)
    share_fixture(lent, user, "write")
    {:ok, _} = Wiki.create_page(lent, %{"title" => "Borrowed", "body" => "Read me."})
    {:ok, _} = Vaults.add_mapping(ctx.vault, user, %{path: "/Lent", board: lent})
    share_fixture(lent, user, "read")

    {:ok, view, html} = live(conn, "/vaults/Notes/Lent/Borrowed")
    assert html =~ "Read me."
    refute has_element?(view, "a[href$='/borrowed/edit']")
  end

  test "an address with nothing there, or someone else's vault, goes home", ctx do
    %{conn: conn} = ctx
    assert {:error, {:live_redirect, %{to: "/", flash: _}}} = live(conn, "/vaults/Notes/Nope")

    stranger = user_fixture("stranger-view@example.com")
    {:ok, _} = Vaults.create_vault(stranger, %{"name" => "Theirs"})
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/vaults/Theirs")
  end

  test "an empty vault sends you to its settings to mount a board", %{conn: conn, user: user} do
    {:ok, _} = Vaults.create_vault(user, %{"name" => "Empty"})

    assert {:error, {:live_redirect, %{to: "/vaults/Empty/.settings"}}} =
             live(conn, "/vaults/Empty")
  end

  test "a page asked for by id settles on its vault address", ctx do
    %{conn: conn, hunt: hunt, questions: questions} = ctx
    # A board's wiki no longer links out to the vault view (#758).
    {:ok, view, _} = live(conn, ~p"/boards/#{hunt}/wiki/#{questions.slug}")
    refute has_element?(view, "#open-in-vault")

    # By id, it settles on the page's own address.
    assert {:error, {:live_redirect, %{to: "/vaults/Notes/Journal/Intake%20Questions"}}} =
             live(conn, "/vaults/Notes?page=#{questions.id}")
  end

  test "settings: one vault, its mount form, and Open from the list", ctx do
    %{conn: conn, user: user} = ctx
    {:ok, _} = Vaults.create_vault(user, %{"name" => "Other"})
    {:ok, view, html} = live(conn, "/vaults/Notes/.settings")

    assert html =~ "Vault settings"
    assert html =~ "Mount a board&#39;s wiki at a path"
    refute html =~ "Other"
    assert has_element?(view, "#open-vault-#{ctx.vault.id}[href='/vaults/Notes']")

    {:ok, home, _} = live(conn, ~p"/")
    assert has_element?(home, "#vault-tile-#{ctx.vault.id}[href='/vaults/Notes']")
  end

  test "a new note made in a folder of the vault lands on the board mapped there", ctx do
    %{conn: conn, kb: kb, notes: notes} = ctx
    {:ok, view, _} = live(conn, "/vaults/Notes/Big%20Ideas")
    reply = tree_load(view, %{"scope" => "vault", "keys" => ["folder:#{notes.id}"]})
    assert row(reply, "vault", "Big Ideas").board_id == kb.id
  end

  defp version(view) do
    [_, v] = Regex.run(~r/id="wiki-tree"[^>]*data-version="(\d+)"/s, render(view))
    String.to_integer(v)
  end

  # The wiki topics the view's process is subscribed to.
  defp topics(view) do
    Slipdock.PubSub
    |> Registry.keys(view.pid)
    |> Enum.filter(&String.starts_with?(&1, "wiki:"))
  end
end
