defmodule SlipdockWeb.SupportAccessLiveTest do
  @moduledoc """
  Finding what a support session opens. The session grants read access to
  somebody's boards, but no board list shows them, so the Users page and the
  admin's Boards page list them while it lasts.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}
  alias SlipdockWeb.SlipdockComponents

  setup %{conn: conn} do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => fixture_email("support-admin@example.com"),
        "signup_mode" => :closed
      })

    {:ok, admin} = Accounts.promote(user_fixture("support-admin@example.com"))
    customer = user_fixture("support-customer@example.com")
    board = board_fixture(%{"name" => "Customer plans"}, owner: customer)

    %{conn: log_in_user(conn, admin), admin: admin, customer: customer, board: board}
  end

  describe "the Users page" do
    test "Support says where to look, and the row lists their boards as links", %{
      conn: conn,
      admin: admin,
      customer: customer,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/users")

      html =
        view
        |> form("form[phx-submit=support]:has(input[name=user_id][value='#{customer.id}'])", %{
          "reason" => "a lost card"
        })
        |> render_submit()

      assert html =~ "listed under Support access in force, and on your Boards page"

      [session] = Accounts.held_support_sessions(admin)

      assert has_element?(
               view,
               "#support-boards-#{session.id} a[href='/boards/#{board.id}']",
               "Customer plans"
             )
    end

    test "another admin's session is listed without their boards", %{
      conn: conn,
      customer: customer
    } do
      {:ok, other} = Accounts.promote(user_fixture("support-other@example.com"))
      {:ok, session} = Accounts.open_support_session(other, customer, "theirs")

      {:ok, view, _} = live(conn, ~p"/users")

      assert has_element?(view, "#support-#{session.id}", "theirs")
      refute has_element?(view, "#support-boards-#{session.id}")
    end
  end

  describe "the Boards page" do
    test "has nothing about support without a session", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      refute has_element?(view, "section[id^=supporting-]")
    end

    test "lists the boards a session opens, and they open", %{
      conn: conn,
      admin: admin,
      customer: customer,
      board: board
    } do
      {:ok, session} = Accounts.open_support_session(admin, customer, "a lost card")

      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#supporting-#{session.id} h2", "Supporting")
      assert has_element?(view, "#supporting-#{session.id}", "a lost card")
      # Not among your own boards: a section of its own, above them.
      refute has_element?(view, "#boards", "Customer plans")

      {:ok, board_view, _} =
        view
        |> element("#supporting-boards-#{session.id}-#{board.id}")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(board_view, "#subheader", "Customer plans")
      assert has_element?(board_view, "#subheader", "read only")
    end

    test "says so when they have no boards", %{conn: conn, admin: admin} do
      empty = user_fixture("support-empty@example.com")
      {:ok, session} = Accounts.open_support_session(admin, empty, "a question")

      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#supporting-boards-#{session.id}", "no boards of their own")
    end

    test "End now ends it there and then", %{conn: conn, admin: admin, customer: customer} do
      {:ok, session} = Accounts.open_support_session(admin, customer, "a lost card")
      {:ok, view, _} = live(conn, ~p"/")

      view |> element("#supporting-#{session.id} button", "End now") |> render_click()

      refute has_element?(view, "#supporting-#{session.id}")
      refute Accounts.support_access?(admin, customer.id)
    end

    test "End now cannot end another admin's session", %{conn: conn, customer: customer} do
      {:ok, other} = Accounts.promote(user_fixture("support-other2@example.com"))
      {:ok, session} = Accounts.open_support_session(other, customer, "theirs")
      {:ok, view, _} = live(conn, ~p"/")

      render_hook(view, "end_support", %{"id" => to_string(session.id)})

      assert Accounts.support_access?(other, customer.id)
    end
  end

  test "support_time_left/2 reads as hours and minutes" do
    now = ~U[2026-10-18 12:00:00Z]

    assert SlipdockComponents.support_time_left(~U[2026-10-18 16:00:00Z], now) == "4h"
    assert SlipdockComponents.support_time_left(~U[2026-10-18 15:52:30Z], now) == "3h 52m"
    assert SlipdockComponents.support_time_left(~U[2026-10-18 12:07:00Z], now) == "7m"
    assert SlipdockComponents.support_time_left(~U[2026-10-18 11:00:00Z], now) == "0m"
  end
end
