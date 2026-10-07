defmodule SlipdockWeb.MobileMenuLiveTest do
  @moduledoc """
  The phone's header and bottom-bar Menu (#348).

  Below `sm` the header is one row — the mark, the board's name, the finder
  and the palette — and everything the avatar menu, the board's `…` menu and
  its AI chat button hold on a wider screen moves to the Menu at the left of
  the bottom bar, where Boards used to be. Which of the two is shown is CSS,
  so these check that both are rendered and carry the classes that pick
  between them.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup do
    %{board: board_fixture(%{"name" => "Phone menus"})}
  end

  describe "the header on a phone" do
    test "is one row: both rows give way to the header's own", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      # contents below sm, a box of their own from sm, contents again from lg.
      assert has_element?(view, "header > #topbar.contents.sm\\:flex.lg\\:contents")
      assert has_element?(view, "header > #subheader.contents.sm\\:flex.lg\\:contents")
      assert has_element?(view, "header.flex-row.sm\\:flex-col.lg\\:flex-row")
    end

    test "puts the board's name on the top row, ahead of the finder and the palette", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      # On one row the order classes are what put the name between the mark
      # and the app's buttons, so they apply at every width.
      assert has_element?(view, "#subheader > div.order-3", board.name)
      assert has_element?(view, "#topbar > a.order-1[title='Boards']")
      assert has_element?(view, "#topbar > div.order-5 button[phx-value-panel=find]")
      assert has_element?(view, "#topbar > div.order-5 button[phx-value-panel=command]")

      # The empty spacer that splits the tablet's first row is not there to
      # take the name's width.
      assert has_element?(view, "#topbar > div.order-2.hidden.sm\\:flex.lg\\:hidden")
    end

    test "a page with a title of its own keeps it on a phone", %{conn: conn} do
      {:ok, view, _} = live(phone(conn), ~p"/groups")

      assert has_element?(view, "#topbar > div.order-2.flex", "Groups")
      refute has_element?(view, "#topbar > div.order-2.hidden")
    end

    test "hides the avatar, the board's chat and its … menu", %{conn: conn, board: board} do
      Slipdock.AIStub.share()
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      assert has_element?(view, "header #account-menu.hidden.sm\\:block")
      assert has_element?(view, "header #board-chat.hidden.sm\\:inline-flex")
      assert has_element?(view, "#subheader .dropdown.hidden.sm\\:block #board-share")
    end
  end

  describe "the bottom bar's Menu" do
    test "takes Boards' place as the leftmost item, with a menu icon", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      assert has_element?(view, "#mobile-bar > div > #mobile-menu:first-child [aria-label=Menu]")
      assert has_element?(view, "#mobile-menu [role=button] .hero-bars-3")
      refute has_element?(view, "#mobile-bar > div > a[href='/']")
    end

    test "carries the avatar menu, Boards first", %{conn: conn, board: board, user: user} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      assert has_element?(
               view,
               "#mobile-menu .menu-title",
               Slipdock.Accounts.User.display_name(user)
             )

      assert has_element?(view, "#mobile-menu a[href='/']", "Boards")
      assert has_element?(view, "#mobile-menu a[href='/ask']", "Ask")
      assert has_element?(view, "#mobile-menu a[href='/account']", "Account")
      assert has_element?(view, "#mobile-menu a[href='/logout']", "Sign out")
      # The desktop's avatar menu draws the same list.
      assert has_element?(view, "#account-menu a[href='/account']", "Account")
    end

    test "carries the board's own menu above the account's", %{conn: conn, board: board} do
      {:ok, view, html} = live(phone(conn), ~p"/boards/#{board}")

      assert has_element?(view, "#mobile-menu #board-share-menu", "Share this board")
      assert has_element?(view, "#mobile-menu a", "Tags")
      assert has_element?(view, "#mobile-menu a", "Archived cards")
      assert has_element?(view, "#mobile-menu a", "Board settings")

      [menu] = Regex.run(~r/id="mobile-menu".*?<\/ul>/s, html)
      {settings, _} = :binary.match(menu, "Board settings")
      {account, _} = :binary.match(menu, ~s(href="/account"))
      assert settings < account
      # A rule under the board's entries, separating them from the account's.
      assert has_element?(view, "#mobile-menu li.menu-title.border-t")
    end

    test "opens the board's AI chat when AI is set up", %{conn: conn, board: board} do
      Slipdock.AIStub.share()
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      refute has_element?(view, "#page-ai [role=dialog]")
      view |> element("#mobile-menu #board-chat-menu") |> render_click()
      assert has_element?(view, "#page-ai [role=dialog]")
    end

    test "has no chat entry without AI", %{conn: conn, board: board, user: user} do
      # The shared key kept for admins, and no key of one's own: no AI.
      previous = Application.get_env(:slipdock, :ai)

      Application.put_env(
        :slipdock,
        :ai,
        Keyword.put(previous, :shared_key_for_admins_only, true)
      )

      on_exit(fn -> Application.put_env(:slipdock, :ai, previous) end)
      refute Slipdock.AI.configured?(user)

      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      refute has_element?(view, "#board-chat-menu")
      refute has_element?(view, "#board-chat")
    end

    test "offers sharing only to whoever can manage the board", %{conn: conn, user: user} do
      owner = user_fixture("menu-owner@example.com")
      board = board_fixture(%{"name" => "Not mine"}, owner: owner)
      {:ok, _} = Slipdock.Access.grant(board, user, "read", owner)

      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      refute has_element?(view, "#board-share-menu")
      refute has_element?(view, "#mobile-menu a", "Board settings")
      assert has_element?(view, "#mobile-menu a", "Tags")
    end

    test "is only the account's on a page that is not a board", %{conn: conn} do
      {:ok, view, _} = live(phone(conn), ~p"/work")

      assert has_element?(view, "#mobile-menu a[href='/']", "Boards")
      refute has_element?(view, "#mobile-menu a", "Board settings")
      refute has_element?(view, "#mobile-menu li.menu-title.border-t")
    end
  end
end
