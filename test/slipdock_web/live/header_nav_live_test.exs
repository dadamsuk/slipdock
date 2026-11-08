defmodule SlipdockWeb.HeaderNavLiveTest do
  @moduledoc """
  The header from lg up (#1713): Boards, My work and Wiki as links you can
  see, a search field, quick add with Quick note inside it, the Favourites
  heart, alerts with what waits on you folded into the badge, and a tooltip
  naming every icon button and its key.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards}

  @places [boards: "/", work: "/work", wiki: "/wiki"]

  describe "the primary navigation" do
    test "shows Boards, My work and Wiki from lg up, in that order", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/groups")

      assert has_element?(view, "#topbar nav#primary-nav.hidden.lg\\:flex")
      html = view |> element("#primary-nav") |> render()

      assert [{"/", "Boards"}, {"/work", "My work"}, {"/wiki", "Wiki"}] ==
               Regex.scan(~r/href="([^"]+)"[^>]*>\s*([^<]+?)\s*</, html, capture: :all_but_first)
               |> Enum.map(&List.to_tuple/1)
    end

    for {place, path} <- @places do
      test "marks #{place} as the current page on #{path}, and nothing else", %{conn: conn} do
        {:ok, view, _} = live(conn, unquote(path))

        assert has_element?(view, "#primary-nav-#{unquote(place)}[aria-current='page']")

        for {other, _} <- @places, other != unquote(place) do
          refute has_element?(view, "#primary-nav-#{other}[aria-current]")
        end
      end
    end

    test "marks nothing on a page that is none of the three", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/groups")

      refute has_element?(view, "#primary-nav [aria-current]")
    end

    test "marks Boards on a board, which is a place under it", %{conn: conn} do
      board = board_fixture(%{"name" => "Nav board"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(view, "#primary-nav-boards[aria-current='page']")
      refute has_element?(view, "#primary-nav-work[aria-current]")
      refute has_element?(view, "#primary-nav-wiki[aria-current]")
    end

    test "is not drawn for somebody signed out" do
      html = build_conn() |> get(~p"/login") |> html_response(200)

      refute html =~ ~s(id="primary-nav")
      refute html =~ ~s(id="search-field")
    end
  end

  describe "every icon button names itself and its key" do
    @tips %{
      "quick-add-open" => "Quick add a card (q)",
      "quick-note-open" => "Quick note (Shift-Alt-N)",
      "finder-open" => "Find a card (Ctrl-O)",
      "commands-open" => "Commands (Ctrl-P)",
      "search-link" => "Search everything (Shift-Alt-S)",
      "search-field" => "Search everything (Shift-Alt-S)",
      "ask-link" => "Ask about everything (Shift-Alt-A)",
      "favourites-link" => "Favourites (Shift-Alt-F)"
    }

    for {name, path} <- [
          home: "/",
          board: :board,
          work: "/work",
          wiki: "/wiki",
          search: "/search"
        ] do
      test "on #{name}", %{conn: conn} do
        path =
          case unquote(path) do
            :board -> ~p"/boards/#{board_fixture(%{"name" => "Tips"})}"
            path -> path
          end

        {:ok, view, _} = live(conn, path)

        for {id, tip} <- @tips do
          assert has_element?(view, "##{id}[title='#{tip}'][aria-label='#{tip}']"),
                 "##{id} should say #{inspect(tip)} on #{path}"
        end

        assert has_element?(
                 view,
                 "#alerts-bar button[title='No alerts (l)'][aria-label='No alerts (l)']"
               )

        assert has_element?(
                 view,
                 "#topbar > a.order-1[title='All boards (h)'][aria-label='All boards (h)']"
               )

        assert has_element?(view, "#account-menu [role=button][aria-label$=': account menu']")
      end
    end

    test "no icon-only button in the app's part of the header is left unnamed", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      html = view |> element("#topbar > div.order-5") |> render()

      squares = Regex.scan(~r/<(?:button|a)\b[^>]*btn-square[^>]*>/, html) |> List.flatten()
      assert length(squares) >= 7

      for tag <- squares do
        assert tag =~ ~r/aria-label="[^"]+\([^)]+\)"/, "unnamed or keyless: #{tag}"
        assert tag =~ ~r/title="[^"]+\([^)]+\)"/, "no tooltip: #{tag}"
      end
    end

    test "header_tip/2 leaves the key off when there is none" do
      assert SlipdockWeb.Layouts.header_tip("Boards", nil) == "Boards"
      assert SlipdockWeb.Layouts.header_tip("Alerts", "l") == "Alerts (l)"
    end
  end

  describe "the search field" do
    test "is a magnifying glass that opens Search everything, from lg up", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(
               view,
               "a#search-field.hidden.lg\\:flex[href='/search']",
               "Search or ask"
             )

      assert has_element?(view, "#search-field .hero-magnifying-glass")
      # The tablet's icon is a magnifying glass too, not the circled one.
      assert has_element?(view, "#search-link.lg\\:hidden .hero-magnifying-glass")
      refute has_element?(view, "#topbar .hero-magnifying-glass-circle")
    end

    test "is marked on Search and on Ask, its other half", %{conn: conn} do
      for path <- ["/search", "/ask"] do
        {:ok, view, _} = live(conn, path)
        assert has_element?(view, "#search-field[aria-current='page']")
      end

      {:ok, view, _} = live(conn, ~p"/")
      refute has_element?(view, "#search-field[aria-current]")
    end

    test "comes before quick add, which comes before the heart", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      html = view |> element("#topbar > div.order-5") |> render()

      order =
        Enum.map(
          ~w(search-field quick-add-open favourites-link alerts-bar account-menu),
          &(:binary.match(html, ~s(id="#{&1}")) |> elem(0))
        )

      assert order == Enum.sort(order)
    end
  end

  describe "nothing is lost: two clicks or fewer" do
    test "Quick note is inside quick add's panel, and opens from there", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      # The header's own pencil gives way from lg up.
      assert has_element?(view, "#quick-note-open.lg\\:hidden")
      refute has_element?(view, "#quick-add-note")

      view |> element("#quick-add-open") |> render_click()
      assert has_element?(view, "#quick-add-panel #quick-add-note", "Quick note")

      view |> element("#quick-add-note") |> render_click()
      refute has_element?(view, "#quick-add-panel")
      assert has_element?(view, "#quick-note-panel")
    end

    test "Ask is the search page's other half, one click on", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/search")

      assert has_element?(view, "a[href='/ask']")
      assert has_element?(view, "#ask-link.lg\\:hidden[href='/ask']")
    end

    test "Favourites keeps its heart on the bar at every width from a tablet up", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#favourites-link.sm\\:inline-flex[href='/favourites']")
      refute has_element?(view, "#favourites-link.lg\\:hidden")
    end

    test "alerts open from the bell in one click", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      view |> element("#alerts-bar button[aria-controls='alerts-panel']") |> render_click()
      assert has_element?(view, "#alerts-panel", "Nothing needs your attention")
      refute has_element?(view, "#alerts-waiting")
    end
  end

  describe "what waits on you, folded into the bell" do
    setup %{user: user} do
      # The wait's own alert (#2095) is off here: these count what waits.
      {:ok, user} = Slipdock.Accounts.update_waiting_notice(user, %{waiting_alerts: false})
      asker = user_fixture("nav-asker@example.com")
      board = board_fixture(%{"name" => "Waits"}, owner: asker)
      {:ok, _} = Slipdock.Access.grant(board, user, "write", asker)
      [_backlog, todo | _] = board.columns
      card = card_fixture(todo, %{"title" => "Region"})
      actor = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: asker.id}

      {:ok, _} =
        Boards.open_wait(card, actor, %{"needs" => "Which region?", "on_user_id" => user.id})

      %{asker: asker, board: board}
    end

    test "the badge counts it from lg up, and the panel leads with it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#alerts-total.hidden.lg\\:inline-block", "1")
      assert has_element?(view, "#alerts-bar button[title='No alerts, 1 waiting on you (l)']")
      # The tablet keeps its own hand, which gives way from lg up.
      assert has_element?(view, "#waiting-link.lg\\:hidden #waiting-count", "1")

      view |> element("#alerts-bar button[aria-controls='alerts-panel']") |> render_click()

      assert has_element?(
               view,
               "#alerts-panel a#alerts-waiting[href='/work']",
               "1 waiting on you"
             )

      refute has_element?(view, "#alerts-panel", "Nothing needs your attention")
    end

    test "with alerts as well, the lg badge is the sum and the tablet's is the alerts", %{
      conn: conn,
      board: board
    } do
      {:ok, _} =
        Automations.raise_alert(%{
          "board_id" => board.id,
          "title" => "Look at this",
          "severity" => "urgent"
        })

      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#alerts-count.lg\\:hidden", "1")
      assert has_element?(view, "#alerts-total.bg-error", "2")
      assert has_element?(view, "#alerts-bar button[title='1 alert, 1 waiting on you (l)']")
    end

    test "with the wait's own alert on, the bell has it as an alert too", ctx do
      user = Slipdock.Repo.reload!(ctx.user)
      {:ok, _} = Slipdock.Accounts.update_waiting_notice(user, %{waiting_alerts: true})
      [_backlog, todo | _] = Boards.get_board!(ctx.board.id).columns
      card = card_fixture(todo, %{"title" => "And this"})
      actor = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.asker.id}

      {:ok, _} =
        Boards.open_wait(card, actor, %{"needs" => "And this?", "on_user_id" => ctx.user.id})

      {:ok, view, _} = live(ctx.conn, ~p"/")
      assert has_element?(view, "#alerts-bar button[title='1 alert, 2 waiting on you (l)']")
    end
  end

  describe "the place keys" do
    test "Shift-Alt-F goes to Favourites and Shift-Alt-A to Ask", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: "/favourites"}}} =
               render_hook(view, "go_place", %{"place" => "favourites"})

      {:ok, view, _} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: "/ask"}}} =
               render_hook(view, "go_place", %{"place" => "ask"})
    end

    test "anything else is ignored, not followed", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      assert render_hook(view, "go_place", %{"place" => "admin/../users"}) =~ "primary-nav"
      assert render_hook(view, "go_place", %{}) =~ "primary-nav"
    end

    test "are in the shortcut list" do
      keys = SlipdockWeb.Shortcuts.all() |> Enum.map(&elem(&1, 0))

      assert "Shift-Alt-F" in keys
      assert "Shift-Alt-A" in keys
    end
  end
end
