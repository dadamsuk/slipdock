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
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kbh"}, owner: user)
    hunt = board_fixture(%{"name" => "Job Hunt", "code" => "hunth"}, owner: user)
    {:ok, _} = Wiki.create_page(kb, %{"title" => "One"})
    {:ok, _} = Wiki.create_page(hunt, %{"title" => "Two"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: hunt})
    {_raw, token} = Accounts.create_api_token(user, "slipdock CLI on laptop")
    Vaults.touch_mirror(vault, token)
    {:ok, _empty} = Vaults.create_vault(user, %{"name" => "Empty"})

    {:ok, view, _} = live(conn, ~p"/")

    tile = "#vault-tile-#{vault.id}"
    assert has_element?(view, tile, "GMinds")
    assert has_element?(view, tile, "2 pages")
    assert has_element?(view, tile, "KnowledgeBase · Job Hunt")
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
end
