defmodule SlipdockWeb.PageCodeSearchTest do
  @moduledoc """
  A wiki page's code (`W-31`) finds it (#423): in the card finder (`Ctrl-O`)
  and in a board's search box, as well as through
  `Slipdock.Wiki.page_by_code_for/2` underneath both.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Filters, Wiki}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Handbook"}, owner: user, derive_keys: true)
    page = page_fixture(board, %{"title" => "Retry policy"}, user: user)
    %{board: board, page: page}
  end

  describe "Wiki.page_by_code_for/2" do
    test "finds the page whatever the case and spacing", %{user: user, page: page} do
      assert %{id: id, board: %{name: "Handbook"}} = Wiki.page_by_code_for(user, page.code)
      assert id == page.id
      assert Wiki.page_by_code_for(user, "  " <> String.downcase(page.code) <> " ").id == page.id
    end

    test "anything that is not a code finds nothing", %{user: user, page: page} do
      assert Wiki.page_by_code_for(user, "Retry policy") == nil
      assert Wiki.page_by_code_for(user, "#{page.id}") == nil
      assert Wiki.page_by_code_for(user, "W-") == nil
      assert Wiki.page_by_code_for(user, "") == nil
      assert Wiki.page_by_code_for(user, nil) == nil
    end

    test "a code no page has finds nothing", %{user: user} do
      assert Wiki.page_by_code_for(user, "W-999999999") == nil
    end

    test "an archived page is not offered", %{user: user, page: page} do
      {:ok, _} = Wiki.archive_page(page)
      assert Wiki.page_by_code_for(user, page.code) == nil
    end

    test "a page on a board you cannot open is not offered", %{page: page} do
      stranger = user_fixture("stranger@example.com")
      assert Wiki.page_by_code_for(stranger, page.code) == nil
      assert Wiki.page_by_code_for(nil, page.code) == nil
    end

    test "a draft is offered to a writer but not to a reader", %{user: user, board: board} do
      draft = page_fixture(board, %{"title" => "Half written", "status" => "draft"}, user: user)
      reader = user_fixture("reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      assert Wiki.page_by_code_for(user, draft.code).id == draft.id
      assert Wiki.page_by_code_for(reader, draft.code) == nil
    end
  end

  describe "Filters.matches?/2" do
    test "a page matches its own code, typed whole, and no other", %{page: page} do
      filters = &Map.put(Filters.empty(), :q, &1)

      assert Filters.matches?(page, filters.(page.code))
      assert Filters.matches?(page, filters.(String.downcase(page.code) <> " "))
      refute Filters.matches?(page, filters.("W-999999999"))
      # A card has no code to match.
      refute Filters.matches?(%{title: "x", tags: [], flags: []}, filters.(page.code))
    end
  end

  describe "the card finder (Ctrl-O)" do
    setup %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      render_hook(view, "shortcut_panel", %{"panel" => "find"})
      %{view: view}
    end

    test "says it takes a page's code", %{view: view} do
      assert has_element?(view, ~s{#palette-q-find[placeholder*="code (W-31)"]})
      assert render(view) =~ "a page&#39;s code to open it"
    end

    test "a page's code offers that page first, linking to it", %{
      view: view,
      board: board,
      page: page
    } do
      # A card whose title holds the code is still found, after the page.
      card = card_fixture(hd(board.columns), %{"title" => "Follow up #{page.code}"})

      render_hook(view, "palette_filter", %{"q" => String.downcase(page.code)})

      page_link = ~s{a[href="/boards/#{board.id}/wiki/#{page.slug}"]}
      assert has_element?(view, "#palette-rows " <> page_link, "Retry policy")
      assert has_element?(view, "#palette-rows " <> page_link, page.code)
      # First, and so the row Enter follows.
      assert has_element?(view, "#palette-rows li:first-child " <> page_link <> "[data-on]")
      assert has_element?(view, ~s{#palette-rows a[href="/boards/#{board.id}/cards/#{card.id}"]})
    end

    test "a page you cannot read is not offered", %{view: view} do
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger, derive_keys: true)
      secret = page_fixture(theirs, %{"title" => "Secret plan"}, user: stranger)

      assert render_hook(view, "palette_filter", %{"q" => secret.code}) =~ "No cards match."
      refute render(view) =~ "Secret plan"
    end

    test "words still find cards, not pages", %{view: view, board: board, page: page} do
      card_fixture(hd(board.columns), %{"title" => "Retry the upload"})
      render_hook(view, "palette_filter", %{"q" => "retry"})

      assert has_element?(view, "#palette-rows a", "Retry the upload")
      refute has_element?(view, ~s{#palette-rows a[href$="/wiki/#{page.slug}"]})
    end
  end

  describe "a board's search box" do
    test "a page's code offers that page, though it is not on the board", %{
      conn: conn,
      board: board,
      page: page
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      refute has_element?(view, "#search-page-hit")

      view |> form("#board-search", %{"q" => page.code}) |> render_change()

      assert has_element?(
               view,
               ~s{#search-page-hit[href="/boards/#{board.id}/wiki/#{page.slug}"]},
               "Retry policy"
             )

      # Same board: no need to say which.
      refute has_element?(view, "#search-page-hit", "Handbook")

      render_click(view, "clear_filters")
      refute has_element?(view, "#search-page-hit")
    end

    test "a page on another board you can open says which board", %{
      conn: conn,
      board: board,
      user: user
    } do
      other = board_fixture(%{"name" => "Runbooks"}, owner: user, derive_keys: true)
      far = page_fixture(other, %{"title" => "Deploy"}, user: user)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      view |> form("#board-search", %{"q" => far.code}) |> render_change()

      assert has_element?(view, ~s{#search-page-hit[href="/boards/#{other.id}/wiki/#{far.slug}"]})
      assert has_element?(view, "#search-page-hit", "Runbooks")
    end

    test "words, and pages you cannot read, offer no page", %{conn: conn, board: board} do
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger, derive_keys: true)
      secret = page_fixture(theirs, %{"title" => "Secret plan"}, user: stranger)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      view |> form("#board-search", %{"q" => "Retry policy"}) |> render_change()
      refute has_element?(view, "#search-page-hit")

      view |> form("#board-search", %{"q" => secret.code}) |> render_change()
      refute has_element?(view, "#search-page-hit")
      refute render(view) =~ "Secret plan"
    end
  end
end
