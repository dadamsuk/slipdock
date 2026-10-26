defmodule SlipdockWeb.PageLinkLiveTest do
  @moduledoc """
  Finding a page to reference (#1302): the picker `[[` opens in a Markdown
  editor (`SlipdockWeb.PageLinkHook`), and the card's "Attach a page already
  written…" box. Both match a title, a folder or a code, and offer the pages
  changed most lately before anything is typed.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Wiki.{Folders, Page}
  alias SlipdockWeb.PageLinkHook

  setup %{user: user} do
    board = board_fixture(%{"name" => "Links", "code" => "plink1302"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Wire up the docs"})
    {:ok, design} = Folders.create(board, %{"name" => "Design"})

    old = page_fixture(board, %{"title" => "Retry policy"}, user: user)
    spec = page_fixture(board, %{"title" => "Billing spec", "folder_id" => design.id}, user: user)
    new = page_fixture(board, %{"title" => "Release notes"}, user: user)

    age(old, 3)
    age(spec, 2)
    age(new, 1)

    %{board: board, card: card, old: old, spec: spec, new: new}
  end

  # Pages made in one test land in the same second; push each back in time.
  defp age(page, days) do
    at = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.truncate(:second)
    Repo.update_all(from(p in Page, where: p.id == ^page.id), set: [updated_at: at])
  end

  defp suggest(view, params) do
    render_hook(view, "page_link_suggest", params)
    assert_reply(view, %{pages: pages})
    pages
  end

  describe "typing [[ in an editor" do
    test "offers the most recently changed pages first", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      assert ["Release notes", "Billing spec", "Retry policy" | _] =
               view |> suggest(%{"q" => "", "fresh" => true}) |> Enum.map(& &1.title)
    end

    test "finds a page by title, folder or code, and says where it sits", %{
      conn: conn,
      board: board,
      spec: spec
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      assert [%{title: "Retry policy", insert: "[[Retry policy]]"} | _] =
               suggest(view, %{"q" => "retry", "fresh" => true})

      assert [%{id: id, path: "Design"} | _] = suggest(view, %{"q" => "design"})
      assert [%{id: ^id} | _] = suggest(view, %{"q" => "design/bill"})
      assert id == spec.id

      assert [%{id: ^id, insert: insert}] =
               view |> suggest(%{"q" => spec.code}) |> Enum.filter(&(&1.code == spec.code))

      assert insert == "[[Billing spec]]"
    end

    test "works from a card's editors, on the card's board", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/cards/#{card}")
      assert html =~ ~s(phx-hook="PageLink")

      assert "Release notes" in Enum.map(
               suggest(view, %{"q" => "rel", "board" => to_string(board.id), "fresh" => true}),
               & &1.title
             )
    end

    test "never offers pages from a board the reader cannot open", %{conn: conn, board: board} do
      stranger = user_fixture("stranger1302@example.com")
      theirs = board_fixture(%{"name" => "Private", "code" => "plink1302x"}, owner: stranger)
      page_fixture(theirs, %{"title" => "Secret plans"}, user: stranger)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      # The board named is not theirs: the view's own board answers instead.
      titles =
        view
        |> suggest(%{"q" => "", "board" => to_string(theirs.id), "fresh" => true})
        |> Enum.map(& &1.title)

      refute "Secret plans" in titles
      assert "Release notes" in titles
    end

    test "a view with no board offers nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/work")
      assert [] = suggest(view, %{"q" => "", "fresh" => true})
    end
  end

  describe "the link written for a page" do
    test "is [[Title]] when the title alone finds it, else its code", %{
      board: board,
      old: old,
      user: user
    } do
      other = board_fixture(%{"name" => "Elsewhere", "code" => "plink1302o"}, owner: user)
      twin = page_fixture(board, %{"title" => "Twin"}, user: user)
      twin2 = page_fixture(board, %{"title" => "twin"}, user: user)
      slashed = page_fixture(board, %{"title" => "A/B testing"}, user: user)
      piped = page_fixture(board, %{"title" => "This | that"}, user: user)
      coded = page_fixture(board, %{"title" => "W-9"}, user: user)

      pool = Wiki.Switcher.pool(user, board)
      entry = fn page -> Enum.find(pool, &(&1.id == page.id)) end

      assert PageLinkHook.link_for(entry.(old), board, pool) == "[[Retry policy]]"
      # Two pages answer to the title: only the code is sure.
      assert PageLinkHook.link_for(entry.(twin), board, pool) == "[[#{twin.code}]]"
      assert PageLinkHook.link_for(entry.(twin2), board, pool) == "[[#{twin2.code}]]"
      # Link syntax in the title.
      assert PageLinkHook.link_for(entry.(slashed), board, pool) == "[[#{slashed.code}]]"
      assert PageLinkHook.link_for(entry.(piped), board, pool) == "[[#{piped.code}]]"
      assert PageLinkHook.link_for(entry.(coded), board, pool) == "[[#{coded.code}]]"
      # Written on another board, a title would look there.
      assert PageLinkHook.link_for(entry.(old), other, pool) == "[[#{old.code}]]"
    end

    test "resolves to the page it was picked for", %{board: board, old: old, user: user} do
      pool = Wiki.Switcher.pool(user, board)
      link = PageLinkHook.link_for(Enum.find(pool, &(&1.id == old.id)), board, pool)

      assert [%{kind: :page, target: "Retry policy"}] = Wiki.Markup.refs(link)
    end
  end

  describe "the card's attach box" do
    test "offers the most recent pages as soon as it is focused", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card}")
      refute has_element?(view, "button[phx-click='attach_doc']")

      view |> element("#card-doc-search input[name='q']") |> render_focus()

      titles =
        view
        |> element("#card-doc-search + ul")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("button[phx-click='attach_doc'] span.block:first-child")
        |> Enum.map(&Floki.text/1)

      assert ["Release notes", "Billing spec", "Retry policy" | _] = titles
    end

    test "matches a folder or a code, and leaves out what is attached", %{
      conn: conn,
      board: board,
      card: card,
      spec: spec,
      new: new
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card}")
      spec_button = "button[phx-click='attach_doc'][phx-value-page='#{spec.id}']"

      view |> form("#card-doc-search") |> render_change(%{"q" => "design"})
      assert has_element?(view, spec_button)
      assert view |> element(spec_button) |> render() =~ "Design"

      view |> form("#card-doc-search") |> render_change(%{"q" => new.code})

      assert has_element?(
               view,
               "button[phx-click='attach_doc'][phx-value-page='#{new.id}']"
             )

      view
      |> element("button[phx-click='attach_doc'][phx-value-page='#{new.id}']")
      |> render_click()

      view |> element("#card-doc-search input[name='q']") |> render_focus()
      refute has_element?(view, "button[phx-click='attach_doc'][phx-value-page='#{new.id}']")
      assert has_element?(view, spec_button)
    end
  end

  describe "pages in the user's other vaults (#1303)" do
    setup %{user: user} do
      garden = board_fixture(%{"name" => "Garden board", "code" => "plink1303g"}, owner: user)
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "Garden"})
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: garden})
      {:ok, plants} = Folders.create(garden, %{"name" => "Plants"})

      rose =
        page_fixture(garden, %{"title" => "Rose pruning", "folder_id" => plants.id}, user: user)

      stranger = user_fixture("plink1303.stranger@example.com")
      hidden = board_fixture(%{"name" => "Hidden", "code" => "plink1303h"}, owner: stranger)
      {:ok, theirs} = Vaults.create_vault(stranger, %{"name" => "Theirs"})
      {:ok, _} = Vaults.add_mapping(theirs, stranger, %{path: "/", board: hidden})
      secret = page_fixture(hidden, %{"title" => "Rose secret"}, user: stranger)

      %{rose: rose, secret: secret}
    end

    test "the [[ picker offers them, says which vault, and links by code", %{
      conn: conn,
      board: board,
      rose: rose,
      secret: secret
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      pages = suggest(view, %{"q" => "rose", "fresh" => true})

      assert %{insert: insert, path: path} = Enum.find(pages, &(&1.id == rose.id))
      assert insert == "[[#{rose.code}]]"
      assert path =~ "Garden"
      assert path =~ "Garden board"
      refute Enum.any?(pages, &(&1.id == secret.id))

      # Written into a page here, the code finds it.
      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Linked", "body" => "See #{insert}"},
          user: Repo.get!(Slipdock.Accounts.User, board.owner_id)
        )

      assert [%{resolved: true, target_page_id: id}] = Wiki.outgoing_links(page)
      assert id == rose.id
    end

    test "the attach box offers them too", %{
      conn: conn,
      user: user,
      board: board,
      card: card,
      rose: rose
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card}")
      view |> form("#card-doc-search") |> render_change(%{"q" => "rose"})

      button = "button[phx-click='attach_doc'][phx-value-page='#{rose.id}']"
      assert view |> element(button) |> render() =~ "Garden"

      view |> element(button) |> render_click()
      assert card |> Wiki.pages_for_card(user) |> Enum.any?(&(&1.page.id == rose.id))
    end
  end
end
