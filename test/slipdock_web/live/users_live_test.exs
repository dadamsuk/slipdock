defmodule SlipdockWeb.UsersLiveTest do
  @moduledoc """
  The Users page: the people on this server, whoever is waiting to be let in,
  and the refusals that keep the last admin from locking everybody out.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  defp set_up(attrs \\ %{}) do
    {:ok, _} =
      Settings.complete_setup(
        Map.merge(%{"admin_email" => "admin@example.com", "signup_mode" => :closed}, attrs)
      )

    :ok
  end

  defp mail, do: %{"smtp_host" => "smtp.example.com", "smtp_from_email" => "mail@example.com"}

  setup %{conn: conn} do
    set_up()
    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    ordinary = user_fixture("ordinary@example.com")
    %{conn: log_in_user(conn, admin), admin: admin, ordinary: ordinary}
  end

  describe "the limits in the people list" do
    test "shows what each person is using, and lets a paid-up date be set", %{
      conn: conn,
      ordinary: ordinary
    } do
      {:ok, view, html} = live(conn, ~p"/users")

      assert html =~ "Paid up to"
      assert html =~ "boards"

      view
      |> form("#paid-until-#{ordinary.id}", %{"paid_until" => "2027-01-31"})
      |> render_submit()

      paid = Accounts.get_user!(ordinary.id).paid_until
      assert DateTime.to_date(paid) == ~D[2027-01-31]
      refute Slipdock.Quota.free?(Accounts.get_user!(ordinary.id))
    end

    test "clearing the date puts somebody back on the free tier", %{
      conn: conn,
      ordinary: ordinary
    } do
      {:ok, _} =
        Accounts.update_standing(ordinary, %{"paid_until" => "2027-01-31"})

      {:ok, view, _} = live(conn, ~p"/users")

      view
      |> form("#paid-until-#{ordinary.id}", %{"paid_until" => ""})
      |> render_submit()

      assert Accounts.get_user!(ordinary.id).paid_until == nil
    end
  end

  describe "unlimited" do
    test "can be switched on and off from the people list", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users")

      html = view |> element("#unlimited-#{ordinary.id}") |> render_click()
      assert html =~ "Remove unlimited"
      assert Accounts.get_user!(ordinary.id).unlimited
      refute Slipdock.Quota.free?(Accounts.get_user!(ordinary.id))

      html = view |> element("#unlimited-#{ordinary.id}") |> render_click()
      assert html =~ "Make unlimited"
      refute Accounts.get_user!(ordinary.id).unlimited
    end

    test "is not offered for an admin, who is exempt already", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, ~p"/users")
      refute has_element?(view, "#unlimited-#{admin.id}")
    end
  end

  describe "an admin demoted while the page is open" do
    test "cannot use it any more", %{conn: conn, admin: admin, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users")
      {:ok, _} = Accounts.promote(user_fixture("other-admin@example.com"))
      {:ok, _} = Accounts.demote(admin)

      assert {:error, {:redirect, %{to: "/"}}} =
               view
               |> element("button[phx-click='promote'][phx-value-id='#{ordinary.id}']")
               |> render_click()

      refute Accounts.admin?(Accounts.get_user!(ordinary.id))
      refute Accounts.admin?(Accounts.get_user!(admin.id))
    end
  end

  describe "who can get in" do
    test "an admin can", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users")
      assert html =~ "People"
    end

    test "an ordinary user is sent away without being told there is anything here", %{
      conn: conn,
      ordinary: ordinary
    } do
      assert {:error, {:redirect, %{to: "/"}}} = live(log_in_user(conn, ordinary), ~p"/users")
    end
  end

  describe "people" do
    test "lists who is here, where they came from, and what they use", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users")

      assert html =~ "ordinary@example.com"
      assert html =~ "signed up"
      assert html =~ "never"
    end

    test "promoting and demoting", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users")

      view
      |> element("button[phx-click='promote'][phx-value-id='#{ordinary.id}']")
      |> render_click()

      assert Accounts.admin?(Slipdock.Repo.reload(ordinary))

      view
      |> element("button[phx-click='demote'][phx-value-id='#{ordinary.id}']")
      |> render_click()

      refute Accounts.admin?(Slipdock.Repo.reload(ordinary))
    end

    test "the last admin cannot be demoted, and is told why", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, ~p"/users")

      html =
        view
        |> element("button[phx-click='demote'][phx-value-id='#{admin.id}']")
        |> render_click()

      assert html =~ "only admin"
      assert html =~ "nobody left"
      assert Accounts.admin?(Slipdock.Repo.reload(admin))
    end

    test "the last admin cannot be disabled either", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, ~p"/users")

      html =
        view
        |> element("button[phx-click='disable'][phx-value-id='#{admin.id}']")
        |> render_click()

      assert html =~ "only admin"
      refute Accounts.disabled?(Slipdock.Repo.reload(admin))
    end

    test "disabling and enabling somebody else", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users")

      view
      |> element("button[phx-click='disable'][phx-value-id='#{ordinary.id}']")
      |> render_click()

      assert Accounts.disabled?(Slipdock.Repo.reload(ordinary))

      view
      |> element("button[phx-click='enable'][phx-value-id='#{ordinary.id}']")
      |> render_click()

      refute Accounts.disabled?(Slipdock.Repo.reload(ordinary))
    end

    test "closing an account says what it will take before it does anything", %{
      conn: conn,
      ordinary: ordinary
    } do
      {:ok, view, html} = live(conn, ~p"/users")

      # Disable is the one to reach for; closing is there because somebody
      # paying for a service may ask to be removed.
      assert html =~ "Disabling is reversible"

      html =
        view
        |> element("button[phx-click='confirm-delete'][phx-value-user_id='#{ordinary.id}']")
        |> render_click()

      assert html =~ "cannot be undone"
      assert html =~ "Type #{ordinary.email} to confirm"
      # Nothing has happened yet.
      assert Slipdock.Repo.reload(ordinary)
    end

    test "and refuses unless the address is typed exactly", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users")

      view
      |> element("button[phx-click='confirm-delete'][phx-value-user_id='#{ordinary.id}']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit='delete']", %{"user_id" => ordinary.id, "email" => "not-it"})
        |> render_submit()

      assert html =~ "Type the address exactly"
      assert Slipdock.Repo.reload(ordinary)

      view
      |> form("form[phx-submit='delete']", %{"user_id" => ordinary.id, "email" => ordinary.email})
      |> render_submit()

      refute Accounts.get_user(ordinary.id)
    end
  end

  describe "signup requests" do
    setup do
      {:ok, _} = Settings.update(Map.put(mail(), "signup_mode", :approval))
      {:ok, request} = Accounts.request_signup("hopeful@example.com", note: "Design")
      %{request: request}
    end

    test "the queue shows what they said", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/signups")

      assert html =~ "hopeful@example.com"
      assert html =~ "Design"
    end

    test "approving makes the account", %{conn: conn, request: request} do
      {:ok, view, _} = live(conn, ~p"/users/signups")

      view
      |> element("button[phx-click='approve'][phx-value-id='#{request.id}']")
      |> render_click()

      assert Accounts.get_user_by_email("hopeful@example.com")
      assert Accounts.list_signup_requests() == []
    end

    test "turning one down", %{conn: conn, request: request} do
      {:ok, view, _} = live(conn, ~p"/users/signups")

      view
      |> element("button[phx-click='reject'][phx-value-id='#{request.id}']")
      |> render_click()

      refute Accounts.get_user_by_email("hopeful@example.com")
      assert Accounts.list_signup_requests() == []
    end

    test "the tab is hidden when it is not the mode", %{conn: conn} do
      {:ok, _} = Settings.update(%{"signup_mode" => :closed})
      {:ok, _view, html} = live(conn, ~p"/users")
      refute html =~ "Requests"
    end
  end

  describe "ids that name nobody" do
    test "a stale or hand-made id is a flash, not a crashed page", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/users")

      for {event, params} <- [
            {"promote", %{"id" => "999999"}},
            {"disable", %{"id" => "not-an-id"}},
            {"set-limit", %{"user_id" => "999999", "limit" => "5"}},
            {"confirm-delete", %{"user_id" => "x"}},
            {"delete", %{"user_id" => "999999", "email" => "a@b.c"}},
            {"support", %{"user_id" => "999999", "reason" => "why"}},
            {"end-support", %{"id" => "999999"}},
            {"approve", %{"id" => "999999"}},
            {"reject", %{"id" => "abc"}}
          ] do
        assert render_click(view, event, params) =~ "isn&#39;t there any more"
      end
    end
  end
end
