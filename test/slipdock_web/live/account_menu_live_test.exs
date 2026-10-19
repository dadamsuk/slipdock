defmodule SlipdockWeb.AccountMenuLiveTest do
  @moduledoc """
  The header's right-hand end and the avatar menu, after the tidy-up: the
  app's buttons in one fixed order, ruled off from a page's own; the menu in
  sections (where you go, Set up, You, Admin) with the page you are on
  marked; the account's pages one entry rather than five; and a board's `…`
  menu in groups.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Automations, Settings}

  defp position(html, needle) do
    case :binary.match(html, needle) do
      {at, _} -> at
      :nomatch -> flunk("#{inspect(needle)} is not in the markup")
    end
  end

  defp menu(view, id), do: view |> element(id) |> render()

  describe "the header's buttons" do
    test "come in one order: add, search, ask, favourites, alerts, you", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      html = view |> element("#topbar > div.order-5") |> render()

      order =
        Enum.map(
          ~w(quick-add-open search-link ask-link favourites-link alerts-bar account-menu),
          &position(html, ~s(id="#{&1}"))
        )

      assert order == Enum.sort(order)
    end

    test "a page's own buttons come first, ruled off from the app's", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/work")
      html = view |> element("#topbar > div.order-5") |> render()

      assert has_element?(view, "#topbar > div.order-5 > div.sm\\:border-r:first-child")
      assert position(html, "sm:border-r") < position(html, ~s(id="quick-add-open"))
    end

    test "a page with none has no rule", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/groups")

      refute has_element?(view, "#topbar > div.order-5 > div.sm\\:border-r")
    end

    test "a board page's own buttons are ruled off from the app's on one row", %{conn: conn} do
      board = board_fixture(%{"name" => "Ruled off"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

      assert has_element?(view, "#subheader > div.order-4.lg\\:border-r", "New page")
    end

    test "the bell carries no count until there is something to read", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#alerts-bar button[title='No alerts']")
      refute has_element?(view, "#alerts-count")

      board = board_fixture(%{"name" => "Alerting"}, owner: user)

      {:ok, _} =
        Automations.raise_alert(%{
          "board_id" => board.id,
          "title" => "Look at this",
          "severity" => "warning"
        })

      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#alerts-count.bg-warning", "1")
    end
  end

  describe "the avatar menu" do
    test "reads as sections: places, Set up, You, then Sign out", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      html = menu(view, "#account-menu")

      order =
        Enum.map(
          [
            ~s(href="/"),
            ~s(href="/work"),
            ~s(href="/wiki"),
            ~s(href="/vaults"),
            ">Set up<",
            ~s(href="/templates"),
            ~s(href="/groups"),
            ~s(href="/tools"),
            ~s(href="/account/agent"),
            ">You<",
            ~s(href="/account"),
            ~s(href="/help"),
            ~s(id="theme-row"),
            ~s(href="/logout")
          ],
          &position(html, &1)
        )

      assert order == Enum.sort(order)
    end

    test "has the account's pages as one entry: the Account page has a tab for each", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#account-menu a[href='/account']", "Account & settings")

      for path <- ~w(/account/settings /account/tokens /account/data) do
        refute has_element?(view, "#account-menu a[href='#{path}']")
        refute has_element?(view, "#mobile-menu a[href='#{path}']")
      end
    end

    test "leaves out what the header has as buttons on a desktop", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      for path <- ~w(/search /ask /favourites) do
        refute has_element?(view, "#account-menu a[href='#{path}']")
      end
    end

    test "on a phone carries Search and Ask, but not Favourites, which has its own tab",
         %{conn: conn} do
      {:ok, view, _} = live(phone(conn), ~p"/")

      assert has_element?(view, "#mobile-menu a[href='/search']", "Search everything")
      assert has_element?(view, "#mobile-menu a[href='/ask']", "Ask")
      refute has_element?(view, "#mobile-menu a[href='/favourites']")
      assert has_element?(view, "#mobile-dock a[href='/favourites']", "Favourites")
    end

    test "chooses the theme on one row of three", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      for theme <- ~w(system light dark) do
        assert has_element?(view, "#theme-row button[data-phx-theme=#{theme}]")
        assert has_element?(view, "#theme-row-menu button[data-phx-theme=#{theme}]")
      end
    end

    test "marks the page you are on, and only that one", %{conn: conn} do
      for {path, href} <- [
            {~p"/work", "/work"},
            {~p"/tools", "/tools"},
            {~p"/account/agent", "/account/agent"},
            {~p"/account/settings", "/account"}
          ] do
        {:ok, view, _} = live(conn, path)

        assert has_element?(view, "#account-menu a[href='#{href}'][aria-current=page]"),
               "#{path} should mark #{href}"

        assert view
               |> menu("#account-menu")
               |> then(&Regex.scan(~r/aria-current="page"/, &1))
               |> length() == 1
      end
    end

    test "has no Admin group for somebody who is not one", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      refute has_element?(view, "#admin-menu")
      refute has_element?(view, "#account-menu a[href='/config']")
    end
  end

  describe "the avatar menu for an admin" do
    setup %{conn: conn} do
      {:ok, _} =
        Settings.complete_setup(%{
          "admin_email" => fixture_email("menu-admin@example.com"),
          "signup_mode" => :closed
        })

      {:ok, admin} = Accounts.promote(user_fixture("menu-admin@example.com"))
      %{conn: log_in_user(conn, admin)}
    end

    test "folds the server's pages into one Admin group, closed away from them", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#account-menu details#admin-menu summary", "Admin")
      refute has_element?(view, "#admin-menu[open]")

      for path <- ~w(/overview /users /admin/tools /config) do
        assert has_element?(view, "#admin-menu a[href='#{path}']")
      end

      # After You, before Sign out.
      html = menu(view, "#account-menu")
      assert position(html, ">You<") < position(html, ~s(id="admin-menu"))
      assert position(html, ~s(id="admin-menu")) < position(html, ~s(href="/logout"))
    end

    test "opens the group on one of its own pages, marking it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")

      assert has_element?(view, "#admin-menu[open] a[href='/config'][aria-current=page]")
    end

    test "counts who is waiting on the folded group's own line", %{conn: conn} do
      {:ok, _} =
        Settings.update(%{
          "signup_mode" => :approval,
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => fixture_email("mail@example.com")
        })

      {:ok, _} = Accounts.request_signup(fixture_email("waiting@example.com"), note: "Hi")

      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#admin-menu summary .badge-warning", "1")
      assert has_element?(view, "#admin-menu a[href='/users'] .badge-warning", "1")
    end
  end

  describe "a board's … menu" do
    setup do
      %{board: board_fixture(%{"name" => "Menu groups"})}
    end

    test "groups what you do, how it is set up, and what it has done", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      html = view |> element("#board-actions .dropdown ul") |> render()

      order =
        Enum.map(
          [
            "Share this board",
            "Tidy up",
            "Tags",
            "Automations",
            "Board settings",
            "Activity",
            "Archived cards"
          ],
          &position(html, &1)
        )

      assert order == Enum.sort(order)
      # A rule above Tags and above Activity: three groups.
      assert view |> element("#board-actions .dropdown li.border-t", "Tags") |> has_element?()
      assert view |> element("#board-actions .dropdown li.border-t", "Activity") |> has_element?()
      assert length(Regex.scan(~r/class="mt-1 border-t/, html)) == 2
    end

    test "is headed This board in the phone's Menu", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")
      html = menu(view, "#mobile-menu")

      assert position(html, "This board") < position(html, "Share this board")
    end
  end
end
