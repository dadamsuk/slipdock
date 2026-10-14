defmodule Slipdock.GoogleTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GoogleStub

  alias Slipdock.Google
  alias Slipdock.Google.{Connection, Drive}
  alias Slipdock.Repo

  setup do
    %{user: user_fixture()}
  end

  describe "configured?/0 and status/1" do
    test "is off without a client id and secret", %{user: user} do
      Slipdock.TestConfig.put(:google, [])
      refute Google.configured?()
      assert Google.status(user) == :not_configured
    end

    test "says where a person stands", %{user: user} do
      assert Google.configured?()
      assert Google.status(user) == :not_connected
      connect!(user, email: "me@example.com")
      assert Google.status(user) == {:connected, "me@example.com"}
    end

    test "a revoked connection says so", %{user: user} do
      connect!(user, revoked: true)
      assert Google.status(user) == :revoked
    end
  end

  test "authorize_url/2 asks for read-only Drive, offline, with the state" do
    url = Google.authorize_url("st4te", "http://localhost:4002/account/google/callback")
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["scope"] == "https://www.googleapis.com/auth/drive.readonly"
    assert query["access_type"] == "offline"
    assert query["prompt"] == "consent"
    assert query["state"] == "st4te"
    assert query["client_id"] == "test-client.apps.googleusercontent.com"
    assert query["redirect_uri"] == "http://localhost:4002/account/google/callback"
  end

  describe "connect/3" do
    test "trades the code, stores the tokens encrypted and who it is", %{user: user} do
      stub(fn conn ->
        case conn.request_path do
          "/token" ->
            assert form(conn)["code"] == "the-code"
            assert form(conn)["client_secret"] == "test-secret"

            Req.Test.json(conn, %{
              "access_token" => "access-x",
              "refresh_token" => "refresh-x",
              "expires_in" => 3599
            })

          "/drive/v3/about" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access-x"]
            Req.Test.json(conn, %{"user" => %{"emailAddress" => "me@example.com"}})
        end
      end)

      assert {:ok, %Connection{email: "me@example.com"}} =
               Google.connect(user, "the-code", "http://x")

      stored = Repo.get_by!(Connection, user_id: user.id)
      refute stored.refresh_token =~ "refresh-x"
      refute stored.access_token =~ "access-x"
      assert Google.decrypt(stored.refresh_token) == {:ok, "refresh-x"}
      assert Google.access_token(user) == {:ok, "access-x"}
    end

    test "connecting again replaces the old connection and clears a revocation", %{user: user} do
      connect!(user, revoked: true)

      stub(fn conn ->
        case conn.request_path do
          "/token" -> Req.Test.json(conn, %{"access_token" => "a2", "refresh_token" => "r2"})
          _ -> Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert {:ok, _} = Google.connect(user, "code", "http://x")
      assert Google.status(user) == {:connected, nil}
      assert Repo.aggregate(Connection, :count) == 1
    end

    test "a code Google refuses", %{user: user} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert Google.connect(user, "used", "http://x") == {:error, :invalid_grant}
      assert Google.status(user) == :not_connected
    end

    test "no refresh token is an error, not a connection that dies in an hour", %{user: user} do
      stub(fn conn -> Req.Test.json(conn, %{"access_token" => "a"}) end)

      assert {:error, message} = Google.connect(user, "code", "http://x")
      assert message =~ "refresh token"
      assert Google.connection(user) == nil
    end

    test "another error from Google is put in words", %{user: user} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "invalid_client", "error_description" => "Unauthorized"})
      end)

      assert Google.connect(user, "code", "http://x") ==
               {:error, "Google refused the request (401: Unauthorized)."}
    end
  end

  describe "access_token/2" do
    test "without a connection", %{user: user} do
      assert Google.access_token(user) == {:error, :not_connected}
    end

    test "a fresh token is used as it is, without asking Google", %{user: user} do
      connect!(user, access_token: "still-good")
      stub(fn _conn -> flunk("Google should not have been asked") end)
      assert Google.access_token(user) == {:ok, "still-good"}
    end

    test "an expired token is refreshed and the new one kept", %{user: user} do
      connect!(user, expires_in: -10, refresh_token: "r-1")

      stub(fn conn ->
        assert form(conn)["grant_type"] == "refresh_token"
        assert form(conn)["refresh_token"] == "r-1"
        Req.Test.json(conn, %{"access_token" => "new-access", "expires_in" => 3599})
      end)

      assert Google.access_token(user) == {:ok, "new-access"}

      stub(fn _conn -> flunk("the new token should have been kept") end)
      assert Google.access_token(user) == {:ok, "new-access"}
    end

    test "invalid_grant marks the connection revoked", %{user: user} do
      connect!(user, expires_in: -10)

      stub(fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert Google.access_token(user) == {:error, :revoked}
      assert Google.status(user) == :revoked
      assert Google.access_token(user) == {:error, :revoked}
    end

    test "Google down is not a revocation", %{user: user} do
      connect!(user, expires_in: -10)
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert Google.access_token(user) == {:error, :unavailable}
      assert {:connected, _} = Google.status(user)
    end
  end

  describe "disconnect/1" do
    test "revokes the token with Google and deletes it", %{user: user} do
      connect!(user, refresh_token: "r-bye")
      test = self()

      stub(fn conn ->
        send(test, {:revoked, conn.request_path, form(conn)["token"]})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert Google.disconnect(user) == :ok
      assert_received {:revoked, "/revoke", "r-bye"}
      assert Google.connection(user) == nil
    end

    test "deletes it even when Google cannot be told", %{user: user} do
      connect!(user)
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert Google.disconnect(user) == :ok
      assert Google.connection(user) == nil
    end

    test "with nothing connected", %{user: user} do
      assert Google.disconnect(user) == :ok
    end
  end

  describe "Drive" do
    test "a 401 from Drive refreshes the token and asks once more", %{user: user} do
      connect!(user, access_token: "stale")

      stub(fn conn ->
        case {conn.request_path, Plug.Conn.get_req_header(conn, "authorization")} do
          {"/drive/v3/files/f1", ["Bearer stale"]} ->
            Plug.Conn.send_resp(conn, 401, "")

          {"/token", _} ->
            Req.Test.json(conn, %{"access_token" => "fresh", "expires_in" => 3599})

          {"/drive/v3/files/f1", ["Bearer fresh"]} ->
            Req.Test.json(conn, %{"id" => "f1", "mimeType" => "audio/mp4"})
        end
      end)

      assert Drive.file(user, "f1") == {:ok, %{"id" => "f1", "mimeType" => "audio/mp4"}}
    end

    test "errors come back as atoms", %{user: user} do
      assert Drive.file(user, "f1") == {:error, :not_connected}

      connect!(user)
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
      assert Drive.file(user, "f1") == {:error, :not_found}

      stub(fn conn -> Plug.Conn.send_resp(conn, 502, "") end)
      assert Drive.file(user, "f1") == {:error, :unavailable}

      stub(fn conn -> Plug.Conn.send_resp(conn, 403, "{}") end)
      assert Drive.file(user, "f1") == {:error, {:status, 403}}
    end

    test "child/3 searches a folder by name, quoting it", %{user: user} do
      connect!(user)
      test = self()

      stub(fn conn ->
        send(test, {:q, conn.query_params["q"]})
        Req.Test.json(conn, %{"files" => [%{"id" => "c1", "name" => "Bob's"}]})
      end)

      assert {:ok, %{"id" => "c1"}} = Drive.child(user, "root", "Bob's")
      assert_received {:q, q}
      assert q == "name = 'Bob\\'s' and 'root' in parents and trashed = false"

      stub(fn conn -> Req.Test.json(conn, %{"files" => []}) end)
      assert Drive.child(user, "root", "nope") == {:error, :not_found}
    end
  end
end
