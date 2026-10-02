defmodule SlipdockWeb.AdminLiveTest do
  @moduledoc """
  The admin area, and above all what it refuses. An admin page that lets you
  brick your own instance is worse than no admin page.
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

  describe "who can get in" do
    test "an admin can", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ "Who can register"
    end

    test "an ordinary user is sent away without being told there is anything here", %{
      conn: conn,
      ordinary: ordinary
    } do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(log_in_user(conn, ordinary), ~p"/admin")
    end
  end

  describe "settings" do
    test "changing the mode says it does not remove anybody", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin")
      assert html =~ "does not remove anybody"

      view
      |> form("#admin-settings-form", %{"settings" => %{"signup_mode" => "open"}})
      |> render_submit()

      assert Settings.signup_mode() == :open
    end

    test "the allowlist editor appears only when it is the mode", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin")
      refute has_element?(view, "#allow-form")

      view
      |> form("#admin-settings-form", %{"settings" => %{"signup_mode" => "allowlist"}})
      |> render_submit()

      assert has_element?(view, "#allow-form")
    end

    test "entries can be added and removed", %{conn: conn, admin: admin} do
      {:ok, _} = Settings.update(%{"signup_mode" => :allowlist})
      {:ok, view, _} = live(conn, ~p"/admin")

      view |> form("#allow-form", %{"allow" => %{"entry" => "example.org"}}) |> render_submit()

      assert [entry] = Settings.list_allowlist()
      assert entry.entry == "example.org"
      assert entry.added_by_id == admin.id

      view |> element("button[phx-value-id='#{entry.id}']") |> render_click()
      assert Settings.list_allowlist() == []
    end

    test "the admin's own address cannot be smuggled in through the settings form", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin")

      # The form has no such field, so this is the crafted-event version: an
      # admin address changed without the new one proving it can receive mail
      # is a silent lock-out waiting to happen.
      render_submit(view, "save-settings", %{
        "settings" => %{"signup_mode" => "closed", "admin_email" => "hijack@example.com"}
      })

      assert Settings.get().admin_email == "admin@example.com"
    end
  end

  describe "mail" do
    test "will not save a change without a test message that worked", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/mail")

      html =
        view
        |> form("#admin-mail-form", %{
          "settings" => %{"smtp_host" => "smtp.example.com", "smtp_from_email" => "m@example.com"}
        })
        |> render_submit(%{"step_action" => "save"})

      assert html =~ "locked out"
      refute Settings.smtp_configured?()
    end

    test "saves once a test has gone out", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/mail")

      params = %{
        "settings" => %{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "m@example.com",
          "test_to" => "admin@example.com"
        }
      }

      view |> form("#admin-mail-form", params) |> render_submit(%{"step_action" => "test"})
      view |> form("#admin-mail-form", params) |> render_submit(%{"step_action" => "save"})

      assert Settings.smtp_configured?()
    end

    test "says where sign-in codes go, and that it is a back door", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/mail")
      assert html =~ "can sign in as anybody"
    end
  end

  describe "people" do
    test "lists who is here, where they came from, and what they use", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/people")

      assert html =~ "ordinary@example.com"
      assert html =~ "signed up"
      assert html =~ "never"
    end

    test "promoting and demoting", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/admin/people")

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
      {:ok, view, _} = live(conn, ~p"/admin/people")

      html =
        view
        |> element("button[phx-click='demote'][phx-value-id='#{admin.id}']")
        |> render_click()

      assert html =~ "only admin"
      assert html =~ "nobody left"
      assert Accounts.admin?(Slipdock.Repo.reload(admin))
    end

    test "the last admin cannot be disabled either", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, ~p"/admin/people")

      html =
        view
        |> element("button[phx-click='disable'][phx-value-id='#{admin.id}']")
        |> render_click()

      assert html =~ "only admin"
      refute Accounts.disabled?(Slipdock.Repo.reload(admin))
    end

    test "disabling and enabling somebody else", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/admin/people")

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
      {:ok, view, html} = live(conn, ~p"/admin/people")

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
      {:ok, view, _} = live(conn, ~p"/admin/people")

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
      {:ok, _view, html} = live(conn, ~p"/admin/signups")

      assert html =~ "hopeful@example.com"
      assert html =~ "Design"
    end

    test "approving makes the account", %{conn: conn, request: request} do
      {:ok, view, _} = live(conn, ~p"/admin/signups")

      view
      |> element("button[phx-click='approve'][phx-value-id='#{request.id}']")
      |> render_click()

      assert Accounts.get_user_by_email("hopeful@example.com")
      assert Accounts.list_signup_requests() == []
    end

    test "turning one down", %{conn: conn, request: request} do
      {:ok, view, _} = live(conn, ~p"/admin/signups")

      view
      |> element("button[phx-click='reject'][phx-value-id='#{request.id}']")
      |> render_click()

      refute Accounts.get_user_by_email("hopeful@example.com")
      assert Accounts.list_signup_requests() == []
    end

    test "the tab is hidden when it is not the mode", %{conn: conn} do
      {:ok, _} = Settings.update(%{"signup_mode" => :closed})
      {:ok, _view, html} = live(conn, ~p"/admin")
      refute html =~ "Requests"
    end
  end
end
