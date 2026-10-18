defmodule SlipdockWeb.HealthTest do
  # `/healthz`, which the deploy job polls after a restart and fails unless it
  # says `ok` on the commit it deployed.
  use SlipdockWeb.ConnCase, async: true

  alias SlipdockWeb.Health

  test "answers ok with the commit it was built from", %{conn: conn} do
    conn = get(conn, "/healthz")

    assert json_response(conn, 200) == %{"status" => "ok", "sha" => Slipdock.Build.sha()}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "answers HEAD too, with no body", %{conn: conn} do
    conn = head(conn, "/healthz")
    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "sets no session cookie and is not behind sign-in", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert conn.status == 200
    refute Map.has_key?(conn.resp_cookies, "_slipdock_key")
  end

  test "is 503 when the database does not answer, still naming the commit" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/healthz")
      |> Health.call(check: fn -> {:error, :timeout} end)

    assert conn.halted
    assert conn.status == 503

    assert Jason.decode!(conn.resp_body) == %{
             "status" => "unavailable",
             "sha" => Slipdock.Build.sha()
           }
  end

  test "any answer from the check but :ok is unavailable" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/healthz")
      |> Health.call(check: fn -> :anything_else end)

    assert conn.status == 503
  end

  test "leaves every other request alone" do
    for {method, path} <- [{:post, "/healthz"}, {:get, "/healthz/x"}, {:get, "/login"}] do
      conn = Phoenix.ConnTest.build_conn(method, path) |> Health.call([])
      refute conn.halted, "#{method} #{path} was answered by Health"
      assert conn.state == :unset
    end
  end

  test "the database check is :ok against a working repo" do
    assert Health.database() == :ok
  end
end
