defmodule SlipdockWeb.API.ToolPackageAPITest do
  @moduledoc """
  A Tool's whole package as a download: every file at its path, rebuilt
  from what was stored (the uploaded archive isn't kept), so it reads back
  with the version's sha and publishes again once its version is bumped.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Accounts, Tools}
  alias Slipdock.Tools.Package

  setup %{user: user} do
    name = unique_name()
    {:ok, version} = Tools.publish(user, package(name))
    %{name: name, version: version}
  end

  defp with_token(user) do
    {token, _} = Accounts.create_api_token(user, "agent", scope: "read")
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  defp unpack(bytes) do
    {:ok, entries} = :erl_tar.extract({:binary, bytes}, [:compressed, :memory])
    Map.new(entries, fn {p, c} -> {to_string(p), c} end)
  end

  test "every file of the package comes back at its path, bytes and all", %{
    user: user,
    name: name
  } do
    conn = user |> with_token() |> get("/api/tools/#{name}/package.tar.gz")

    assert get_resp_header(conn, "content-type") == ["application/gzip"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition == ~s(attachment; filename="#{name}-1.0.0.tar.gz")
    assert unpack(response(conn, 200)) == files(name)
  end

  test "it reads back as the same version, and publishes once the version is bumped", %{
    user: user,
    name: name,
    version: version
  } do
    bytes = user |> with_token() |> get("/api/tools/#{name}/package.tar.gz") |> response(200)

    assert {:ok, package} = Package.read(bytes)
    assert Package.sha(package.entries) == version.sha

    # As it stands it is the same version, which never changes.
    assert {:error, message} = Tools.publish(user, bytes)
    assert message =~ "already published"

    bumped =
      bytes
      |> unpack()
      |> Map.update!("tool.json", &String.replace(&1, ~s("1.0.0"), ~s("1.0.1")))
      |> tarball()

    assert {:ok, republished} = Tools.publish(user, bumped)
    assert republished.version == "1.0.1"
  end

  test "binary files survive the trip untouched", %{user: user} do
    name = unique_name()
    png = <<137, 80, 78, 71, 0, 255, 254>>
    {:ok, _} = Tools.publish(user, package(name, "1.0.0", %{"skills/#{name}/logo.png" => png}))

    files =
      user
      |> with_token()
      |> get("/api/tools/#{name}/package.tar.gz")
      |> response(200)
      |> unpack()

    assert files["skills/#{name}/logo.png"] == png
  end

  test "the latest version unless version names an older one; an unknown version is a 404", %{
    user: user,
    name: name
  } do
    {:ok, _} = Tools.publish(user, package(name, "1.1.0", %{"README.md" => "# Newer"}))

    latest = user |> with_token() |> get("/api/tools/#{name}/package.tar.gz")
    assert get_resp_header(latest, "content-disposition") |> hd() =~ "#{name}-1.1.0.tar.gz"
    assert unpack(response(latest, 200))["README.md"] == "# Newer"

    old = user |> with_token() |> get("/api/tools/#{name}/package.tar.gz?version=1.0.0")
    assert unpack(response(old, 200))["README.md"] == "# Demo\n\nWhat it does."

    assert user
           |> with_token()
           |> get("/api/tools/#{name}/package.tar.gz?version=9.9.9")
           |> json_response(404)
  end

  test "the Tool's JSON says where the package is", %{user: user, name: name} do
    shown = user |> with_token() |> get("/api/tools/#{name}") |> json_response(200)
    assert shown["tool"]["package"] == "/api/tools/#{name}/package.tar.gz?version=1.0.0"
  end

  test "no access is a 404 that reads exactly like a Tool that doesn't exist", %{name: name} do
    stranger = user_fixture("package-stranger@example.com")

    hidden =
      stranger |> with_token() |> get("/api/tools/#{name}/package.tar.gz") |> json_response(404)

    missing =
      stranger
      |> with_token()
      |> get("/api/tools/no-such-#{name}/package.tar.gz")
      |> json_response(404)

    assert String.replace(hidden["error"], name, "X") ==
             String.replace(missing["error"], "no-such-" <> name, "X")
  end

  test "a grantee can download it too", %{user: user, name: name, version: version} do
    friend = user_fixture("package-friend@example.com")
    {:ok, _} = Tools.share(user, version.tool, friend)

    assert friend
           |> with_token()
           |> get("/api/tools/#{name}/package.tar.gz")
           |> response(200)
           |> unpack() == files(name)
  end
end
