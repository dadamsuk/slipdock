defmodule SlipdockWeb.API.ToolsAPITest do
  @moduledoc """
  Tools over the API (#960): `POST /api/tools` with a package, and reading
  one back. Somebody else's private Tool is a 404, the same as a missing one.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.Accounts

  defp with_token(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp upload(bytes) do
    path = Path.join(System.tmp_dir!(), "tool-up-#{System.unique_integer([:positive])}.tar.gz")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "p.tar.gz", content_type: "application/gzip"}
  end

  test "publishes a package sent as a multipart field, and shows it", %{user: user} do
    name = unique_name()

    body =
      user
      |> with_token()
      |> post("/api/tools", %{package: upload(package(name))})
      |> json_response(201)

    assert %{"tool" => %{"name" => ^name, "version" => "1.0.0", "mine" => true, "sha" => sha}} =
             body

    assert byte_size(sha) == 64

    shown = user |> with_token() |> get("/api/tools/#{name}") |> json_response(200)
    assert shown["tool"]["readme"] =~ "What it does."
    assert Enum.map(shown["tool"]["skills"], & &1["name"]) == [name, "#{name}-setup"]
    assert shown["tool"]["board"]["folders"] == ["Config"]
    assert %{"path" => "helper.sh", "install" => "local"} = List.last(shown["tool"]["files"])

    listed = user |> with_token() |> get("/api/tools") |> json_response(200)
    assert Enum.any?(listed["tools"], &(&1["name"] == name))
  end

  test "publishes a package sent as the gzip body", %{user: user} do
    name = unique_name()

    conn =
      user
      |> with_token()
      |> put_req_header("content-type", "application/gzip")
      |> post("/api/tools", package(name))

    assert %{"tool" => %{"name" => ^name}} = json_response(conn, 201)
  end

  test "a bad package is a 422 with the reason, and a duplicate version too", %{user: user} do
    name = unique_name()
    conn = with_token(user)

    bad = files(name, "1.0.0", %{"README.md" => nil})

    assert %{"error" => "README.md is missing"} =
             conn |> post("/api/tools", %{package: upload(tarball(bad))}) |> json_response(422)

    with_token(user)
    |> post("/api/tools", %{package: upload(package(name))})
    |> json_response(201)

    assert %{"error" => error} =
             with_token(user)
             |> post("/api/tools", %{package: upload(package(name))})
             |> json_response(422)

    assert error =~ "already published"
  end

  test "no package is a 400", %{user: user} do
    assert %{"error" => error} =
             user |> with_token() |> post("/api/tools", %{}) |> json_response(400)

    assert error =~ "multipart field “package”"
  end

  test "a read-only token can't publish", %{user: user} do
    conn =
      user
      |> with_token(scope: "read")
      |> post("/api/tools", %{package: upload(package(unique_name()))})

    assert conn.status == 403
  end

  test "somebody else's private Tool is a 404, like one that doesn't exist", %{user: user} do
    name = unique_name()
    {:ok, _} = Slipdock.Tools.publish(user, package(name))
    stranger = user_fixture("stranger@example.com")

    assert %{"error" => missing} =
             stranger |> with_token() |> get("/api/tools/nope-#{name}") |> json_response(404)

    assert %{"error" => hidden} =
             stranger |> with_token() |> get("/api/tools/#{name}") |> json_response(404)

    assert String.replace(missing, "nope-", "") == hidden

    listed = stranger |> with_token() |> get("/api/tools") |> json_response(200)
    refute Enum.any?(listed["tools"], &(&1["name"] == name))
  end

  describe "POST /api/tools/:name/install" do
    setup %{user: user} do
      Slipdock.TestConfig.own_uploads_dir()
      name = unique_name()
      {:ok, _} = Slipdock.Tools.publish(user, package(name))
      %{name: name}
    end

    test "201 with the new board's code, then 200 with the same one", %{user: user, name: name} do
      first =
        user
        |> with_token()
        |> post("/api/tools/#{name}/install", %{"name" => "Mine"})
        |> json_response(201)

      assert %{"install" => %{"board" => code, "board_name" => "Mine", "created" => true}} = first

      again =
        user |> with_token() |> post("/api/tools/#{name}/install", %{}) |> json_response(200)

      assert %{"install" => %{"board" => ^code, "created" => false}} = again

      shown = user |> with_token() |> get("/api/tools/#{name}") |> json_response(200)
      assert shown["tool"]["installed"]["board"] == code
    end

    test "a stranger gets a 404 and no board", %{name: name} do
      stranger = user_fixture("api-tool-stranger@example.com")

      assert stranger
             |> with_token()
             |> post("/api/tools/#{name}/install", %{})
             |> json_response(404)
    end

    test "a missing version is a 404", %{user: user, name: name} do
      assert %{"error" => error} =
               user
               |> with_token()
               |> post("/api/tools/#{name}/install", %{"version" => "3.0.0"})
               |> json_response(404)

      assert error =~ "version 3.0.0"
    end

    test "a token confined to boards is refused", %{user: user, name: name} do
      board = board_fixture(%{}, owner: user)

      assert user
             |> with_token(scope_boards: [board.id])
             |> post("/api/tools/#{name}/install", %{})
             |> json_response(403)
    end
  end

  describe "POST /api/tools/:name/listing" do
    test "the owner asks; anybody else is refused", %{user: user} do
      name = unique_name()
      {:ok, _} = Slipdock.Tools.publish(user, package(name))

      body = user |> with_token() |> post("/api/tools/#{name}/listing", %{}) |> json_response(200)
      assert body["tool"]["listing"]["this_version"] == "waiting for an admin"

      friend = user_fixture("api-listing-friend@example.com")

      {:ok, _} =
        Slipdock.Tools.share(user, Slipdock.Repo.get_by!(Slipdock.Tools.Tool, slug: name), friend)

      assert friend
             |> with_token()
             |> post("/api/tools/#{name}/listing", %{})
             |> json_response(403)
    end
  end
end
