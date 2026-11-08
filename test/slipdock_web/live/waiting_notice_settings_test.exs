defmodule SlipdockWeb.WaitingNoticeSettingsTest do
  @moduledoc """
  "When something waits on you" in account settings (#2095): the alert and
  the email, both on by default, each switched off and on again here.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Accounts

  setup %{conn: conn} do
    user = user_fixture("notice@example.com")
    %{conn: log_in_user(conn, user), user: user}
  end

  test "both start on, and each switches on its own", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/account/settings")
    assert has_element?(view, "#waiting-alerts[checked]")
    assert has_element?(view, "#waiting-emails[checked]")

    view
    |> form("#waiting-notice-form", notice: %{waiting_alerts: "false", waiting_emails: "true"})
    |> render_submit()

    user = Accounts.get_user!(user.id)
    refute user.waiting_alerts
    assert user.waiting_emails

    {:ok, again, _} = live(conn, ~p"/account/settings")
    refute has_element?(again, "#waiting-alerts[checked]")
    assert has_element?(again, "#waiting-emails[checked]")

    again
    |> form("#waiting-notice-form", notice: %{waiting_alerts: "true", waiting_emails: "false"})
    |> render_submit()

    user = Accounts.get_user!(user.id)
    assert user.waiting_alerts
    refute user.waiting_emails
  end
end
