defmodule SlipdockWeb.VaultsLiveTest do
  @moduledoc "The vault's page (W-2201): the root vault's tree link, name and synced folders."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults, Wiki}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kb7"}, owner: user)
    %{kb: kb}
  end

  test "the account menu reaches it, and it says what a vault is", %{conn: conn, user: user} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/vaults")

    {:ok, view, _html} = live(conn, ~p"/vaults")
    assert has_element?(view, "#vaults-what", "Every board you own is a folder")
    assert has_element?(view, "#vault-#{Vaults.root(user).id}")
  end

  test "shows the one vault, its page count, a link to its tree and its synced folders", ctx do
    %{conn: conn, user: user, kb: kb} = ctx
    {:ok, _} = Wiki.create_page(kb, %{"title" => "A"})
    {:ok, _} = Wiki.create_page(kb, %{"title" => "B"})
    vault = Vaults.root(user)
    {_raw, token} = Accounts.create_api_token(user, "slipdock CLI on laptop")
    Vaults.touch_mirror(vault, token)

    {:ok, view, _html} = live(conn, ~p"/vaults")

    assert has_element?(view, "#vault-pages-#{vault.id}", "2 pages")
    assert has_element?(view, "#open-vault-#{vault.id}[href='/vaults/#{vault.name}']")
    assert has_element?(view, "#vault-#{vault.id} [id^=mirror-]", "slipdock CLI on laptop")
  end

  test "its tree link opens the root's tree", ctx do
    %{conn: conn, user: user} = ctx
    vault = Vaults.root(user)

    {:ok, view, _html} = live(conn, ~p"/vaults")

    {:ok, tree, _html} =
      view |> element("#open-vault-#{vault.id}") |> render_click() |> follow_redirect(conn)

    assert has_element?(tree, "#vault-settings")
    assert render(tree) =~ "Every board in #{vault.name}"
  end

  test "nothing of the mounting is left", %{conn: conn, user: user} do
    vault = Vaults.root(user)
    {:ok, view, html} = live(conn, ~p"/vaults")

    refute has_element?(view, "#map-form-#{vault.id}")
    refute has_element?(view, "#delete-vault-#{vault.id}")
    refute has_element?(view, "form[phx-submit=create]")
    refute html =~ "Mappings"
  end

  test "says how to sync it when nothing is synced", %{conn: conn, user: user} do
    vault = Vaults.root(user)
    {:ok, view, _html} = live(conn, ~p"/vaults")
    assert has_element?(view, "#vault-#{vault.id} code", "slipdock sync init")
  end

  test "renames the vault, and refuses a name it can't take", %{conn: conn, user: user} do
    vault = Vaults.root(user)
    {:ok, view, _html} = live(conn, ~p"/vaults")

    view
    |> form("#vault-#{vault.id} form[phx-submit=rename]", %{"name" => "Notes"})
    |> render_submit()

    assert {:ok, %{name: "Notes"}} = Vaults.get_vault(user, vault.id)

    html =
      view
      |> form("#vault-#{vault.id} form[phx-submit=rename]", %{"name" => "a/b"})
      |> render_submit()

    assert html =~ "cannot contain a slash"
    assert {:ok, %{name: "Notes"}} = Vaults.get_vault(user, vault.id)
  end

  test "its settings address shows the same page; somebody else's is not found", ctx do
    %{conn: conn, user: user} = ctx
    vault = Vaults.root(user)
    {:ok, view, _html} = live(conn, "/vaults/#{vault.name}/.settings")
    assert has_element?(view, "#vault-#{vault.id}")

    assert {:error, {:live_redirect, %{to: "/vaults"}}} =
             live(conn, "/vaults/Nobody-by-that-name/.settings")
  end

  test "somebody else's vault is not found: not shown, not renamed", %{conn: conn} do
    stranger = user_fixture("stranger@example.com")
    {:ok, theirs} = stranger |> Vaults.root() |> Vaults.update_vault(%{"name" => "Theirs"})

    {:ok, view, html} = live(conn, ~p"/vaults")
    refute html =~ "Theirs"

    render_submit(view, "rename", %{"vault_id" => to_string(theirs.id), "name" => "Mine now"})
    assert render(view) =~ "isn&#39;t there any more"
    assert {:ok, %{name: "Theirs"}} = Vaults.get_vault(stranger, theirs.id)
  end

  test "a board's wiki has no switch out to the vault (#758)", ctx do
    %{conn: conn, kb: kb} = ctx
    {:ok, _} = Wiki.create_page(kb, %{"title" => "Note"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{kb.id}/wiki")

    refute has_element?(view, "#open-in-vault")
    refute has_element?(view, "[data-tree-scope]")
  end
end
