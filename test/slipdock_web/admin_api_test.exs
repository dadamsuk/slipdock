defmodule SlipdockWeb.AdminAPITest do
  @moduledoc """
  Administering the server over HTTP, and above all who may.

  The scope is the point: tokens live in agents, scripts and CI, and the ones
  that leak are the ones lying around. An ordinary read/write token being able
  to change who may register would make every such token a key to the server.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  defp token_conn(user, scope) do
    {token, _} = Accounts.create_api_token(user, "test", scope: scope)
    build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  setup do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    %{admin: admin, ordinary: user_fixture("ordinary@example.com")}
  end

  describe "who may" do
    test "an admin with an admin-scoped token", %{admin: admin} do
      conn = get(token_conn(admin, "admin"), ~p"/api/admin/settings")
      assert json_response(conn, 200)["settings"]["signup_mode"] == "closed"
    end

    test "settings say which build answered", %{admin: admin} do
      conn = get(token_conn(admin, "admin"), ~p"/api/admin/settings")
      build = json_response(conn, 200)["build"]

      assert build["git_sha"] == Slipdock.Build.sha()
      assert build["git_short_sha"] == Slipdock.Build.short_sha()
      assert build["version"] == Slipdock.Build.version()
      assert build["built_at"]
    end

    test "an admin with an ordinary write token may not", %{admin: admin} do
      conn = get(token_conn(admin, "write"), ~p"/api/admin/settings")

      assert json_response(conn, 403)["error"] =~ "admin scope"
    end

    test "a non-admin with an admin-scoped token may not", %{ordinary: ordinary} do
      # Asking for the scope is not the same as having the rights.
      conn = get(token_conn(ordinary, "admin"), ~p"/api/admin/settings")

      assert json_response(conn, 403)["error"] =~ "not an admin"
    end

    test "no token at all", %{} do
      assert build_conn() |> get(~p"/api/admin/settings") |> json_response(401)
    end
  end

  describe "settings" do
    setup %{admin: admin}, do: %{conn: token_conn(admin, "admin")}

    test "changing what can be changed", %{conn: conn} do
      conn = patch(conn, ~p"/api/admin/settings", %{"signup_mode" => "open"})

      assert json_response(conn, 200)["settings"]["signup_mode"] == "open"
      assert Settings.signup_mode() == :open
    end

    test "the admin address and the mail server are not among them", %{conn: conn} do
      patch(conn, ~p"/api/admin/settings", %{
        "admin_email" => "hijack@example.com",
        "smtp_host" => "evil.example.com"
      })

      # Both have flows that prove something first — a code to the new address,
      # a test message that arrived. A PATCH would skip them.
      assert Settings.get().admin_email == "admin@example.com"
      refute Settings.smtp_configured?()
    end

    test "the allowlist", %{conn: conn} do
      conn = post(conn, ~p"/api/admin/allowlist", %{"entry" => "example.org"})
      assert "example.org" in json_response(conn, 200)["settings"]["allowlist"]

      conn = delete(conn, ~p"/api/admin/allowlist?entry=example.org")
      assert json_response(conn, 200)["settings"]["allowlist"] == []
    end
  end

  describe "people" do
    setup %{admin: admin}, do: %{conn: token_conn(admin, "admin")}

    test "listing says what each of them is", %{conn: conn, admin: admin} do
      users = get(conn, ~p"/api/admin/users") |> json_response(200) |> Map.get("users")

      me = Enum.find(users, &(&1["email"] == admin.email))
      assert me["admin"]
      refute me["disabled"]
      # An admin escapes the free tier's allowance but not the server-wide
      # ceiling, which is on by default on every install.
      assert me["cards"]["limit"] == 250_000
      assert me["limits"]["boards"]["limit"] == 1_000
      refute me["limits"]["trial"]["applies?"]
    end

    test "promoting, disabling, and a card limit", %{conn: conn, ordinary: ordinary} do
      patch(conn, ~p"/api/admin/users/#{ordinary.id}", %{"admin" => true})
      assert Accounts.admin?(Slipdock.Repo.reload(ordinary))

      patch(conn, ~p"/api/admin/users/#{ordinary.id}", %{"admin" => false})
      patch(conn, ~p"/api/admin/users/#{ordinary.id}", %{"disabled" => true})
      assert Accounts.disabled?(Slipdock.Repo.reload(ordinary))

      patch(conn, ~p"/api/admin/users/#{ordinary.id}", %{"card_limit" => 5})
      assert Slipdock.Repo.reload(ordinary).card_limit_override == 5
    end

    test "marking somebody unlimited, and taking it away", %{conn: conn, ordinary: ordinary} do
      {:ok, _} = Settings.update(%{"free_card_limit" => 5})

      body = patch(conn, ~p"/api/admin/users/#{ordinary.id}", %{"unlimited" => true})
      user = json_response(body, 200)["user"]
      assert user["unlimited"]
      refute user["limits"]["free"]
      # Off the free allowance, onto the server-wide ceiling.
      assert user["cards"]["limit"] == 250_000
      assert Slipdock.Repo.reload(ordinary).unlimited

      listed = get(conn, ~p"/api/admin/users") |> json_response(200) |> Map.get("users")
      assert Enum.find(listed, &(&1["email"] == ordinary.email))["unlimited"]

      body = patch(conn, ~p"/api/admin/users/#{ordinary.id}", %{"unlimited" => false})
      user = json_response(body, 200)["user"]
      refute user["unlimited"]
      assert user["cards"]["limit"] == 5
    end

    test "unlimited has to be a boolean", %{conn: conn, ordinary: ordinary} do
      body = patch(conn, ~p"/api/admin/users/#{ordinary.id}", %{"unlimited" => "yes"})
      assert json_response(body, 400)["error"] =~ "unlimited"
      refute Slipdock.Repo.reload(ordinary).unlimited
    end

    test "the last admin is protected here too, by name", %{conn: conn, admin: admin} do
      conn = patch(conn, ~p"/api/admin/users/#{admin.id}", %{"admin" => false})
      body = json_response(conn, 409)

      # The guard lives in Accounts, not in the LiveView, which is why it is
      # still here.
      assert body["error"] == "last_admin"
      assert body["retryable"] == false
      assert Accounts.admin?(Slipdock.Repo.reload(admin))
    end
  end

  describe "signups" do
    setup %{admin: admin} do
      {:ok, _} =
        Settings.update(%{
          "signup_mode" => :approval,
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "mail@example.com"
        })

      {:ok, request} = Accounts.request_signup("hopeful@example.com", note: "Design")
      %{conn: token_conn(admin, "admin"), request: request}
    end

    test "listing and approving", %{conn: conn, request: request} do
      requests = get(conn, ~p"/api/admin/signups") |> json_response(200) |> Map.get("requests")
      assert [%{"email" => "hopeful@example.com", "note" => "Design"}] = requests

      conn = post(conn, ~p"/api/admin/signups/#{request.id}/approve")
      assert json_response(conn, 200)["approved"]["email"] == "hopeful@example.com"
      assert Accounts.get_user_by_email("hopeful@example.com")
    end

    test "a request that isn't there is a 404, not a crash", %{conn: conn} do
      assert conn |> post(~p"/api/admin/signups/999999/approve") |> json_response(404)
      assert conn |> post(~p"/api/admin/signups/nope/approve") |> json_response(404)
    end

    test "rejecting", %{conn: conn, request: request} do
      conn = post(conn, ~p"/api/admin/signups/#{request.id}/reject")

      assert json_response(conn, 200)["rejected"]["status"] == "rejected"
      refute Accounts.get_user_by_email("hopeful@example.com")
    end
  end
end
