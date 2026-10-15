defmodule SlipdockWeb.PasskeyControllerTest do
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Accounts
  alias Slipdock.Accounts.Passkeys
  alias Slipdock.PasskeyAuthenticator, as: Authenticator

  # A passkey on `user`'s account, added straight through the context: these
  # tests are about the doors, not about adding.
  defp passkey_for(user) do
    a = Authenticator.new()
    {challenge, _} = Passkeys.registration_challenge(user, "https://slipdock.example.com")
    {:ok, _} = Passkeys.register(user, challenge, Authenticator.attest(a, challenge), "Phone")
    a
  end

  defp start_sign_in(conn) do
    conn = post(conn, ~p"/login/passkey/options")
    {conn, json_response(conn, 200)["publicKey"], get_session(conn, :passkey_login_challenge)}
  end

  describe "signing in" do
    @describetag :anonymous

    test "a challenge, then the signed answer, signs the passkey's owner in", %{conn: conn} do
      user = user_fixture("passkey-signin@example.com")
      a = passkey_for(user)

      {conn, options, challenge} = start_sign_in(conn)
      assert options["challenge"] == Passkeys.encode(challenge.bytes)
      assert options["rpId"] == challenge.rp_id
      assert options["userVerification"] == "required"

      response = Authenticator.assert(a, challenge, user_handle: Passkeys.user_handle(user))
      conn = conn |> recycle() |> post(~p"/login/passkey", %{"passkey" => response})

      assert redirected_to(conn) == "/"
      assert token = get_session(conn, :user_token)
      assert Accounts.get_user_by_session_token(token).id == user.id
      # The challenge is gone with the old session.
      refute get_session(conn, :passkey_login_challenge)
      assert Accounts.get_user!(user.id).last_signed_in_at
    end

    test "the same answer cannot be played twice, even with the old cookie", %{conn: conn} do
      a = passkey_for(user_fixture("passkey-replay@example.com"))
      {conn, _, challenge} = start_sign_in(conn)
      response = Authenticator.assert(a, challenge)

      used = conn |> recycle() |> post(~p"/login/passkey", %{"passkey" => response})
      assert get_session(used, :user_token)

      # Somebody who kept the cookie from before the sign-in, challenge and
      # all, and copied the answer, still gets nowhere.
      again = conn |> recycle() |> post(~p"/login/passkey", %{"passkey" => response})
      assert redirected_to(again) == "/login"
      assert Phoenix.Flash.get(again.assigns.flash, :error) =~ "can't sign in here"
      refute get_session(again, :user_token)

      # And with no challenge in the session at all, it is too late.
      fresh =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> post(~p"/login/passkey", %{"passkey" => response})

      assert Phoenix.Flash.get(fresh.assigns.flash, :error) =~ "took too long"
    end

    test "a failed answer uses the challenge up", %{conn: conn} do
      user = user_fixture("passkey-fail@example.com")
      a = passkey_for(user)
      {conn, _, challenge} = start_sign_in(conn)

      bad = Authenticator.assert(Authenticator.new(credential_id: a.credential_id), challenge)
      conn = conn |> recycle() |> post(~p"/login/passkey", %{"passkey" => bad})

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "can't sign in here"
      refute get_session(conn, :user_token)
      refute get_session(conn, :passkey_login_challenge)

      # Now the real answer to that challenge has nothing left to answer.
      good = Authenticator.assert(a, challenge)
      conn = conn |> recycle() |> post(~p"/login/passkey", %{"passkey" => good})
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "took too long"
      refute get_session(conn, :user_token)
    end

    test "a cloned passkey is told so", %{conn: conn} do
      a = passkey_for(user_fixture("passkey-clone@example.com"))

      {conn, _, challenge} = start_sign_in(conn)

      conn =
        conn
        |> recycle()
        |> post(~p"/login/passkey", %{
          "passkey" => Authenticator.assert(a, challenge, sign_count: 9)
        })

      assert get_session(conn, :user_token)

      {conn, _, challenge} = start_sign_in(build_conn())

      conn =
        conn
        |> recycle()
        |> post(~p"/login/passkey", %{
          "passkey" => Authenticator.assert(a, challenge, sign_count: 4)
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "looks like a copy"
      refute get_session(conn, :user_token)
    end

    test "a disabled account's passkey is refused like an unknown one", %{conn: conn} do
      user = user_fixture("passkey-disabled@example.com")
      a = passkey_for(user)
      {:ok, _} = Accounts.disable(user)

      {conn, _, challenge} = start_sign_in(conn)

      conn =
        conn
        |> recycle()
        |> post(~p"/login/passkey", %{"passkey" => Authenticator.assert(a, challenge)})

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "can't sign in here"
      refute get_session(conn, :user_token)
    end

    test "a post with no passkey in it is refused", %{conn: conn} do
      {conn, _, _} = start_sign_in(conn)
      conn = conn |> recycle() |> post(~p"/login/passkey", %{})
      assert redirected_to(conn) == "/login"
      refute get_session(conn, :user_token)
    end

    test "adding one needs somebody signed in", %{conn: conn} do
      assert conn |> post(~p"/account/passkeys/options") |> redirected_to() == "/login"
      assert conn |> post(~p"/account/passkeys", %{}) |> redirected_to() == "/login"
    end
  end

  describe "adding a passkey" do
    test "options for this account, then the answer keeps it", %{conn: conn, user: user} do
      conn = post(conn, ~p"/account/passkeys/options")
      options = json_response(conn, 200)["publicKey"]
      challenge = get_session(conn, :passkey_registration_challenge)

      assert options["user"]["id"] == Passkeys.encode(Passkeys.user_handle(user))
      assert options["user"]["name"] == user.email
      assert options["challenge"] == Passkeys.encode(challenge.bytes)
      assert options["excludeCredentials"] == []

      a = Authenticator.new()
      body = Map.put(Authenticator.attest(a, challenge), "name", "Desk key")
      conn = conn |> recycle() |> post(~p"/account/passkeys", body)

      assert %{"passkey" => %{"id" => id, "name" => "Desk key"}} = json_response(conn, 201)
      assert [%{id: ^id, credential_id: cred}] = Passkeys.list(user)
      assert cred == a.credential_id
      refute get_session(conn, :passkey_registration_challenge)
    end

    test "an answer with no challenge kept says so", %{conn: conn, user: user} do
      {challenge, _} = Passkeys.registration_challenge(user, "https://slipdock.example.com")
      body = Authenticator.attest(Authenticator.new(), challenge)

      assert %{"error" => "That took too long" <> _} =
               conn |> post(~p"/account/passkeys", body) |> json_response(422)

      assert Passkeys.list(user) == []
    end

    test "a bad answer, and one already added, are refused", %{conn: conn, user: user} do
      conn = post(conn, ~p"/account/passkeys/options")
      challenge = get_session(conn, :passkey_registration_challenge)

      bad =
        Authenticator.attest(Authenticator.new(), challenge, origin: "https://evil.example.net")

      assert %{"error" => "The passkey couldn't be checked" <> _} =
               conn |> recycle() |> post(~p"/account/passkeys", bad) |> json_response(422)

      other = user_fixture("passkey-owner@example.com")
      a = passkey_for(other)
      conn = post(conn, ~p"/account/passkeys/options")
      challenge = get_session(conn, :passkey_registration_challenge)

      assert %{"error" => "That passkey is already on an account here."} =
               conn
               |> recycle()
               |> post(~p"/account/passkeys", Authenticator.attest(a, challenge))
               |> json_response(422)

      assert Passkeys.list(user) == []
    end
  end
end
