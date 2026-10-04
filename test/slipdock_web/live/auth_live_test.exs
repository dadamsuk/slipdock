defmodule SlipdockWeb.AuthLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Slipdock.Fixtures
  alias Slipdock.{Access, Accounts, Boards}
  alias Slipdock.Swimlanes.Config

  @tag :anonymous
  test "anonymous visitors are sent to the login page and can sign in by magic link", %{
    conn: conn
  } do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    assert conn |> get(~p"/") |> redirected_to() == "/login"

    {:ok, view, _} = live(conn, ~p"/login")

    view
    |> form("#login-form", %{"login" => %{"email" => "visitor@example.com"}})
    |> render_submit()

    assert render(view) =~ "Check your email"

    assert_email_sent(fn email ->
      [token] = Regex.run(~r{/login/([\w-]+)}, email.text_body, capture: :all_but_first)
      # Opening the link only asks; it uses nothing up.
      page = conn |> get(~p"/login/#{token}") |> html_response(200)
      assert page =~ ~s(action="/login/#{token}")
      assert page =~ ~s(method="post")
      refute Accounts.get_user_by_email("visitor@example.com").confirmed_at

      conn = post(conn, ~p"/login/#{token}")
      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_email("visitor@example.com").confirmed_at

      # Signed in now.
      {:ok, _, html} = live(conn, ~p"/")
      assert html =~ "Your boards"

      # Used links no longer work.
      assert conn |> recycle() |> get(~p"/login/#{token}") |> redirected_to() == "/login"
      assert conn |> recycle() |> post(~p"/login/#{token}") |> redirected_to() == "/login"
    end)

    assert conn |> get(~p"/login/bogus") |> redirected_to() == "/login"
  end

  @tag :anonymous
  test "agentic login writes the sign-in link to a file instead of emailing it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/login")
    assert has_element?(view, "#agentic-login", "Agentic Login")

    # The Agentic Login button is the form submitter, adding login[mode]=agentic.
    view
    |> form("#login-form", %{"login" => %{"email" => "agent@example.com"}})
    |> render_submit(%{"login" => %{"mode" => "agentic"}})

    html = render(view)
    assert html =~ "Agentic sign-in link written"

    [path] =
      Regex.run(~r{<code id="agentic-login-file"[^>]*>([^<]+)</code>}, html,
        capture: :all_but_first
      )

    path = String.trim(path)
    assert Path.dirname(path) == Application.fetch_env!(:slipdock, :agentic_login_dir)
    assert Path.basename(path) =~ ~r/^slipdock-agentic-login-[\w-]+\.txt$/
    # A working sign-in link: nobody but the server's own account may read it.
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    refute_email_sent()

    link = path |> File.read!() |> String.trim()
    [token] = Regex.run(~r{/login/([\w-]+)$}, link, capture: :all_but_first)
    assert link == url(~p"/login/#{token}")

    conn = post(conn, ~p"/login/#{token}")
    assert redirected_to(conn) == "/"
    assert get_session(conn, :user_token)
    assert Accounts.get_user_by_email("agent@example.com").confirmed_at

    # One-time: the link is dead once used.
    assert conn |> recycle() |> get(~p"/login/#{token}") |> redirected_to() == "/login"
    File.rm(path)
  end

  test "signing out clears the session", %{conn: conn} do
    conn = delete(conn, ~p"/logout")
    assert redirected_to(conn) == "/login"
    refute get_session(conn, :user_token)
  end

  test "account page: profile", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/account")
    view |> form("#profile-form", %{"user" => %{"name" => "Tess"}}) |> render_submit()
    assert Accounts.get_user!(user.id).name == "Tess"
  end

  test "account page: API tokens", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/account/tokens")

    view |> form("form[id^=token-form]", %{"label" => "laptop"}) |> render_submit()
    html = render(view)
    assert html =~ "Copy this token now"

    [token] =
      Regex.run(~r{<code id="new-token"[^>]*>([^<]+)</code>}, html, capture: :all_but_first)

    assert Accounts.get_user_by_api_token(String.trim(token)).id == user.id
  end

  test "groups page", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/groups")
    view |> form("form[id^=new-group]", %{"name" => "Design"}) |> render_submit()
    [group] = Accounts.list_groups(user)

    view
    |> form("#group-#{group.id} form[phx-submit=add_member]", %{"email" => "pal@example.com"})
    |> render_submit()

    assert has_element?(view, "#group-#{group.id}", "pal@example.com")
    pal = Accounts.get_user_by_email("pal@example.com")

    view
    |> element("#member-#{group.id}-#{pal.id} button[phx-click=remove_member]")
    |> render_click()

    refute has_element?(view, "#member-#{group.id}-#{pal.id}")
  end

  describe "board access" do
    setup %{user: owner} do
      other = user_fixture("other@example.com")
      board = board_fixture(%{"name" => "Owned"}, owner: owner)
      card = card_fixture(hd(board.columns), %{"title" => "Visible card"})
      hidden = card_fixture(hd(board.columns), %{"title" => "Hidden card"})
      %{other: other, board: board, card: card, hidden: hidden, other_conn: conn_as(other)}
    end

    test "strangers are bounced; readers see but can't edit; the owner shares from settings",
         ctx do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(ctx.other_conn, ~p"/boards/#{ctx.board}")

      # Owner shares read access from the settings modal.
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")

      view
      |> form("form[id^=share-board]", %{"email" => "other@example.com", "level" => "read"})
      |> render_submit()

      assert has_element?(view, "[id^=grant-board-]", "other@example.com")
      assert Access.board_permission(ctx.other, ctx.board) == :read

      {:ok, rview, html} = live(ctx.other_conn, ~p"/boards/#{ctx.board}")
      assert html =~ "Visible card" and html =~ "read only"
      refute has_element?(rview, "button", "Add a card")

      assert render_hook(rview, "quick_add_card", %{
               "column_id" => to_string(hd(ctx.board.columns).id),
               "title" => "Nope"
             }) =~ "read-only"

      refute Boards.get_board!(ctx.board.id).columns
             |> Enum.flat_map(& &1.cards)
             |> Enum.any?(&(&1.title == "Nope"))

      # Opening a card read-only: the modal is disabled and writes are refused.
      {:ok, rview, _} = live(ctx.other_conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      assert has_element?(rview, "#card-modal fieldset[disabled]")
      assert render_hook(rview, "add_comment", %{"body" => "hi"}) =~ "read-only"
      assert Boards.get_card!(ctx.card.id).comments == []

      # Upgrading to write lets them edit.
      {:ok, _} = Access.grant(ctx.board, ctx.other, "write", ctx.user)
      {:ok, wview, _} = live(ctx.other_conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      refute has_element?(wview, "#card-modal fieldset[disabled]")
      render_hook(wview, "add_comment", %{"body" => "hi"})
      assert [_] = Boards.get_card!(ctx.card.id).comments

      # But only the owner can rename the board or share it: the settings
      # panel isn't there for anyone else, and the board knows no such event.
      refute has_element?(wview, "#board-settings")

      assert render_hook(wview, "save_board", %{"board" => %{"name" => "Mine now"}}) =~
               "isn&#39;t something this page can do"

      assert Boards.get_board!(ctx.board.id).name == "Owned"
    end

    test "the settings form cannot change who owns the board", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")

      for owner_id <- [to_string(ctx.other.id), ""] do
        view
        |> with_target("#board-settings")
        |> render_hook("save_board", %{
          "board" => %{"name" => "Renamed", "owner_id" => owner_id}
        })

        board = Boards.get_board!(ctx.board.id)
        assert board.name == "Renamed"
        assert board.owner_id == ctx.user.id
      end
    end

    test "a single shared card is reachable without board access", ctx do
      {:ok, _} = Access.grant(ctx.card, ctx.other, "write", ctx.user)
      {:ok, index, html} = live(ctx.other_conn, ~p"/")
      assert html =~ "Cards shared with you" and html =~ "Visible card"
      refute has_element?(index, "#board-#{ctx.board.id}")

      {:ok, view, html} = live(ctx.other_conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      assert html =~ "Visible card"
      refute has_element?(view, "#card-modal fieldset[disabled]")

      # The other card on the board stays out of reach.
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(ctx.other_conn, ~p"/boards/#{ctx.board}/cards/#{ctx.hidden.id}")
    end

    test "a shared view shows only its cards, read-only", ctx do
      {:ok, saved} =
        Boards.create_saved_view(ctx.board, %{
          "name" => "Visible only",
          "config" => Config.to_map(%{Config.defaults("table") | q: "visible"})
        })

      {:ok, _} = Access.grant(saved, ctx.other, "read", ctx.user)

      # Board mode and other URLs get redirected to the granted view in its mode.
      assert {:error, {:live_redirect, %{to: to}}} =
               live(ctx.other_conn, ~p"/boards/#{ctx.board}")

      assert to == "/boards/#{ctx.board.id}/table?view=#{saved.id}"
      {:ok, view, html} = live(ctx.other_conn, to)
      assert html =~ "Visible card" and html =~ "Shared view"
      refute html =~ "Hidden card"
      refute has_element?(view, "#swim-config")

      # Cards outside the view are not reachable; matching ones are, read-only.
      assert {:error, {:live_redirect, %{to: to}}} =
               live(
                 ctx.other_conn,
                 ~p"/boards/#{ctx.board}/table/cards/#{ctx.hidden.id}?view=#{saved.id}"
               )

      assert to == "/boards/#{ctx.board.id}/table?view=#{saved.id}"

      {:ok, view, _} =
        live(ctx.other_conn, ~p"/boards/#{ctx.board}/table/cards/#{ctx.card.id}?view=#{saved.id}")

      assert has_element?(view, "#card-modal fieldset[disabled]")

      # A write view grant allows editing matching cards.
      {:ok, _} = Access.grant(saved, ctx.other, "write", ctx.user)

      {:ok, view, _} =
        live(ctx.other_conn, ~p"/boards/#{ctx.board}/table/cards/#{ctx.card.id}?view=#{saved.id}")

      refute has_element?(view, "#card-modal fieldset[disabled]")
    end

    test "the owner shares a view from the views menu and a card from its modal", ctx do
      {:ok, saved} =
        Boards.create_saved_view(ctx.board, %{
          "name" => "Plan",
          "config" => Config.to_map(%Config{})
        })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?view=#{saved.id}")

      view
      |> form("form[id^=share-view]", %{"email" => "other@example.com", "level" => "read"})
      |> render_submit()

      assert Access.view_permission(ctx.other, saved) == :read

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      view
      |> form("form[id^=share-card]", %{"email" => "other@example.com", "level" => "write"})
      |> render_submit()

      assert Access.card_permission(ctx.other, ctx.card) == :write
      [grant] = Access.list_grants(ctx.card)
      view |> element("#grant-card-#{grant.id} button[phx-click=revoke_grant]") |> render_click()
      assert Access.list_grants(ctx.card) == []
    end
  end
end
