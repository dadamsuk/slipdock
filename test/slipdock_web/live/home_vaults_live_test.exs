defmodule SlipdockWeb.HomeVaultsLiveTest do
  @moduledoc "Vaults on the home page, beside the boards (#751)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults, Wiki}

  test "with no vaults, the home page has no vault section", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#vaults")
  end

  test "a tile per vault: its boards, pages and synced folders", %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbh"}, owner: user)
    hunt = board_fixture(%{"name" => "Journal Desk", "code" => "hunth"}, owner: user)
    {:ok, _} = Wiki.create_page(kb, %{"title" => "One"})
    {:ok, _} = Wiki.create_page(hunt, %{"title" => "Two"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: hunt})
    {_raw, token} = Accounts.create_api_token(user, "slipdock CLI on laptop")
    Vaults.touch_mirror(vault, token)
    {:ok, _empty} = Vaults.create_vault(user, %{"name" => "Empty"})

    {:ok, view, _} = live(conn, ~p"/")

    tile = "#vault-tile-#{vault.id}"
    assert has_element?(view, tile, "Notes")
    assert has_element?(view, tile, "2 pages")
    assert has_element?(view, tile, "Keystone · Journal Desk")
    assert has_element?(view, tile, "slipdock CLI on laptop")
    assert has_element?(view, "#vaults a", "No boards mapped yet")
  end

  test "somebody else's vault is not shown", %{conn: conn} do
    stranger = user_fixture("home-stranger@example.com")
    {:ok, _} = Vaults.create_vault(stranger, %{"name" => "Theirs"})
    {:ok, _view, html} = live(conn, ~p"/")
    refute html =~ "Theirs"
  end

  test "makes a vault from the home page, and says when the name won't do", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = Vaults.create_vault(user, %{"name" => "First"})
    {:ok, view, _} = live(conn, ~p"/")

    view |> element("#new-vault") |> render_click()
    view |> form("#new-vault-form", %{"name" => "Second"}) |> render_submit()
    assert [_, _] = Vaults.list_vaults(user)
    assert has_element?(view, "#vaults a", "Second")
    refute has_element?(view, "#new-vault-form")

    view |> element("#new-vault") |> render_click()
    html = view |> form("#new-vault-form", %{"name" => "second"}) |> render_submit()
    assert html =~ "already have a vault with that name"
    assert length(Vaults.list_vaults(user)) == 2
  end

  describe "a board kept inside its vault (#757)" do
    setup %{user: user} do
      kb = board_fixture(%{"name" => "Keystone", "code" => "kbin"}, owner: user)
      plain = board_fixture(%{"name" => "Plain Board", "code" => "plainin"}, owner: user)
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb, inside: true})
      %{kb: kb, plain: plain, vault: vault}
    end

    test "leaves the owner's boards and is named on the vault's tile", ctx do
      %{conn: conn, kb: kb, plain: plain, vault: vault} = ctx
      [column | _] = Slipdock.Repo.preload(kb, :columns).columns
      card_fixture(column, %{"title" => "Something to do"})
      {:ok, view, _} = live(conn, ~p"/")

      refute has_element?(view, "#boards a[href='/boards/#{kb.id}']")
      assert has_element?(view, "#boards", plain.name)

      inside = "#vault-inside-#{vault.id}-#{kb.id}"

      assert has_element?(
               view,
               "#{inside}[href='/boards/#{kb.id}']",
               "pages stored on Keystone"
             )

      assert has_element?(view, inside, "1 card")
    end

    test "still reachable at its address", %{conn: conn, kb: kb} do
      assert {:ok, _view, html} = live(conn, ~p"/boards/#{kb}")
      assert html =~ "Keystone"
    end

    test "anyone it is shared with sees an ordinary board", %{kb: kb, user: owner} do
      member = user_fixture("inside-member@example.com")
      {:ok, _} = Slipdock.Access.grant(kb, member, "read", owner)

      {:ok, view, _} = live(conn_as(member), ~p"/")
      assert has_element?(view, "#boards", "Keystone")
      refute has_element?(view, "#vaults")
    end

    test "back on the home page when unmapped, or the vault is deleted", ctx do
      %{conn: conn, kb: kb, vault: vault, user: user} = ctx
      {:ok, _} = Vaults.remove_mapping(vault, "/")
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#boards", "Keystone")

      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb, inside: true})
      {:ok, _} = Vaults.delete_vault(vault)
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#boards", "Keystone")
    end

    test "a new vault can come with a board to hold its pages, kept inside", ctx do
      %{conn: conn, user: user} = ctx
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-vault") |> render_click()

      html =
        view
        |> form("#new-vault-form", %{"name" => "Brain", "with_board" => "true"})
        |> render_submit()

      assert html =~ "with a board of the same name holding its pages"
      {:ok, brain} = Vaults.get_vault(user, "Brain")
      assert [%{path: "", inside: true, board: board}] = brain.mappings
      assert has_element?(view, "#vault-inside-#{brain.id}-#{board.id}", "pages stored on Brain")
      refute has_element?(view, "#boards a[href='/boards/#{board.id}']")
    end
  end
end
