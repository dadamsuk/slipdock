defmodule SlipdockWeb.HeaderLinksLiveTest do
  @moduledoc "Header links (#1205): pinned in Account settings, drawn left of quick add."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{HeaderLinks, Vaults}

  setup %{user: user} do
    plan = board_fixture(%{"name" => "Plan"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain #{plan.id}"})
    %{plan: plan, vault: vault}
  end

  test "nothing pinned draws no links", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#header-links")
    assert has_element?(view, "#quick-add-open")
  end

  test "a pinned board and vault are drawn as their icons, before quick add, and go there",
       %{conn: conn, user: user, plan: plan, vault: vault} do
    {:ok, board_link} = HeaderLinks.add(user, plan, "rocket-launch")
    {:ok, vault_link} = HeaderLinks.add(user, vault, "book-open")

    {:ok, view, html} = live(conn, ~p"/work")

    assert has_element?(
             view,
             ~s(#header-link-#{board_link.id}[title="Plan"] .hero-rocket-launch)
           )

    assert has_element?(view, ~s(#header-link-#{vault_link.id} .hero-book-open))

    assert view |> element("#header-link-#{vault_link.id}") |> render() =~
             ~s(href="#{SlipdockWeb.VaultUrls.url(vault)}")

    # Left of quick add: the links come first in the header.
    {links_at, _} = :binary.match(html, ~s(id="header-links"))
    {quick_add_at, _} = :binary.match(html, ~s(id="quick-add-open"))
    assert links_at < quick_add_at

    view |> element("#header-link-#{board_link.id}") |> render_click()
    assert_redirect(view, SlipdockWeb.SwimlaneComponents.board_home_path(plan))
  end

  test "the links survive opening and closing quick add", %{conn: conn, user: user, plan: plan} do
    {:ok, link} = HeaderLinks.add(user, plan, "star")
    {:ok, view, _} = live(conn, ~p"/work")

    view |> element("#quick-add-open") |> render_click()
    view |> element("#quick-add-open") |> render_click()
    assert has_element?(view, "#header-link-#{link.id}")
  end

  test "Account settings pins one with the icon chosen, and the header shows it at once",
       %{conn: conn, user: user, vault: vault} do
    {:ok, view, _} = live(conn, ~p"/account/settings")
    assert has_element?(view, "#header-links-settings")
    refute has_element?(view, "#header-links")

    view
    |> form("#header-link-form-0", %{
      "header_link" => %{"target" => "vault:#{vault.id}", "icon" => "light-bulb"}
    })
    |> render_change()

    view
    |> form("#header-link-form-0", %{
      "header_link" => %{"target" => "vault:#{vault.id}", "icon" => "light-bulb"}
    })
    |> render_submit()

    assert [%{kind: :vault, icon: "light-bulb", id: id}] = HeaderLinks.list(user)
    assert has_element?(view, "#header-link-#{id} .hero-light-bulb")
    assert has_element?(view, "#header-link-row-#{id}")
    assert render(view) =~ "pinned to the header"

    # What is pinned is no longer offered.
    refute view |> element("#header-link-form-1") |> render() =~ "vault:#{vault.id}"
  end

  test "a refused pin says why and pins nothing", %{conn: conn, user: user, plan: plan} do
    {:ok, view, _} = live(conn, ~p"/account/settings")

    view
    |> element("#header-link-form-0")
    |> render_submit(%{"header_link" => %{"target" => "board:#{plan.id}", "icon" => "skull"}})

    assert render(view) =~ "Couldn&#39;t pin that"
    assert HeaderLinks.list(user) == []
  end

  test "settings moves and removes links, and the header follows",
       %{conn: conn, user: user, plan: plan, vault: vault} do
    {:ok, a} = HeaderLinks.add(user, plan, "star")
    {:ok, b} = HeaderLinks.add(user, vault, "flag")
    {:ok, view, _} = live(conn, ~p"/account/settings")

    view
    |> element(~s(#header-link-row-#{b.id} button[phx-value-direction="left"]))
    |> render_click()

    assert Enum.map(HeaderLinks.list(user), & &1.id) == [b.id, a.id]
    html = render(view)
    {b_at, _} = :binary.match(html, ~s(id="header-link-#{b.id}"))
    {a_at, _} = :binary.match(html, ~s(id="header-link-#{a.id}"))
    assert b_at < a_at

    view |> element("#header-link-row-#{a.id} button", "Remove") |> render_click()
    assert Enum.map(HeaderLinks.list(user), & &1.id) == [b.id]
    refute has_element?(view, "#header-link-#{a.id}")
    refute has_element?(view, "#header-link-row-#{a.id}")
  end

  test "a full header offers no form", %{conn: conn, user: user} do
    for _ <- 1..HeaderLinks.max(),
        do: {:ok, _} = HeaderLinks.add(user, board_fixture(%{}, owner: user), "star")

    {:ok, view, _} = live(conn, ~p"/account/settings")
    refute has_element?(view, "form[phx-submit=add_header_link]")
  end
end
