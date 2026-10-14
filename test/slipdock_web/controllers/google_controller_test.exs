defmodule SlipdockWeb.GoogleControllerTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.GoogleStub

  alias Slipdock.Google

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "connect" do
    test "sends the person to Google with a state kept in the session", %{conn: conn} do
      conn = get(conn, ~p"/account/google/connect")
      location = redirected_to(conn)
      assert location =~ "https://accounts.google.com/o/oauth2/v2/auth?"

      state =
        location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.get("state")

      assert is_binary(state) and byte_size(state) > 20
      assert get_session(conn, "google_oauth_state") == state
    end

    test "says so when the server has no Google client", %{conn: conn} do
      Slipdock.TestConfig.put(:google, [])
      conn = get(conn, ~p"/account/google/connect")
      assert redirected_to(conn) == "/account/settings#google-drive"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't set up"
    end

    test "needs a signed-in person" do
      conn = get(build_conn(), ~p"/account/google/connect")
      assert redirected_to(conn) =~ "/login"
    end
  end

  describe "callback" do
    defp with_state(conn, state),
      do: conn |> init_test_session(%{}) |> put_session("google_oauth_state", state)

    test "a good code connects the account", %{conn: conn, user: user} do
      stub(fn conn ->
        case conn.request_path do
          "/token" -> Req.Test.json(conn, %{"access_token" => "a", "refresh_token" => "r"})
          "/drive/v3/about" -> Req.Test.json(conn, %{"user" => %{"emailAddress" => "me@example.com"}})
        end
      end)

      conn =
        conn
        |> with_state("s1")
        |> get(~p"/account/google/callback?state=s1&code=c1")

      assert redirected_to(conn) == "/account/settings#google-drive"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Google Drive connected as me@example.com."

      assert Google.status(user) == {:connected, "me@example.com"}
      assert get_session(conn, "google_oauth_state") == nil
    end

    test "a state that doesn't match is refused without asking Google", %{conn: conn, user: user} do
      stub(fn _ -> flunk("Google should not have been asked") end)

      conn = conn |> with_state("mine") |> get(~p"/account/google/callback?state=theirs&code=c")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't come from this page"
      assert Google.status(user) == :not_connected
    end

    test "no state in the session is refused", %{conn: conn, user: user} do
      conn = get(conn, ~p"/account/google/callback?state=x&code=c")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't come from this page"
      assert Google.status(user) == :not_connected
    end

    test "the person saying no at Google", %{conn: conn, user: user} do
      conn =
        conn |> with_state("s") |> get(~p"/account/google/callback?state=s&error=access_denied")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Google Drive was not connected."
      assert Google.status(user) == :not_connected
    end

    test "another error from Google", %{conn: conn} do
      conn =
        conn |> with_state("s") |> get(~p"/account/google/callback?state=s&error=server_error")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Google said no: server_error."
    end

    test "a code Google refuses", %{conn: conn, user: user} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      conn = conn |> with_state("s") |> get(~p"/account/google/callback?state=s&code=old")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "turned down"
      assert Google.status(user) == :not_connected
    end
  end

  test "disconnect deletes the connection", %{conn: conn, user: user} do
    connect!(user)
    stub(fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

    conn = delete(conn, ~p"/account/google")
    assert redirected_to(conn) == "/account/settings#google-drive"
    assert Google.connection(user) == nil
  end

  describe "the Settings tab" do
    test "offers to connect", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/settings")
      assert has_element?(view, "#google-drive-status", "Not connected")
      assert has_element?(view, "#google-drive-connect[href='/account/google/connect']")
      refute has_element?(view, "#google-drive-disconnect")
    end

    test "shows who is connected, and offers to disconnect", %{conn: conn, user: user} do
      connect!(user, email: "me@example.com")
      {:ok, view, _html} = live(conn, ~p"/account/settings")
      assert has_element?(view, "#google-drive-status", "Connected as me@example.com")
      assert has_element?(view, "#google-drive-disconnect")
      refute has_element?(view, "#google-drive-connect")
    end

    test "a revoked connection asks to connect again", %{conn: conn, user: user} do
      connect!(user, revoked: true)
      {:ok, view, _html} = live(conn, ~p"/account/settings")
      assert has_element?(view, "#google-drive-status", "no longer accepts")
      assert has_element?(view, "#google-drive-connect")
      assert has_element?(view, "#google-drive-disconnect")
    end

    test "is not there without a Google client", %{conn: conn} do
      Slipdock.TestConfig.put(:google, [])
      {:ok, view, _html} = live(conn, ~p"/account/settings")
      refute has_element?(view, "#google-drive")
    end
  end
end
