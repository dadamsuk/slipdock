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
    {:ok, view, html} = live(conn, "/wiki/Journal%20Desk/Intake%20Questions")

    assert html =~ "Why us?"
    assert has_element?(view, "#vault-crumbs a[href='/wiki']", "Wiki")

    assert has_element?(
             view,
             "#vault-crumbs a[href='/wiki/Journal%20Desk']",
             "Journal Desk"
           )

    assert has_element?(view, "#vault-board", "on Journal Desk")
    assert has_element?(view, "#vault-board[href='/boards/#{hunt.id}/wiki/intake-questions']")
    assert has_element?(view, "#vault-settings[href='/wiki/.settings']")
  end

  test "a page in a board's folder, case aside, .md or not", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/wiki/keystone/big%20ideas/PLAIN%20TEXT.md")
    assert html =~ "Write it down."
  end

  test "the vault's top lists every board's notes, a board and a folder their own", ctx do
    %{conn: conn} = ctx
    {:ok, _view, html} = live(conn, "/wiki")
    assert html =~ "Plain text"
    assert html =~ "Intake Questions"

    {:ok, view, _html} = live(conn, "/wiki/Journal%20Desk")
    assert has_element?(view, "h1", "Journal Desk")
    assert render(view) =~ "Intake Questions"
    refute render(view) =~ "Plain text"

    {:ok, view, _html} = live(conn, "/wiki/Keystone/Big%20Ideas")
    assert has_element?(view, "#vault-crumbs a", "Big Ideas")
    assert render(view) =~ "Plain text"
  end

  test "its top stands on a live board when the first is archived", ctx do
    %{conn: conn, kb: kb, hunt: hunt} = ctx
    {:ok, _} = Slipdock.Boards.archive_board(hunt)
    {:ok, view, _html} = live(conn, "/wiki")
    assert has_element?(view, "#wiki-tree[data-board='#{kb.id}']")
  end

  test "an archived board keeps its address", %{conn: conn, hunt: hunt} do
    {:ok, _} = Slipdock.Boards.archive_board(hunt)
    {:ok, _view, html} = live(conn, "/wiki/Journal%20Desk/Intake%20Questions")
    assert html =~ "Why us?"
  end

  test "the tree is the vault's, and its rows open at their vault addresses", ctx do
    %{conn: conn, kb: kb, hunt: hunt} = ctx
    {:ok, view, _} = live(conn, "/wiki/Journal%20Desk/Intake%20Questions")

    # Whatever the hook remembers, the vault view's tree is the vault's.
    reply =
      tree_load(view, %{"scope" => "board", "keys" => ["board:#{kb.id}", "board:#{hunt.id}"]})

    assert reply.scope == "vault"
    # The home page's hand-made order: neither is placed, so oldest first.
    assert titles(reply, "vault") == ["Knowledge Base", "Keystone", "Journal Desk"]
    row = row(reply, "board:#{kb.id}", "Big Ideas")
    assert row.href == "/wiki/Keystone/Big%20Ideas"
    assert row.nav == "patch"

    assert row(reply, "board:#{hunt.id}", "Intake Questions").href ==
             "/wiki/Journal%20Desk/Intake%20Questions"
  end

  # The tree's rows open by patching (none of them by a fresh view, which
  # would tear the tree down and draw it again from nothing on every click).
  test "a row opens by patching, onto another board too, in the same view", ctx do
    %{conn: conn, kb: kb, hunt: hunt, questions: questions} = ctx
    {:ok, view, _} = live(conn, "/wiki/Keystone/Big%20Ideas/Plain%20text")
    render_hook(view, "tree_view", %{"view" => "recent"})
    before = version(view)
    assert topics(view) == ["wiki:#{kb.id}"]

    # A page on another board: its board's wiki, under the vault's tree.
    html = render_patch(view, "/wiki/Journal%20Desk/Intake%20Questions")
    assert html =~ "Why us?"
    assert has_element?(view, "#vault-board", "on Journal Desk")

    assert has_element?(
             view,
             "#vault-crumbs a[href='/wiki/Journal%20Desk']",
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
    assert render_patch(view, "/wiki/Journal%20Desk") =~ "Intake Questions"
    assert version(view) == after_switch
  end

  test "patched to an address with nothing there, the view starts afresh", %{conn: conn} do
    {:ok, view, _} = live(conn, "/wiki/Keystone/Big%20Ideas")

    assert {:error, {:live_redirect, %{to: "/wiki/Nope"}}} =
             render_patch(view, "/wiki/Nope")
  end

  test "a board shared by somebody else has no address in the vault", ctx do
    %{conn: conn, user: user} = ctx
    lender = user_fixture("lender-view@example.com")
    lent = board_fixture(%{"name" => "Lent", "code" => "lentv"}, owner: lender)
    share_fixture(lent, user, "read")
    {:ok, _} = Wiki.create_page(lent, %{"title" => "Borrowed", "body" => "Read me."})

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/wiki/Lent/Borrowed")
  end

  test "an address with nothing there goes home", ctx do
    %{conn: conn} = ctx
    assert {:error, {:live_redirect, %{to: "/", flash: _}}} = live(conn, "/wiki/Nope")
  end

  test "an address from when it was a named vault lands in the same place", ctx do
    %{conn: conn} = ctx

    assert redirected_to(get(conn, "/vaults/Notes/Journal%20Desk/Intake%20Questions")) ==
             "/wiki/Journal%20Desk/Intake%20Questions"

    assert redirected_to(get(conn, "/vaults/Theirs")) == "/wiki"
    assert redirected_to(get(conn, "/vaults")) == "/wiki"
    assert redirected_to(get(conn, "/vaults/Notes/.settings")) == "/wiki/.settings"
  end

  test "somebody with no boards finds their Knowledge Base there" do
    user = user_fixture("no-boards-view@example.com")
    {:ok, view, _html} = live(conn_as(user), "/wiki")

    assert titles(tree_load(view, %{"scope" => "vault", "keys" => ["vault"]}), "vault") ==
             ["Knowledge Base"]
  end

  test "a page asked for by id settles on its vault address", ctx do
    %{conn: conn, hunt: hunt, questions: questions} = ctx
    # A board's wiki no longer links out to the vault view (#758).
    {:ok, view, _} = live(conn, ~p"/boards/#{hunt}/wiki/#{questions.slug}")
    refute has_element?(view, "#open-in-vault")

    # By id, it settles on the page's own address.
    assert {:error, {:live_redirect, %{to: "/wiki/Journal%20Desk/Intake%20Questions"}}} =
             live(conn, "/wiki?page=#{questions.id}")
  end

  test "settings: the wiki's page, and Open and the home page's Wiki link lead to the tree",
       ctx do
    %{conn: conn} = ctx
    {:ok, view, html} = live(conn, "/wiki/.settings")

    assert html =~ "Wiki settings"
    # No text a person reads says "vault" (ids and form fields aside).
    refute html =~ ~r/>[^<]*\bvaults?\b[^<]*</i
    refute html =~ "Rename"
    assert has_element?(view, "#open-vault-#{ctx.vault.id}[href='/wiki']")

    {:ok, home, _} = live(conn, ~p"/")
    refute has_element?(home, "[id^='vault-tile-']")
    assert has_element?(home, "a[href='/wiki']", "Wiki")
  end

  test "a folder of the vault says which board it is on", ctx do
    %{conn: conn, kb: kb, notes: notes} = ctx
    {:ok, view, _} = live(conn, "/wiki/Keystone/Big%20Ideas")

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

    {:ok, _view, html} = live(conn, "/wiki/Plans/Cards/Launch/Inner note")

    assert html =~ "Inner note"
  end
end
