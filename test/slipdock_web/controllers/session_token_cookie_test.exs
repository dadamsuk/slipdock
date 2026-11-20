defmodule SlipdockWeb.SessionTokenCookieTest do
  # The cookie holds the raw session token and the database only its digest
  # (#3503): signing in and out through the browser, and a cookie from before
  # the change, whose LiveView id is brought up to date on its next request.
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query

  alias Slipdock.Accounts
  alias Slipdock.Accounts.UserToken
  alias Slipdock.Repo

  defp session_rows(user) do
    Repo.all(
      from(t in UserToken,
        where: t.user_id == ^user.id and t.context == "session",
        select: t.token
      )
    )
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  @tag :anonymous
  test "signing in puts the raw token in the cookie and only its digest in the database", %{
    conn: conn,
    user: user
  } do
    token = Accounts.create_sign_in_token(user)
    conn = post(conn, ~p"/login/#{token}")
    cookie_token = get_session(conn, :user_token)

    assert session_rows(user) == [digest(cookie_token)]
    refute cookie_token in session_rows(user)
    assert get_session(conn, :live_socket_id) == Accounts.session_live_socket_id(cookie_token)

    next = conn |> recycle() |> get(~p"/account")
    assert next.status == 200
    assert next.assigns.current_user.id == user.id
  end

  test "signing out deletes the digest's row", %{conn: conn, user: user} do
    token = get_session(conn, :user_token)
    assert session_rows(user) == [digest(token)]

    conn = delete(conn, ~p"/logout")

    assert redirected_to(conn) == "/login"
    assert session_rows(user) == []
  end

  test "an expired session's cookie no longer signs in", %{conn: conn, user: user} do
    token = get_session(conn, :user_token)

    Repo.update_all(UserToken.by_session_token(token),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -31, :day)]
    )

    assert conn |> get(~p"/account") |> redirected_to() =~ "/login"
    refute Accounts.get_user_by_session_token(token)
    assert session_rows(user) == [digest(token)]
  end

  describe "a cookie from before the change" do
    test "has its LiveView id replaced by the digest's, which a disconnect reaches", %{
      user: user
    } do
      token = Accounts.generate_session_token(user)
      old_id = "users_sessions:" <> Base.url_encode64(token)
      new_id = Accounts.session_live_socket_id(token)

      conn =
        build_conn()
        |> init_test_session(%{user_token: token, live_socket_id: old_id})
        |> get(~p"/account")

      assert conn.status == 200
      assert get_session(conn, :live_socket_id) == new_id

      SlipdockWeb.Endpoint.subscribe(new_id)
      Accounts.disconnect_sessions(user)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^new_id, event: "disconnect"}
    end

    test "with no live session is left alone", %{user: user} do
      token = Accounts.generate_session_token(user)
      old_id = "users_sessions:" <> Base.url_encode64(token)
      :ok = Accounts.delete_session_token(token)

      conn =
        build_conn()
        |> init_test_session(%{user_token: token, live_socket_id: old_id})
        |> get(~p"/account")

      assert redirected_to(conn) =~ "/login"
      assert get_session(conn, :live_socket_id) == old_id
    end
  end
end
