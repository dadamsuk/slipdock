defmodule SlipdockWeb.SignInGateLiveTest do
  @moduledoc """
  The sign-in page with the gate on: a refused address learns nothing it did
  not already know, too many attempts are refused, and every browser response
  carries the Content-Security-Policy.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, RateLimit}

  setup do
    previous_limit = Application.get_env(:slipdock, :rate_limit)

    on_exit(fn ->
      Application.put_env(:slipdock, :rate_limit, previous_limit)
      RateLimit.reset()
    end)

    :ok
  end

  # Registration policy is a row now, and writing one also marks the server set
  # up — which is the other thing that has to be true for "closed" to mean
  # anything (an unclaimed server lets anybody in on purpose).
  defp closed do
    {:ok, _} =
      Slipdock.Settings.complete_setup(%{
        "admin_email" => "admin@example.com",
        "signup_mode" => :closed
      })

    :ok
  end

  describe "a closed instance" do
    @tag :anonymous
    test "a stranger gets the same screen as a member, and no account", %{conn: conn} do
      user_fixture("owner@example.com")
      closed()

      {:ok, view, _html} = live(conn, ~p"/login")

      html =
        view
        |> form("#login-form", %{"login" => %{"email" => "stranger@example.com"}})
        |> render_submit()

      # The wording cannot be read as "you have an account here".
      assert html =~ "can sign in here, a link is on its way"
      assert html =~ "stranger@example.com"
      refute Accounts.get_user_by_email("stranger@example.com")

      {:ok, view, _} = live(conn, ~p"/login")

      member =
        view
        |> form("#login-form", %{"login" => %{"email" => "owner@example.com"}})
        |> render_submit()

      assert member =~ "can sign in here, a link is on its way"
    end

    @tag :anonymous
    test "an allowed domain does get in", %{conn: conn} do
      user_fixture("owner@example.com")
      Application.put_env(:slipdock, :signups, open: false, allow: ["@work.example"])

      {:ok, view, _html} = live(conn, ~p"/login")

      view
      |> form("#login-form", %{"login" => %{"email" => "new@work.example"}})
      |> render_submit()

      assert Accounts.get_user_by_email("new@work.example")
    end

    @tag :anonymous
    test "Agentic Login says no rather than writing a link", %{conn: conn} do
      user_fixture("owner@example.com")
      closed()

      {:ok, view, _html} = live(conn, ~p"/login")

      html =
        view
        |> form("#login-form", %{"login" => %{"email" => "stranger@example.com"}})
        |> render_submit(%{"login" => %{"mode" => "agentic"}})

      assert html =~ "can&#39;t sign in on this server" or html =~ "can't sign in on this server"
      refute has_element?(view, "#agentic-login-file")
    end
  end

  describe "too many attempts" do
    @tag :anonymous
    test "the sixth try for one address is refused", %{conn: conn} do
      Application.put_env(:slipdock, :signups, open: true)
      Application.put_env(:slipdock, :rate_limit, enabled: true)
      RateLimit.reset()

      html =
        Enum.reduce(1..6, nil, fn _, _acc ->
          {:ok, view, _} = live(conn, ~p"/login")

          view
          |> form("#login-form", %{"login" => %{"email" => "keen@example.com"}})
          |> render_submit()
        end)

      assert html =~ "Too many sign-in attempts"
    end
  end

  describe "headers" do
    @tag :anonymous
    test "every browser page carries the policy, and it forbids inline script", %{conn: conn} do
      conn = get(conn, ~p"/login")
      [policy] = get_resp_header(conn, "content-security-policy")

      assert policy =~ "script-src 'self'"
      refute policy =~ "'unsafe-inline' 'self'"
      refute policy =~ "script-src 'self' 'unsafe-inline'"
      assert policy =~ "object-src 'none'"
      assert policy =~ "frame-ancestors 'self'"

      # ...and the page really has no inline script to need an exception for.
      refute html_response(conn, 200) =~ "<script>"
    end

    @tag :anonymous
    test "an operator can replace or remove it", %{conn: conn} do
      Application.put_env(:slipdock, :csp, "default-src 'none'")
      on_exit(fn -> Application.delete_env(:slipdock, :csp) end)

      assert ["default-src 'none'"] =
               conn |> get(~p"/login") |> get_resp_header("content-security-policy")

      # `false` means "send none of ours"; Phoenix's own two-directive header
      # from put_secure_browser_headers is still there, which is the point of
      # the setting — somebody whose proxy sets a policy wants ours out of the
      # way, not the framework's.
      Application.put_env(:slipdock, :csp, false)
      [theirs] = conn |> get(~p"/login") |> get_resp_header("content-security-policy")
      refute theirs =~ "script-src"
    end
  end
end
