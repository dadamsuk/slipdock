defmodule SlipdockWeb.PasskeyNudgeTest do
  # The sign-in confirm page offers a passkey (#831): a second button that
  # signs in the same way and then lands on adding one.
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Slipdock.Accounts

  @moduletag :anonymous

  test "the confirm page offers to set up a passkey, posting the same token", %{
    conn: conn,
    user: user
  } do
    token = Accounts.create_sign_in_token(user)
    page = conn |> get(~p"/login/#{token}") |> html_response(200)

    assert page =~ "Configure a passkey for faster and more secure sign in"
    assert page =~ ~s(id="confirm-sign-in")
    [form] = Regex.run(~r{<form[^>]*id="confirm-sign-in-passkey".*?</form>}s, page)
    assert form =~ ~s(action="/login/#{token}")
    assert form =~ ~s(name="then" value="passkey")
    # Opening the page uses nothing up.
    assert Accounts.magic_link_valid?(token)
  end

  test "pressing it signs in and lands on the passkeys section of the account page", %{
    conn: conn,
    user: user
  } do
    token = Accounts.create_sign_in_token(user)
    conn = post(conn, ~p"/login/#{token}", %{"then" => "passkey"})

    assert redirected_to(conn) == "/account#passkeys"
    assert get_session(conn, :user_token)
    refute Accounts.magic_link_valid?(token)

    {:ok, _view, html} = conn |> recycle() |> live(~p"/account")
    assert html =~ ~s(id="passkeys")
  end

  test "it wins over wherever the browser was heading before signing in", %{
    conn: conn,
    user: user
  } do
    token = Accounts.create_sign_in_token(user)

    conn =
      conn
      |> init_test_session(%{user_return_to: "/boards"})
      |> post(~p"/login/#{token}", %{"then" => "passkey"})

    assert redirected_to(conn) == "/account#passkeys"
  end

  test "the plain button still goes where it did", %{conn: conn, user: user} do
    token = Accounts.create_sign_in_token(user)

    conn =
      conn
      |> init_test_session(%{user_return_to: "/boards"})
      |> post(~p"/login/#{token}")

    assert redirected_to(conn) == "/boards"
  end

  test "a used or expired link signs nobody in, whichever button", %{conn: conn, user: user} do
    token = Accounts.create_sign_in_token(user)
    post(conn, ~p"/login/#{token}")

    conn = post(build_conn(), ~p"/login/#{token}", %{"then" => "passkey"})
    assert redirected_to(conn) == "/login"
    refute get_session(conn, :user_token)
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
  end

  test "an unknown follow-on is ignored: a plain sign-in", %{conn: conn, user: user} do
    token = Accounts.create_sign_in_token(user)
    conn = post(conn, ~p"/login/#{token}", %{"then" => "elsewhere"})

    refute redirected_to(conn) =~ "/account"
    assert get_session(conn, :user_token)
  end
end
