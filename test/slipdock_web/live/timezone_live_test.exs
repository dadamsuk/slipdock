defmodule SlipdockWeb.TimezoneLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "the first connected page adopts the browser's timezone", %{conn: conn, user: user} do
    conn = Phoenix.LiveViewTest.put_connect_params(conn, %{"timezone" => "Europe/London"})
    {:ok, _view, _html} = live(conn, ~p"/account")
    assert Accounts.get_user!(user.id).timezone == "Europe/London"
  end

  test "a later browser doesn't overwrite it", %{conn: conn, user: user} do
    {:ok, _} = Accounts.update_profile(user, %{"timezone" => "Asia/Tokyo"})
    conn = Phoenix.LiveViewTest.put_connect_params(conn, %{"timezone" => "Europe/London"})
    {:ok, _view, _html} = live(conn, ~p"/account")
    assert Accounts.get_user!(user.id).timezone == "Asia/Tokyo"
  end

  test "a page with no timezone in its connect params leaves it unset", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/account")
    assert Accounts.get_user!(user.id).timezone == nil
    # Shown as the default meanwhile.
    assert has_element?(view, ~s|#profile-form option[selected][value="Etc/UTC"]|)
  end

  test "Account edits it, and refuses an unknown zone", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/account")

    view
    |> form("#profile-form", user: %{name: "Sam", timezone: "America/New_York"})
    |> render_submit()

    assert Accounts.get_user!(user.id).timezone == "America/New_York"
    assert has_element?(view, ~s|#profile-form option[selected][value="America/New_York"]|)

    # Not on the picker, but a hand-made post must not get one in either.
    html = render_submit(view |> element("#profile-form"), %{user: %{timezone: "Bogus/Zone"}})
    assert html =~ "isn&#39;t a timezone"
    assert Accounts.get_user!(user.id).timezone == "America/New_York"
  end

  test "GET /api/me says the timezone, the default until one is set", %{user: user} do
    assert %{"user" => %{"timezone" => "Etc/UTC"}} =
             conn_as(user) |> get(~p"/api/me") |> json_response(200)

    {:ok, user} = Accounts.update_profile(user, %{"timezone" => "Europe/Paris"})

    assert %{"user" => %{"timezone" => "Europe/Paris"}} =
             conn_as(user) |> get(~p"/api/me") |> json_response(200)
  end
end
