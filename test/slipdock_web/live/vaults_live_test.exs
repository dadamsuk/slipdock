defmodule SlipdockWeb.VaultsLiveTest do
  @moduledoc """
  The wiki's settings (W-2201), at `/wiki/.settings`: its page count, a link
  to its tree, its keys and synced folders. A wiki has no name to change,
  and no address of anybody else's reaches theirs.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults, Wiki}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kb7"}, owner: user)
    %{kb: kb}
  end

  test "the menu reaches the wiki, and its settings say what it is", %{conn: conn, user: user} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/wiki")
    refute html =~ ~s(href="/vaults")

    {:ok, view, _html} = live(conn, ~p"/wiki/.settings")
    assert has_element?(view, "#vaults-what", "your Knowledge Base first")
    assert has_element?(view, "#vault-#{Vaults.root(user).id}")
  end

  test "shows its page count, a link to its tree and its synced folders", ctx do
    %{conn: conn, user: user, kb: kb} = ctx
    {:ok, _} = Wiki.create_page(kb, %{"title" => "A"})
    {:ok, _} = Wiki.create_page(kb, %{"title" => "B"})
    vault = Vaults.root(user)
    {_raw, token} = Accounts.create_api_token(user, "slipdock CLI on laptop")
    Vaults.touch_mirror(vault, token)

    {:ok, view, _html} = live(conn, ~p"/wiki/.settings")

    assert has_element?(view, "#vault-pages-#{vault.id}", "2 pages")
    assert has_element?(view, "#open-vault-#{vault.id}[href='/wiki']")
    assert has_element?(view, "#vault-#{vault.id} [id^=mirror-]", "slipdock CLI on laptop")
  end

  test "its tree link opens the wiki's tree", %{conn: conn, user: user} do
    vault = Vaults.root(user)
    {:ok, view, _html} = live(conn, ~p"/wiki/.settings")

    {:ok, tree, _html} =
      view |> element("#open-vault-#{vault.id}") |> render_click() |> follow_redirect(conn)

    assert has_element?(tree, "#vault-settings")
    assert render(tree) =~ "Your wiki"
  end

  test "nothing of the mounting, or of a name, is left", %{conn: conn, user: user} do
    vault = Vaults.root(user)
    {:ok, view, html} = live(conn, ~p"/wiki/.settings")

    refute has_element?(view, "#map-form-#{vault.id}")
    refute has_element?(view, "#delete-vault-#{vault.id}")
    refute has_element?(view, "form[phx-submit=create]")
    refute has_element?(view, "form[phx-submit=rename]")
    refute html =~ "Mappings"
  end

  test "says how to sync it when nothing is synced, naming no vault", %{conn: conn, user: user} do
    vault = Vaults.root(user)
    {:ok, view, _html} = live(conn, ~p"/wiki/.settings")
    assert has_element?(view, "#vault-#{vault.id} code", "slipdock sync init ~/Notes")
    refute render(view) =~ "--vault"
  end

  test "an old settings address lands here", %{conn: conn} do
    assert redirected_to(get(conn, "/vaults/Nobody-by-that-name/.settings")) ==
             "/wiki/.settings"
  end

  test "somebody else's wiki can't be changed from here", %{conn: conn} do
    stranger = user_fixture("stranger@example.com")
    theirs = Vaults.root(stranger)

    {:ok, view, _html} = live(conn, ~p"/wiki/.settings")

    render_submit(view, "keys", %{"vault_id" => to_string(theirs.id), "shortcut" => "zz"})
    assert render(view) =~ "isn&#39;t there any more"
    assert Vaults.root(stranger).shortcut == theirs.shortcut
  end

  test "a board's wiki has no switch out to another view (#758)", ctx do
    %{conn: conn, kb: kb} = ctx
    {:ok, _} = Wiki.create_page(kb, %{"title" => "Note"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{kb.id}/wiki")

    refute has_element?(view, "#open-in-vault")
    refute has_element?(view, "[data-tree-scope]")
  end
end
