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

    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Notes"})
    %{kb: kb, hunt: hunt, notes: notes, idea: idea, questions: questions, vault: vault}
  end

  test "a page opens at its vault path, spaces and all, with the vault's breadcrumbs", ctx do
    %{conn: conn, hunt: hunt} = ctx
    {:ok, view, html} = live(conn, "/vaults/Notes/Journal%20Desk/Intake%20Questions")

    assert html =~ "Why us?"
    assert has_element?(view, "#vault-crumbs a", "Notes")

    assert has_element?(
             view,
             "#vault-crumbs a[href='/vaults/Notes/Journal%20Desk']",
             "Journal Desk"
           )

    assert has_element?(view, "#vault-board", "on Journal Desk")
    assert has_element?(view, "#vault-board[href='/boards/#{hunt.id}/wiki/intake-questions']")
    assert has_element?(view, "#vault-settings[href='/vaults/Notes/.settings']")
  end

  test "a page in a board's folder, case aside, .md or not", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/vaults/notes/keystone/big%20ideas/PLAIN%20TEXT.md")
    assert html =~ "Write it down."
  end

  test "the vault's top lists every board's notes, a board and a folder their own", ctx do
    %{conn: conn} = ctx
    {:ok, _view, html} = live(conn, "/vaults/Notes")
    assert html =~ "Plain text"
    assert html =~ "Intake Questions"

    {:ok, view, _html} = live(conn, "/vaults/Notes/Journal%20Desk")
    assert has_element?(view, "h1", "Journal Desk")
    assert render(view) =~ "Intake Questions"
    refute render(view) =~ "Plain text"

    {:ok, view, _html} = live(conn, "/vaults/Notes/Keystone/Big%20Ideas")
    assert has_element?(view, "#vault-crumbs a", "Big Ideas")
    assert render(view) =~ "Plain text"
  end

  test "its top stands on a live board when the first is archived", ctx do
    %{conn: conn, kb: kb, hunt: hunt} = ctx
    {:ok, _} = Slipdock.Boards.archive_board(hunt)
    {:ok, view, _html} = live(conn, "/vaults/Notes")
    assert has_element?(view, "#wiki-tree[data-board='#{kb.id}']")
  end

  test "an archived board keeps its address", %{conn: conn, hunt: hunt} do
    {:ok, _} = Slipdock.Boards.archive_board(hunt)
    {:ok, _view, html} = live(conn, "/vaults/Notes/Journal%20Desk/Intake%20Questions")
    assert html =~ "Why us?"
  end

  test "the tree is the vault's, and its rows open at their vault addresses", ctx do
    %{conn: conn, kb: kb, hunt: hunt} = ctx
    {:ok, view, _} = live(conn, "/vaults/Notes/Journal%20Desk/Intake%20Questions")

    # Whatever the hook remembers, the vault view's tree is the vault's.
    reply =
      tree_load(view, %{"scope" => "board", "keys" => ["board:#{kb.id}", "board:#{hunt.id}"]})

    assert reply.scope == "vault"
    # The home page's hand-made order: neither is placed, so oldest first.
    assert titles(reply, "vault") == ["Keystone", "Journal Desk"]
    row = row(reply, "board:#{kb.id}", "Big Ideas")
    assert row.href == "/vaults/Notes/Keystone/Big%20Ideas"
    assert row.nav == "patch"

    assert row(reply, "board:#{hunt.id}", "Intake Questions").href ==
             "/vaults/Notes/Journal%20Desk/Intake%20Questions"
  end

  # The tree's rows open by patching (none of them by a fresh view, which
  # would tear the tree down and draw it again from nothing on every click).
  test "a row opens by patching, onto another board too, in the same view", ctx do
    %{conn: conn, kb: kb, hunt: hunt, questions: questions} = ctx
    {:ok, view, _} = live(conn, "/vaults/Notes/Keystone/Big%20Ideas/Plain%20text")
    render_hook(view, "tree_view", %{"view" => "recent"})
    before = version(view)
    assert topics(view) == ["wiki:#{kb.id}"]

    # A page on another board: its board's wiki, under the vault's tree.
    html = render_patch(view, "/vaults/Notes/Journal%20Desk/Intake%20Questions")
    assert html =~ "Why us?"
    assert has_element?(view, "#vault-board", "on Journal Desk")

    assert has_element?(
             view,
             "#vault-crumbs a[href='/vaults/Notes/Journal%20Desk']",
             "Journal Desk"
           )

    assert has_element?(view, "#wiki-tree[data-current='page:#{questions.id}']")
    assert tree_load(view).scope == "vault"
    # The hook is told to ask for the rows again; the reader's choice of
    # list is kept; and it now hears about this board's changes, not the last.
    assert version(view) > before
    assert has_element?(view, "#wiki-tree-view-recent[aria-pressed='true']")
    assert topics(view) == ["wiki:#{hunt.id}"]

    # Another page of the same board changes only what is shown.
    after_switch = version(view)
    assert render_patch(view, "/vaults/Notes/Journal%20Desk") =~ "Intake Questions"
    assert version(view) == after_switch
  end

  test "patched to an address with nothing there, the view starts afresh", %{conn: conn} do
    {:ok, view, _} = live(conn, "/vaults/Notes/Keystone/Big%20Ideas")

    assert {:error, {:live_redirect, %{to: "/vaults/Notes/Nope"}}} =
             render_patch(view, "/vaults/Notes/Nope")
  end

  test "a board shared by somebody else has no address in the vault", ctx do
    %{conn: conn, user: user} = ctx
    lender = user_fixture("lender-view@example.com")
    lent = board_fixture(%{"name" => "Lent", "code" => "lentv"}, owner: lender)
    share_fixture(lent, user, "read")
    {:ok, _} = Wiki.create_page(lent, %{"title" => "Borrowed", "body" => "Read me."})

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/vaults/Notes/Lent/Borrowed")
  end

  test "an address with nothing there, or someone else's vault, goes home", ctx do
    %{conn: conn} = ctx
    assert {:error, {:live_redirect, %{to: "/", flash: _}}} = live(conn, "/vaults/Notes/Nope")

    stranger = user_fixture("stranger-view@example.com")
    _ = Vaults.root(stranger)
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/vaults/Theirs")
  end

  test "a vault with no boards sends you to its settings, and says why" do
    user = user_fixture("no-boards-view@example.com")
    vault = Vaults.root(user)

    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn_as(user), "/vaults/#{vault.name}")

    assert to == "/vaults/#{vault.name}/.settings"
    assert flash["info"] =~ "nothing in it yet"
  end

  test "a page asked for by id settles on its vault address", ctx do
    %{conn: conn, hunt: hunt, questions: questions} = ctx
    # A board's wiki no longer links out to the vault view (#758).
    {:ok, view, _} = live(conn, ~p"/boards/#{hunt}/wiki/#{questions.slug}")
    refute has_element?(view, "#open-in-vault")

    # By id, it settles on the page's own address.
    assert {:error, {:live_redirect, %{to: "/vaults/Notes/Journal%20Desk/Intake%20Questions"}}} =
             live(conn, "/vaults/Notes?page=#{questions.id}")
  end

  test "settings: the vault's page, and Open and the home tile lead to the tree", ctx do
    %{conn: conn} = ctx
    {:ok, view, html} = live(conn, "/vaults/Notes/.settings")

    assert html =~ "Your vault"
    refute html =~ "Mount a board"
    assert has_element?(view, "#open-vault-#{ctx.vault.id}[href='/vaults/Notes']")

    {:ok, home, _} = live(conn, ~p"/")
    assert has_element?(home, "#vault-tile-#{ctx.vault.id}[href='/vaults/Notes']")
  end

  test "a folder of the vault says which board it is on", ctx do
    %{conn: conn, kb: kb, notes: notes} = ctx
    {:ok, view, _} = live(conn, "/vaults/Notes/Keystone/Big%20Ideas")

    reply =
      tree_load(view, %{"scope" => "vault", "keys" => ["board:#{kb.id}", "folder:#{notes.id}"]})

    assert row(reply, "board:#{kb.id}", "Big Ideas").board_id == kb.id
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

  test "a page on a sub-board opens at its address in its epic's folder", ctx do
    %{conn: conn, user: user} = ctx
    board = board_fixture(%{"name" => "Plans", "code" => "vvsub"}, owner: user)
    {:ok, template} = Slipdock.Boards.find_template(nil, "Simple")
    [column | _] = board.columns
    epic = card_fixture(column, %{"title" => "Launch"})
    {:ok, sub} = sub_board(epic, template)
    {:ok, _} = Slipdock.Wiki.create_page(sub, %{"title" => "Inner note"}, user: user)
    vault = Slipdock.Vaults.root(user)

    {:ok, _view, html} = live(conn, "/vaults/#{vault.name}/Plans/Cards/Launch/Inner note")

    assert html =~ "Inner note"
  end
end
