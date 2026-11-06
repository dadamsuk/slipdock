defmodule SlipdockWeb.WikiTreeNamesLiveTest do
  @moduledoc """
  "Names in trees and lists" (#1594): set in account settings or the tree's
  header, and used by the tree, card-folder rows and breadcrumbs, falling
  back to the title. The server never cuts a name: CSS does.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.{Accounts, Boards, Repo, Vaults, Wiki}

  @long "Agent supervision 5/9: Parked jobs must be released on timeout, every one"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Handbook", "code" => "treenames1"}, owner: user)
    long = card_fixture(hd(board.columns), %{"title" => @long})
    {:ok, long} = Boards.update_card(long, %{"short_name" => "Parked jobs"})
    plain = card_fixture(hd(board.columns), %{"title" => "Plain card"})
    {:ok, page} = Wiki.create_page_from_card(long, user: user, title: "Write up")
    {:ok, other} = Wiki.create_page_from_card(plain, user: user, title: "Other")
    page = Repo.get!(Wiki.Page, page.id)
    other = Repo.get!(Wiki.Page, other.id)
    cards = Wiki.get_folder(Wiki.get_folder(page.folder_id).parent_id)
    %{board: board, page: page, other: other, cards: cards, folder: page.folder_id}
  end

  defp choose(user, choice) do
    {:ok, user} = Accounts.update_display(user, %{tree_names: choice})
    user
  end

  defp render_hook_children(view, cards) do
    view
    |> tree_load(%{"keys" => ["folder:#{cards.id}"]})
    |> titles("folder:#{cards.id}")
  end

  describe "the setting" do
    test "is full titles until somebody chooses", %{user: user} do
      assert Accounts.get_user!(user.id).tree_names == "full"
    end

    test "is set in account settings and stays set", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account/settings")
      assert has_element?(view, "#tree-names option[selected][value='full']")

      view |> form("#tree-names-form", display: %{tree_names: "short"}) |> render_submit()

      assert Accounts.get_user!(user.id).tree_names == "short"
      {:ok, again, _html} = live(conn, ~p"/account/settings")
      assert has_element?(again, "#tree-names option[selected][value='short']")
    end

    test "refuses anything but the two choices", %{user: user} do
      assert {:error, changeset} = Accounts.update_display(user, %{tree_names: "tiny"})
      assert Keyword.has_key?(changeset.errors, :tree_names)
      assert {:error, _} = Accounts.update_display(user, %{tree_names: nil})
    end
  end

  describe "the tree" do
    test "shows full titles, whole, by default", %{conn: conn, board: board, cards: cards} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      titles = render_hook_children(view, cards)

      assert @long in titles
      assert "Plain card" in titles
    end

    test "short names where there are any, and the title where not",
         %{conn: conn, user: user, board: board, cards: cards} do
      choose(user, "short")
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      titles = render_hook_children(view, cards)

      assert "Parked jobs" in titles
      assert "Plain card" in titles
      refute @long in titles
    end

    test "a short row keeps the full name for its hover",
         %{conn: conn, user: user, board: board, cards: cards} do
      choose(user, "short")
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      reply = tree_load(view, %{"keys" => ["folder:#{cards.id}"]})

      assert %{full: @long} = row(reply, "folder:#{cards.id}", "Parked jobs")
      assert %{full: "Plain card"} = row(reply, "folder:#{cards.id}", "Plain card")
    end

    test "pages keep their titles either way",
         %{conn: conn, user: user, board: board, folder: folder} do
      choose(user, "short")
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      assert "Write up" in (view
                            |> tree_load(%{"keys" => ["folder:#{folder}"]})
                            |> titles("folder:#{folder}"))
    end

    test "a folder that isn't a card's is untouched",
         %{conn: conn, user: user, board: board} do
      {:ok, _} = Wiki.create_folder(board, %{"name" => "Design"})
      choose(user, "short")
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      assert row(tree_load(view), "root", "Design")
    end

    test "the header's button flips it, for good, and redraws",
         %{conn: conn, user: user, board: board, cards: cards} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      assert has_element?(view, "#wiki-tree-names[aria-pressed='false']")
      version = view |> element("#wiki-tree") |> render() |> version()

      view |> element("#wiki-tree-names") |> render_click()

      assert has_element?(view, "#wiki-tree-names[aria-pressed='true']")
      assert Accounts.get_user!(user.id).tree_names == "short"
      assert view |> element("#wiki-tree") |> render() |> version() > version
      assert "Parked jobs" in render_hook_children(view, cards)

      view |> element("#wiki-tree-names") |> render_click()
      assert Accounts.get_user!(user.id).tree_names == "full"
      assert @long in render_hook_children(view, cards)
    end
  end

  defp version(html) do
    [_, n] = Regex.run(~r/data-version="(\d+)"/, html)
    String.to_integer(n)
  end

  describe "card-folder rows" do
    test "the folder page names its children by the choice, whole, title on hover",
         %{conn: conn, user: user, board: board, cards: cards} do
      choose(user, "short")
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{cards.id}")

      assert has_element?(view, "span.truncate[title='#{@long}']", "Parked jobs")
      assert has_element?(view, "span.truncate[title='Plain card']", "Plain card")
    end

    test "full titles are never cut by the server",
         %{conn: conn, board: board, cards: cards} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{cards.id}")

      assert has_element?(view, "span.truncate", @long)
    end

    test "the wiki's index uses it too", %{conn: conn, user: user, board: board} do
      choose(user, "short")
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki")

      # Cards is a top folder, so its children are listed on the index.
      assert html =~ "Parked jobs"
      refute html =~ ">#{@long}<"
    end
  end

  describe "breadcrumbs" do
    test "a page's use the short name, with the title on hover",
         %{conn: conn, user: user, board: board, page: page} do
      choose(user, "short")
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert has_element?(
               view,
               "article nav span.truncate[title='Filed here: #{@long}']",
               "Parked jobs"
             )
    end

    test "fall back to the title", %{conn: conn, user: user, board: board, other: other} do
      choose(user, "short")
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{other.slug}")

      assert has_element?(view, "article nav span.truncate", "Plain card")
    end

    test "a page's say the title when that's the choice",
         %{conn: conn, board: board, page: page} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert has_element?(view, "article nav span.truncate", @long)
    end

    test "a folder's use it", %{conn: conn, user: user, board: board, folder: folder} do
      choose(user, "short")
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{folder}")

      assert has_element?(view, "nav span[title='#{@long}']", "Parked jobs")
    end

    test "the vault's use it, and full titles rather than disk names",
         %{conn: conn, user: user, page: page} do
      vault = Vaults.root(user)
      address = Vaults.addresses(vault).pages[page.id]
      url = SlipdockWeb.VaultUrls.url(vault, address)

      {:ok, view, _html} = live(conn, url)
      assert has_element?(view, "#vault-crumbs a[title='#{@long}']", @long)

      choose(user, "short")
      {:ok, view, _html} = live(conn, url)
      assert has_element?(view, "#vault-crumbs a[title='#{@long}']", "Parked jobs")
    end
  end
end
