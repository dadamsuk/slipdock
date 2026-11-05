defmodule SlipdockWeb.UsersPanelTest do
  @moduledoc """
  The Users page as a read-only table and a person panel (#1739): the rows
  only show, a row or its Manage link opens `?user=<id>`, and every control
  that used to sit on the row works from the panel, refusals included.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo, Settings}
  alias SlipdockWeb.UsersLive.Index, as: UsersIndex

  setup %{conn: conn} do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "signup_mode" => :closed})

    {:ok, admin} = Accounts.promote(user_fixture("panel-admin@example.com"))
    person = user_fixture("panel-person@example.com")
    %{conn: log_in_user(conn, admin), admin: admin, person: person}
  end

  defp open(conn, user), do: live(conn, ~p"/users?user=#{user.id}")

  describe "the table" do
    test "has nothing to change in its rows but one Manage link", %{
      conn: conn,
      admin: admin,
      person: person
    } do
      {:ok, view, html} = live(conn, ~p"/users")
      doc = LazyHTML.from_document(html)

      for sel <- ~w(input button select textarea form label) do
        assert Enum.count(LazyHTML.query(doc, "#people tbody #{sel}")) == 0, "a #{sel} in a row"
      end

      for user <- [admin, person] do
        links = LazyHTML.query(doc, "#person-#{user.id} a")
        assert Enum.count(links) == 1
        assert LazyHTML.attribute(links, "id") == ["manage-#{user.id}"]
        assert LazyHTML.attribute(links, "href") == ["/users?user=#{user.id}"]
      end

      refute has_element?(view, "#person-panel")
    end

    test "shows who, where from, last seen, usage, plan and role", %{
      conn: conn,
      admin: admin,
      person: person
    } do
      {:ok, _} = Accounts.update_standing(person, %{"unlimited" => true})
      {:ok, view, html} = live(conn, ~p"/users")

      headers =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#people thead th")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert headers == ["Who", "Came from", "Last seen", "Usage", "Plan", "Role", "Manage"]

      assert has_element?(view, "#person-#{person.id}", person.email)
      assert has_element?(view, "#person-#{person.id}", "signed up")
      assert has_element?(view, "#person-#{person.id}", "never")
      assert has_element?(view, "#person-#{person.id} [data-role=usage]", "0 /")
      assert has_element?(view, "#person-#{person.id} [data-role=usage]", "items")
      assert has_element?(view, "#person-#{person.id} [data-role=usage]", "0 boards")
      assert has_element?(view, "#person-#{person.id} [data-role=plan]", "Unlimited")
      assert has_element?(view, "#person-#{person.id} [data-role=roles] .badge", "unlimited")
      assert has_element?(view, "#person-#{admin.id} [data-role=roles] .badge", "admin")
      assert has_element?(view, "#person-#{admin.id} [data-role=plan]", "Admin, no allowance")
    end

    test "last seen is relative, with the exact time on hover", %{conn: conn, person: person} do
      at = DateTime.add(DateTime.utc_now(:second), -3 * 3600)
      Repo.update!(Ecto.Changeset.change(person, last_signed_in_at: at))

      {:ok, view, _} = live(conn, ~p"/users")

      assert has_element?(view, "#person-#{person.id} time#last-seen-#{person.id}", "3 h ago")

      assert has_element?(
               view,
               "#last-seen-#{person.id}[title='#{SlipdockWeb.Dates.exact(at)}']"
             )

      assert has_element?(view, "#last-seen-#{person.id}[datetime='#{DateTime.to_iso8601(at)}']")
    end
  end

  describe "opening and closing the panel" do
    test "Manage opens it at ?user=<id>", %{conn: conn, person: person} do
      {:ok, view, _} = live(conn, ~p"/users")

      view |> element("#manage-#{person.id}") |> render_click()

      assert_patch(view, ~p"/users?user=#{person.id}")
      assert has_element?(view, "#person-panel h2", "panel-person")
      assert has_element?(view, "#person-panel [data-user-id='#{person.id}']")
    end

    test "so does a click on the row", %{conn: conn, person: person} do
      {:ok, view, _} = live(conn, ~p"/users")

      view |> element("#person-#{person.id}") |> render_click()

      assert_patch(view, ~p"/users?user=#{person.id}")
      assert has_element?(view, "#person-panel #admin-#{person.id}")
    end

    test "the close button takes it away again", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)

      view |> element("#person-panel button[aria-label=Close]") |> render_click()

      assert_patch(view, ~p"/users")
      refute has_element?(view, "#person-panel")
    end

    test "opening someone else starts afresh", %{conn: conn, admin: admin, person: person} do
      {:ok, view, _} = open(conn, person)
      view |> element("#close-#{person.id}") |> render_click()
      assert has_element?(view, "#closing")

      view |> element("#manage-#{admin.id}") |> render_click()

      refute has_element?(view, "#closing")
      assert has_element?(view, "#person-panel [data-user-id='#{admin.id}']")
    end

    test "its boxes are the one field (#1723)", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)
      view |> element("#edit-email-#{person.id}") |> render_click()
      view |> element("#close-#{person.id}") |> render_click()

      boxes =
        view
        |> element("#person-panel")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(
          "input[type=text], input[type=email], input[type=number], [data-date-field]"
        )

      assert Enum.count(boxes) == 5

      for box <- boxes do
        assert "field" in String.split(Enum.join(LazyHTML.attribute(box, "class"), " ")),
               inspect(LazyHTML.attribute(box, "id"))
      end
    end

    test "stays open on the same person through a change", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)

      view |> element("#unlimited-#{person.id}") |> render_click()

      assert has_element?(view, "#person-panel #unlimited-#{person.id}[checked]")
    end

    test "an id that names nobody is a flash, and the address drops it", %{conn: conn} do
      for bad <- ["999999", "not-an-id"] do
        {:ok, view, _} = live(conn, ~p"/users")
        render_patch(view, "/users?user=#{bad}")

        assert_patch(view, ~p"/users")
        assert render(view) =~ "That isn&#39;t there any more."
        refute has_element?(view, "#person-panel")
      end
    end

    test "is only on People, not the sign-up requests", %{conn: conn, person: person} do
      {:ok, _} =
        Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "mail@example.com",
          "signup_mode" => :approval
        })

      {:ok, view, html} = live(conn, ~p"/users/signups?user=#{person.id}")

      refute has_element?(view, "#person-panel")
      refute html =~ "isn&#39;t there any more"
    end
  end

  # The info toast dismisses itself with a click, which the modal takes as a
  # click outside it: a toast for a panel action closed the panel 4.5s later.
  describe "what the panel says" do
    test "a save is said in the panel, not in a toast", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)

      view |> element("#unlimited-#{person.id}") |> render_click()

      assert has_element?(view, "#person-panel #panel-notice[data-callout=info]", "Saved.")
      refute has_element?(view, "#flash-info")
    end

    test "so is a refusal", %{conn: conn, admin: admin} do
      {:ok, view, _} = open(conn, admin)

      view |> element("#admin-#{admin.id}") |> render_click()

      assert has_element?(view, "#panel-notice[data-callout=error]", "is the only admin")
      refute has_element?(view, "#flash-error")
    end

    test "and it goes with the person", %{conn: conn, admin: admin, person: person} do
      {:ok, view, _} = open(conn, person)
      view |> element("#unlimited-#{person.id}") |> render_click()
      assert has_element?(view, "#panel-notice")

      view |> element("#manage-#{admin.id}") |> render_click()

      refute has_element?(view, "#panel-notice")
    end

    test "with no panel open it is a toast, as before", %{conn: conn, person: person} do
      {:ok, view, _} = live(conn, ~p"/users")

      render_click(view, "toggle-unlimited", %{"id" => to_string(person.id)})

      assert has_element?(view, "#flash-info", "Saved.")
      refute has_element?(view, "#panel-notice")
    end

    test "closing an account is a toast, the panel having gone", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)
      view |> element("#close-#{person.id}") |> render_click()
      view |> form("#close-account", %{"email" => person.email}) |> render_submit()

      assert has_element?(view, "#flash-info", "is gone.")
      refute has_element?(view, "#person-panel")
    end
  end

  describe "the item limit" do
    test "is set and cleared from the panel", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)

      html = view |> form("#limit-#{person.id}", %{"limit" => "25"}) |> render_submit()

      assert html =~ "Saved."
      assert Repo.reload(person).card_limit_override == 25
      assert has_element?(view, "#person-#{person.id} [data-role=usage]", "0 / 25 items")
      assert has_element?(view, "#limit-input-#{person.id}[value='25']")

      view |> form("#limit-#{person.id}", %{"limit" => " "}) |> render_submit()
      assert Repo.reload(person).card_limit_override == nil
    end

    test "refuses something that isn't a number", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)

      html =
        view
        |> element("#limit-#{person.id}")
        |> render_submit(%{"user_id" => person.id, "limit" => "lots"})

      assert html =~ "That isn&#39;t a number of cards."
      assert Repo.reload(person).card_limit_override == nil
    end
  end

  describe "the paid-up date" do
    test "is set from the panel and the table's plan says so", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)

      view |> form("#paid-until-#{person.id}", %{"paid_until" => "2031-05-06"}) |> render_change()

      assert DateTime.to_date(Repo.reload(person).paid_until) == ~D[2031-05-06]
      assert has_element?(view, "#person-#{person.id} [data-role=plan]", "Paid up to 6 May 2031")
    end

    test "refuses something that isn't a date", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)

      html =
        view
        |> element("#paid-until-#{person.id}")
        |> render_change(%{"user_id" => person.id, "paid_until" => "soon"})

      assert html =~ "That isn&#39;t a date."
      assert Repo.reload(person).paid_until == nil
    end
  end

  describe "meetings" do
    test "are allowed and taken away from the panel", %{conn: conn, person: person} do
      {:ok, person} = Accounts.update_standing(person, %{"meetings_access" => false})
      {:ok, view, _} = open(conn, person)

      view |> element("#meetings-#{person.id}") |> render_click()
      assert Repo.reload(person).meetings_access
      assert has_element?(view, "#person-#{person.id} [data-role=roles] .badge", "meetings")

      view |> element("#meetings-#{person.id}") |> render_click()
      refute Repo.reload(person).meetings_access
    end
  end

  describe "admin" do
    test "another admin can be demoted from their panel", %{conn: conn} do
      {:ok, other} = Accounts.promote(user_fixture("panel-other-admin@example.com"))
      {:ok, view, _} = open(conn, other)

      view |> element("#admin-#{other.id}") |> render_click()

      refute Accounts.admin?(Repo.reload(other))
      assert has_element?(view, "#admin-#{other.id}:not([checked])[phx-click=promote]")
    end
  end

  describe "support" do
    test "opens with a reason from the panel", %{conn: conn, admin: admin, person: person} do
      {:ok, view, _} = open(conn, person)

      html =
        view
        |> form("#support-form-#{person.id}", %{"reason" => "a lost card"})
        |> render_submit()

      assert html =~ "You can read #{person.email}&#39;s boards"
      assert [session] = Accounts.held_support_sessions(admin)
      assert session.reason == "a lost card"
      assert has_element?(view, "#support-#{session.id}", "a lost card")
    end

    test "refuses without a reason", %{conn: conn, admin: admin, person: person} do
      {:ok, view, _} = open(conn, person)

      html = view |> form("#support-form-#{person.id}", %{"reason" => "  "}) |> render_submit()

      assert html =~ "Say what the access is for"
      assert Accounts.held_support_sessions(admin) == []
    end

    test "isn't offered on your own panel, and refuses if asked", %{conn: conn, admin: admin} do
      {:ok, view, _} = open(conn, admin)

      refute has_element?(view, "#panel-support")

      html = render_click(view, "support", %{"user_id" => to_string(admin.id), "reason" => "me"})
      assert html =~ "You can already see your own boards."
    end
  end

  describe "the danger zone" do
    test "Disable and Close each ask first", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)

      assert has_element?(
               view,
               "#danger-zone #disable-#{person.id}[data-confirm*='#{person.email}']"
             )

      assert has_element?(
               view,
               "#danger-zone #close-#{person.id}[data-confirm*='#{person.email}']"
             )
    end

    test "Disable, then Enable", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)

      view |> element("#disable-#{person.id}") |> render_click()
      assert Accounts.disabled?(Repo.reload(person))
      assert has_element?(view, "#enable-#{person.id}")
      refute has_element?(view, "#disable-#{person.id}")

      view |> element("#enable-#{person.id}") |> render_click()
      refute Accounts.disabled?(Repo.reload(person))
      assert has_element?(view, "#disable-#{person.id}")
    end

    test "Close shows what goes, and Cancel backs out", %{conn: conn, person: person} do
      board_fixture(%{"name" => "Person's only board"}, owner: person)
      {:ok, view, _} = open(conn, person)

      view |> element("#close-#{person.id}") |> render_click()

      assert has_element?(view, "#closing", "Person's only board")
      refute has_element?(view, "#close-#{person.id}")

      view |> element("#closing button", "Cancel") |> render_click()

      refute has_element?(view, "#closing")
      assert has_element?(view, "#close-#{person.id}")
      assert Repo.reload(person)
    end

    test "Close goes through once the address is typed", %{conn: conn, person: person} do
      {:ok, view, _} = open(conn, person)
      view |> element("#close-#{person.id}") |> render_click()

      html = view |> form("#close-account", %{"email" => person.email}) |> render_submit()

      assert html =~ "#{person.email} is gone."
      refute Accounts.get_user(person.id)
      assert_patch(view, ~p"/users")
    end

    test "on your own panel there is nothing to press", %{conn: conn, admin: admin} do
      {:ok, view, _} = open(conn, admin)

      assert has_element?(view, "#danger-zone", "You can't disable or close your own account.")
      refute has_element?(view, "#danger-zone button")
    end

    test "you can't disable yourself, even with another admin to spare", %{
      conn: conn,
      admin: admin
    } do
      {:ok, _} = Accounts.promote(user_fixture("panel-spare-admin@example.com"))
      {:ok, view, _} = open(conn, admin)

      html = render_click(view, "disable", %{"id" => to_string(admin.id)})

      assert html =~ "You can&#39;t disable your own account."
      refute Accounts.disabled?(Repo.reload(admin))
    end

    test "you can't close yourself, at either step", %{conn: conn, admin: admin} do
      {:ok, _} = Accounts.promote(user_fixture("panel-spare-admin2@example.com"))
      {:ok, view, _} = open(conn, admin)

      html = render_click(view, "confirm-delete", %{"user_id" => to_string(admin.id)})
      assert html =~ "You can&#39;t close your own account."
      refute has_element?(view, "#closing")

      html =
        render_click(view, "delete", %{"user_id" => to_string(admin.id), "email" => admin.email})

      assert html =~ "You can&#39;t close your own account."
      assert Accounts.get_user(admin.id)
    end

    test "another admin can be disabled while one admin is left", %{conn: conn} do
      {:ok, other} = Accounts.promote(user_fixture("panel-disable-admin@example.com"))
      {:ok, view, _} = open(conn, other)

      view |> element("#disable-#{other.id}") |> render_click()

      assert Accounts.disabled?(Repo.reload(other))
    end
  end

  describe "plan_label/1" do
    test "says what somebody is on" do
      admin = %Accounts.User{admin: true}
      assert UsersIndex.plan_label(admin) == "Admin, no allowance"
      assert UsersIndex.plan_label(%Accounts.User{unlimited: true}) == "Unlimited"

      paid = %Accounts.User{paid_until: ~U[2099-03-01 00:00:00Z]}
      assert UsersIndex.plan_label(paid) == "Paid up to 1 Mar 2099"

      lapsed = %Accounts.User{paid_until: ~U[2020-03-01 00:00:00Z]}
      assert UsersIndex.plan_label(lapsed) =~ "Free, lapsed 1 Mar 2020"

      assert UsersIndex.plan_label(%Accounts.User{}) =~ "Free"
    end

    test "names the trial while it applies" do
      {:ok, _} = Settings.update(%{"trial_days" => 14, "trial_enabled" => true})
      fresh = %Accounts.User{inserted_at: DateTime.utc_now(:second)}
      old = %Accounts.User{inserted_at: ~U[2020-01-01 00:00:00Z]}

      assert UsersIndex.plan_label(fresh) == "Free · trial: 14d left"
      assert UsersIndex.plan_label(old) == "Free · trial over"
    end
  end
end
