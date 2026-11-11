defmodule SlipdockWeb.SessionRenewalTest do
  # Signing in starts a fresh session: nothing the browser's session held
  # before carries over into the signed-in one, except where it was going.
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.Accounts

  @moduletag :anonymous

  # The session key `protect_from_forgery` keeps its token under.
  @csrf_key "_csrf_token"

  # A session as a browser might hold one before signing in: a value of its
  # own, a CSRF token, and (when given) where it was heading.
  defp with_earlier_session(conn, extra \\ %{}) do
    csrf = Base.url_encode64(:crypto.strong_rand_bytes(18))
    session = Map.merge(%{:planted => "x", @csrf_key => csrf}, extra)
    {Plug.Test.init_test_session(conn, session), csrf}
  end

  defp renewed?(conn), do: conn.private[:plug_session_info] == :renew

  describe "signing in by magic link" do
    test "starts a fresh session and still goes where the browser was heading", %{
      conn: conn,
      user: user
    } do
      {conn, csrf} = with_earlier_session(conn, %{user_return_to: "/account"})
      token = Accounts.create_sign_in_token(user)

      # The earlier session is what the request arrives with.
      page = get(conn, ~p"/login/#{token}")
      assert html_response(page, 200)
      assert get_session(page, :planted) == "x"
      assert get_session(page, @csrf_key) == csrf

      conn = post(conn, ~p"/login/#{token}")

      assert redirected_to(conn) == "/account"
      assert renewed?(conn)
      assert user.id == Accounts.get_user_by_session_token(get_session(conn, :user_token)).id
      assert get_session(conn, :planted) == nil
      assert get_session(conn, :user_return_to) == nil
      assert get_session(conn, @csrf_key) != csrf

      # All of the session but the flash is the new sign-in.
      assert conn |> get_session() |> Map.keys() |> Enum.sort() ==
               ["live_socket_id", "phoenix_flash", "user_token"]

      # The cookie the browser was sent says the same on the next request.
      next = conn |> recycle() |> get("/account")
      assert next.status == 200
      assert next.assigns.current_user.id == user.id
      assert get_session(next, :planted) == nil
      assert get_session(next, :user_return_to) == nil
      assert get_session(next, @csrf_key) != csrf
    end

    test "with nowhere asked for, lands on the index with a fresh session", %{
      conn: conn,
      user: user
    } do
      {conn, csrf} = with_earlier_session(conn)
      token = Accounts.create_sign_in_token(user)

      conn = post(conn, ~p"/login/#{token}")

      assert redirected_to(conn) == "/"
      assert renewed?(conn)
      assert get_session(conn, :user_token)
      assert get_session(conn, :planted) == nil
      assert get_session(conn, @csrf_key) != csrf
    end

    test "a link that doesn't work leaves the session as it was", %{conn: conn} do
      {conn, csrf} = with_earlier_session(conn, %{user_return_to: "/account"})

      conn = post(conn, ~p"/login/bogus")

      assert redirected_to(conn) == "/login"
      refute renewed?(conn)
      assert get_session(conn, :user_token) == nil
      assert get_session(conn, :planted) == "x"
      assert get_session(conn, :user_return_to) == "/account"
      assert get_session(conn, @csrf_key) == csrf
    end

    test "a form token made earlier in the same request isn't kept", %{conn: conn, user: user} do
      # The browser pipeline without a controller, so the token can be made
      # here, in the request's process, before `log_in_user/3` runs.
      conn =
        conn
        |> Plug.Test.init_test_session(%{planted: "x"})
        |> bypass_through(SlipdockWeb.Router, [:browser])
        |> get("/")

      assert is_binary(Plug.CSRFProtection.get_csrf_token())
      conn = SlipdockWeb.UserAuth.log_in_user(conn, user)

      assert redirected_to(conn) == "/"
      assert renewed?(conn)
      assert get_session(conn, :user_token)
      assert get_session(conn, :planted) == nil
      assert get_session(conn, @csrf_key) == nil
    end
  end

  describe "signing in to add a passkey" do
    test "starts a fresh session and lands on the passkeys, wherever it was heading", %{
      conn: conn,
      user: user
    } do
      {conn, csrf} = with_earlier_session(conn, %{user_return_to: "/account"})
      token = Accounts.create_sign_in_token(user)

      conn = post(conn, ~p"/login/#{token}", %{"then" => "passkey"})

      assert redirected_to(conn) == "/account/sign-in#passkeys"
      assert renewed?(conn)
      assert user.id == Accounts.get_user_by_session_token(get_session(conn, :user_token)).id
      assert get_session(conn, :planted) == nil
      assert get_session(conn, :user_return_to) == nil
      assert get_session(conn, @csrf_key) != csrf
    end
  end

  describe "signing out" do
    test "starts a fresh session too", %{conn: conn, user: user} do
      {conn, csrf} = with_earlier_session(conn)
      token = Accounts.create_sign_in_token(user)
      signed_in = post(conn, ~p"/login/#{token}")
      session_token = get_session(signed_in, :user_token)

      conn =
        signed_in
        |> recycle()
        |> Plug.Test.init_test_session(%{:planted => "y", @csrf_key => csrf})
        |> delete(~p"/logout")

      assert redirected_to(conn) == "/login"
      assert renewed?(conn)
      assert get_session(conn, :user_token) == nil
      assert get_session(conn, :planted) == nil
      assert get_session(conn, @csrf_key) != csrf
      assert Accounts.get_user_by_session_token(session_token) == nil
    end
  end
end
