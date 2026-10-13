defmodule SlipdockWeb.VaultsLiveTest do
  @moduledoc "The vaults screen: see, make, rename and delete vaults (W-103 R1.1)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults, Wiki}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kb"}, owner: user)
    %{kb: kb}
  end

  test "the account menu reaches it, and with no vaults it says what one is", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/vaults")

    {:ok, view, _html} = live(conn, ~p"/vaults")
    assert has_element?(view, "#vaults-empty", "You have no vaults yet")
    assert has_element?(view, "#vaults-what", "owns no pages")
  end

  test "lists each vault with its mappings, page counts and synced folders", ctx do
    %{conn: conn, user: user, kb: kb} = ctx
    {:ok, folder} = Wiki.create_folder(kb, %{"name" => "Jobs"})
    {:ok, _} = Wiki.create_page(kb, %{"title" => "A"})
    {:ok, _} = Wiki.create_page(kb, %{"title" => "B", "folder_id" => folder.id})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    {:ok, root} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, jobs} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: kb, folder: folder})
    {_raw, token} = Accounts.create_api_token(user, "slipdock CLI on laptop")
    Vaults.touch_mirror(vault, token)

    {:ok, view, _html} = live(conn, ~p"/vaults")

    refute has_element?(view, "#vaults-empty")
    assert has_element?(view, "#mapping-#{root.id}", "KnowledgeBase")
    assert has_element?(view, "#mapping-#{root.id}", "1 page")
    assert has_element?(view, "#mapping-#{jobs.id}", "folder Jobs")
    assert has_element?(view, "#mapping-#{jobs.id}", "1 page")
    assert has_element?(view, "#vault-#{vault.id} [id^=mirror-]", "slipdock CLI on laptop")
  end

  test "makes a vault, and refuses a name it can't take", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/vaults")

    view |> form("form[phx-submit=create]", %{"name" => "Brain"}) |> render_submit()
    assert [%{name: "Brain"}] = Vaults.list_vaults(user)
    assert has_element?(view, "input[aria-label='Vault name'][value=Brain]")
    assert has_element?(view, "[id^=vault-] p", "Nothing mapped yet")

    html = view |> form("form[phx-submit=create]", %{"name" => "a/b"}) |> render_submit()
    assert html =~ "cannot contain a slash"
    assert length(Vaults.list_vaults(user)) == 1
  end

  test "renames a vault, and says so when the name is taken", %{conn: conn, user: user} do
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.create_vault(user, %{"name" => "Other"})
    {:ok, view, _html} = live(conn, ~p"/vaults")

    view
    |> form("#vault-#{vault.id} form[phx-submit=rename]", %{"name" => "GMinds"})
    |> render_submit()

    assert {:ok, %{name: "GMinds"}} = Vaults.get_vault(user, vault.id)

    html =
      view
      |> form("#vault-#{vault.id} form[phx-submit=rename]", %{"name" => "other"})
      |> render_submit()

    assert html =~ "already have a vault with that name"
    assert {:ok, %{name: "GMinds"}} = Vaults.get_vault(user, vault.id)
  end

  test "deleting confirms that pages stay and names the synced folders, then keeps them", ctx do
    %{conn: conn, user: user, kb: kb} = ctx
    {:ok, page} = Wiki.create_page(kb, %{"title" => "Kept"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {_raw, token} = Accounts.create_api_token(user, "slipdock CLI on laptop")
    Vaults.touch_mirror(vault, token)

    {:ok, view, _html} = live(conn, ~p"/vaults")

    confirm = view |> element("#delete-vault-#{vault.id}") |> render()

    assert confirm =~ "Every page stays on its board"
    assert confirm =~ "only the layout"
    assert confirm =~ "stop getting changes: slipdock CLI on laptop"

    view |> element("#delete-vault-#{vault.id}") |> render_click()

    assert Vaults.list_vaults(user) == []
    assert Wiki.get_page(page.id)
    assert has_element?(view, "#vaults-empty")
  end

  test "a vault with no synced folder confirms without naming any", %{user: user} do
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    text = SlipdockWeb.VaultLive.Index.delete_confirm(vault, [])
    assert text =~ "Every page stays on its board"
    refute text =~ "synced"
  end

  test "somebody else's vault is not found: not listed, not renamed, not deleted", ctx do
    %{conn: conn} = ctx
    stranger = user_fixture("stranger@example.com")
    {:ok, theirs} = Vaults.create_vault(stranger, %{"name" => "Theirs"})

    {:ok, view, html} = live(conn, ~p"/vaults")
    refute html =~ "Theirs"

    render_submit(view, "rename", %{"vault_id" => to_string(theirs.id), "name" => "Mine now"})
    assert render(view) =~ "isn&#39;t there any more"
    render_click(view, "delete", %{"id" => to_string(theirs.id)})

    assert {:ok, %{name: "Theirs"}} = Vaults.get_vault(stranger, theirs.id)
  end

  test "the wiki's tree switch explains a vault and links its owner here", ctx do
    %{conn: conn, user: user, kb: kb} = ctx
    {:ok, _} = Wiki.create_page(kb, %{"title" => "Note"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})

    {:ok, view, _html} = live(conn, ~p"/boards/#{kb.id}/wiki")

    assert has_element?(view, "button[data-tree-scope=vault][title*='not a folder']")
    assert has_element?(view, "#manage-vault[href='/vaults#vault-#{vault.id}']")
  end
end
