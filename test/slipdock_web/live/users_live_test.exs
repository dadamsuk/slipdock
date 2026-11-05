defmodule SlipdockWeb.UsersLiveTest do
  @moduledoc """
  The Users page: the people on this server, whoever is waiting to be let in,
  and the refusals that keep the last admin from locking everybody out.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  defp set_up(attrs \\ %{}) do
    {:ok, _} =
      Settings.complete_setup(
        Map.merge(
          %{"admin_email" => fixture_email("admin@example.com"), "signup_mode" => :closed},
          attrs
        )
      )

    :ok
  end

  defp mail,
    do: %{
      "smtp_host" => "smtp.example.com",
      "smtp_from_email" => fixture_email("mail@example.com")
    }

  setup %{conn: conn} do
    set_up()
    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    ordinary = user_fixture("ordinary@example.com")
    %{conn: log_in_user(conn, admin), admin: admin, ordinary: ordinary}
  end

  describe "the limits, in the person panel" do
    test "shows what each person is using, and lets a paid-up date be set", %{
      conn: conn,
      ordinary: ordinary
    } do
      {:ok, view, html} = live(conn, ~p"/users?user=#{ordinary.id}")

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

      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")

      view
      |> form("#paid-until-#{ordinary.id}", %{"paid_until" => ""})
      |> render_submit()

      assert Accounts.get_user!(ordinary.id).paid_until == nil
    end
  end

  describe "unlimited" do
    test "can be switched on and off from the person panel", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")

      refute has_element?(view, "#unlimited-#{ordinary.id}[checked]")
      view |> element("#unlimited-#{ordinary.id}") |> render_click()
      assert has_element?(view, "#unlimited-#{ordinary.id}[checked]")
      assert Accounts.get_user!(ordinary.id).unlimited
      refute Slipdock.Quota.free?(Accounts.get_user!(ordinary.id))

      view |> element("#unlimited-#{ordinary.id}") |> render_click()
      refute has_element?(view, "#unlimited-#{ordinary.id}[checked]")
      refute Accounts.get_user!(ordinary.id).unlimited
    end

    test "is not offered for an admin, who is exempt already", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{admin.id}")
      refute has_element?(view, "#unlimited-#{admin.id}")
    end
  end

  # #1206: meetings, transcription and voiceprints, per person.
  describe "meetings" do
    test "can be allowed and taken away from the person panel", %{
      conn: conn,
      ordinary: ordinary
    } do
      no_meetings(ordinary)
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")

      refute has_element?(view, "#meetings-#{ordinary.id}[checked]")
      view |> element("#meetings-#{ordinary.id}") |> render_click()
      assert has_element?(view, "#meetings-#{ordinary.id}[checked]")
      assert Slipdock.Meetings.allowed?(Accounts.get_user!(ordinary.id))

      view |> element("#meetings-#{ordinary.id}") |> render_click()
      refute has_element?(view, "#meetings-#{ordinary.id}[checked]")
      refute Slipdock.Meetings.allowed?(Accounts.get_user!(ordinary.id))
    end

    test "is not offered for an admin, who always has them", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{admin.id}")
      refute has_element?(view, "#meetings-#{admin.id}")
      assert Slipdock.Meetings.allowed?(no_meetings(admin))
    end
  end

  # #1207: permissions are checkboxes, the rest are buttons, and no second
  # title. Since #1739 they are in the person panel, not on the row.
  describe "the panel's controls" do
    test "permissions are checkboxes showing each person's standing", %{
      conn: conn,
      admin: admin,
      ordinary: ordinary
    } do
      {:ok, view, html} = live(conn, ~p"/users?user=#{ordinary.id}")

      refute html =~ ~r/<h2[^>]*>\s*People/
      assert has_element?(view, "input[type=checkbox]#admin-#{ordinary.id}")
      refute has_element?(view, "#admin-#{ordinary.id}[checked]")
      assert has_element?(view, "input[type=checkbox]#unlimited-#{ordinary.id}")
      assert has_element?(view, "input[type=checkbox]#meetings-#{ordinary.id}")
      refute html =~ "Make admin"
      refute html =~ "Make unlimited"
      refute html =~ "Allow meetings"

      {:ok, view, _} = live(conn, ~p"/users?user=#{admin.id}")
      assert has_element?(view, "input[type=checkbox][checked]#admin-#{admin.id}")
    end

    test "an admin's unlimited and meetings boxes are ticked and cannot be changed", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _} = live(conn, ~p"/users?user=#{admin.id}")

      assert view
             |> element("#panel-permissions")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("input[type=checkbox][disabled][checked]")
             |> Enum.count() == 2
    end

    test "ticking Admin promotes, and the box shows it", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")
      view |> element("#admin-#{ordinary.id}") |> render_click()
      assert has_element?(view, "#admin-#{ordinary.id}[checked][phx-click=demote]")
      assert Accounts.admin?(Accounts.get_user!(ordinary.id))
      refute has_element?(view, "#unlimited-#{ordinary.id}")
    end

    test "disable, enable, close and support are buttons", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")

      assert has_element?(
               view,
               "#danger-zone button.btn-ghost.btn-error[data-confirm][phx-click=disable][phx-value-id='#{ordinary.id}']"
             )

      assert has_element?(
               view,
               "#danger-zone button.btn-ghost.btn-error[data-confirm][phx-click=confirm-delete][phx-value-user_id='#{ordinary.id}']"
             )

      assert has_element?(
               view,
               "form[phx-submit=support] button.btn:not(.btn-outline)",
               "Support"
             )

      view
      |> element("button[phx-click=disable][phx-value-id='#{ordinary.id}']")
      |> render_click()

      assert has_element?(
               view,
               "#danger-zone button.btn:not(.btn-outline)[phx-click=enable][phx-value-id='#{ordinary.id}']"
             )
    end
  end

  describe "an admin demoted while the page is open" do
    test "cannot use it any more", %{conn: conn, admin: admin, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")
      {:ok, _} = Accounts.promote(user_fixture("other-admin@example.com"))
      {:ok, _} = Accounts.demote(admin)

      assert {:error, {:redirect, %{to: "/"}}} =
               view
               |> element("input[phx-click='promote'][phx-value-id='#{ordinary.id}']")
               |> render_click()

      refute Accounts.admin?(Accounts.get_user!(ordinary.id))
      refute Accounts.admin?(Accounts.get_user!(admin.id))
    end
  end

  describe "who can get in" do
    test "an admin can", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users")
      assert html =~ "Last seen"
    end

    test "an ordinary user is sent away without being told there is anything here", %{
      conn: conn,
      ordinary: ordinary
    } do
      assert {:error, {:redirect, %{to: "/"}}} = live(log_in_user(conn, ordinary), ~p"/users")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(log_in_user(conn, ordinary), ~p"/users?user=#{ordinary.id}")
    end
  end

  describe "people" do
    test "lists who is here, where they came from, and what they use", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users")

      assert html =~ fixture_email("ordinary@example.com")
      assert html =~ "signed up"
      assert html =~ "never"
    end

    test "promoting and demoting", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")

      view
      |> element("input[phx-click='promote'][phx-value-id='#{ordinary.id}']")
      |> render_click()

      assert Accounts.admin?(Slipdock.Repo.reload(ordinary))

      view
      |> element("input[phx-click='demote'][phx-value-id='#{ordinary.id}']")
      |> render_click()

      refute Accounts.admin?(Slipdock.Repo.reload(ordinary))
    end

    test "the last admin cannot be demoted, and is told why", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{admin.id}")

      html =
        view
        |> element("input[phx-click='demote'][phx-value-id='#{admin.id}']")
        |> render_click()

      assert html =~ "only admin"
      assert html =~ "nobody left"
      assert Accounts.admin?(Slipdock.Repo.reload(admin))
      # The box still says admin, and the panel is still open on them.
      assert has_element?(view, "#person-panel #admin-#{admin.id}[checked]")
    end

    test "the last admin cannot be disabled either, being yourself", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{admin.id}")

      refute has_element?(view, "button[phx-click='disable']")
      html = render_click(view, "disable", %{"id" => to_string(admin.id)})

      assert html =~ "You can&#39;t disable your own account."
      refute Accounts.disabled?(Slipdock.Repo.reload(admin))
    end

    test "disabling and enabling somebody else", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")

      view
      |> element("button[phx-click='disable'][phx-value-id='#{ordinary.id}']")
      |> render_click()

      assert Accounts.disabled?(Slipdock.Repo.reload(ordinary))
      assert has_element?(view, "#person-#{ordinary.id} .badge", "disabled")

      view
      |> element("button[phx-click='enable'][phx-value-id='#{ordinary.id}']")
      |> render_click()

      refute Accounts.disabled?(Slipdock.Repo.reload(ordinary))
      refute has_element?(view, "#person-#{ordinary.id} .badge", "disabled")
    end

    test "closing an account says what it will take before it does anything", %{
      conn: conn,
      ordinary: ordinary
    } do
      {:ok, view, html} = live(conn, ~p"/users?user=#{ordinary.id}")

      # The danger zone says what each action does (#1699).
      assert html =~ "signs someone out everywhere and stops them signing in"
      assert html =~ "deletes the account and everything they own, after showing you what will go"

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
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")

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
      # The panel closes with them, and they are gone from the table.
      assert_patch(view, ~p"/users")
      refute has_element?(view, "#person-panel")
      refute has_element?(view, "#person-#{ordinary.id}")
    end
  end

  describe "the page" do
    test "uses the full width rather than a narrow column", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users")
      refute html =~ "max-w-3xl"
    end
  end

  describe "adding somebody" do
    test "makes the account and says they could not be emailed without mail", %{conn: conn} do
      email = fixture_email("newcomer@example.com")
      {:ok, view, _} = live(conn, ~p"/users")

      html = view |> form("#add-user", %{"email" => String.upcase(email)}) |> render_submit()

      user = Accounts.get_user_by_email(email)
      assert user.email == email
      assert user.invited_at
      assert html =~ "Added #{email}."
      refute html =~ "have been emailed"
      # They appear in the list straight away.
      assert render(view) =~ email
    end

    test "with mail, they are emailed an invitation", %{conn: conn} do
      {:ok, _} = Settings.update(mail())
      email = fixture_email("mailed@example.com")
      {:ok, view, _} = live(conn, ~p"/users")

      html = view |> form("#add-user", %{"email" => email}) |> render_submit()

      assert html =~ "They have been emailed an invitation."
      assert Accounts.get_user_by_email(email)
    end

    test "refuses an address already here, and one that isn't an address", %{
      conn: conn,
      ordinary: ordinary
    } do
      count = length(Accounts.list_users())
      {:ok, view, _} = live(conn, ~p"/users")

      html = view |> form("#add-user", %{"email" => ordinary.email}) |> render_submit()
      assert html =~ "already uses that address"

      html = view |> form("#add-user", %{"email" => "not an address"}) |> render_submit()
      assert html =~ "doesn&#39;t look like an email address"

      assert length(Accounts.list_users()) == count
    end
  end

  describe "changing somebody's address" do
    test "edits in place, and they sign in with the new one", %{conn: conn, ordinary: ordinary} do
      new_email = fixture_email("renamed@example.com")
      {:ok, view, html} = live(conn, ~p"/users?user=#{ordinary.id}")
      refute html =~ ~s(id="email-#{ordinary.id}")

      view
      |> element("button[phx-click='edit-email'][phx-value-user_id='#{ordinary.id}']")
      |> render_click()

      html =
        view
        |> form("#email-#{ordinary.id}", %{"email" => new_email})
        |> render_submit()

      assert html =~ "#{new_email} signs in with that address now."
      refute html =~ ~s(id="email-#{ordinary.id}")
      assert Slipdock.Repo.reload(ordinary).email == new_email
    end

    test "cancel leaves it as it was", %{conn: conn, ordinary: ordinary} do
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")

      view
      |> element("button[phx-click='edit-email'][phx-value-user_id='#{ordinary.id}']")
      |> render_click()

      html = view |> element("#email-#{ordinary.id} button", "Cancel") |> render_click()

      refute html =~ ~s(id="email-#{ordinary.id}")
      assert Slipdock.Repo.reload(ordinary).email == ordinary.email
    end

    test "refuses somebody else's address, and nonsense", %{
      conn: conn,
      admin: admin,
      ordinary: ordinary
    } do
      {:ok, view, _} = live(conn, ~p"/users?user=#{ordinary.id}")

      view
      |> element("button[phx-click='edit-email'][phx-value-user_id='#{ordinary.id}']")
      |> render_click()

      html =
        view |> form("#email-#{ordinary.id}", %{"email" => admin.email}) |> render_submit()

      assert html =~ "already uses that address"

      html = view |> form("#email-#{ordinary.id}", %{"email" => "nope"}) |> render_submit()
      assert html =~ "doesn&#39;t look like an email address"

      assert Slipdock.Repo.reload(ordinary).email == ordinary.email
    end
  end

  describe "signup requests" do
    setup do
      {:ok, _} = Settings.update(Map.put(mail(), "signup_mode", :approval))

      {:ok, request} =
        Accounts.request_signup(fixture_email("hopeful@example.com"), note: "Design")

      %{request: request}
    end

    test "the queue shows what they said", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/signups")

      assert html =~ fixture_email("hopeful@example.com")
      assert html =~ "Design"
    end

    test "approving makes the account", %{conn: conn, request: request} do
      {:ok, view, _} = live(conn, ~p"/users/signups")

      view
      |> element("button[phx-click='approve'][phx-value-id='#{request.id}']")
      |> render_click()

      assert Accounts.get_user_by_email(fixture_email("hopeful@example.com"))
      assert Accounts.list_signup_requests() == []
    end

    test "turning one down", %{conn: conn, request: request} do
      {:ok, view, _} = live(conn, ~p"/users/signups")

      view
      |> element("button[phx-click='reject'][phx-value-id='#{request.id}']")
      |> render_click()

      refute Accounts.get_user_by_email(fixture_email("hopeful@example.com"))
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
