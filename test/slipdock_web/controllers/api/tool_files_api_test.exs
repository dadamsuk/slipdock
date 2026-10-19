defmodule SlipdockWeb.API.ToolFilesAPITest do
  @moduledoc """
  One file of a Tool by its path in the package (#1156): what a stub skill
  fetches its procedure from at run time, the latest version unless asked,
  and where the Tool's JSON says each file and board file can be read.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Accounts, Repo, Tools}

  setup %{user: user} do
    name = unique_name()
    {:ok, v1} = Tools.publish(user, package(name))
    %{name: name, v1: v1}
  end

  defp with_token(user) do
    {token, _} = Accounts.create_api_token(user, "agent", scope: "read")
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  test "a skill's SKILL.md comes back as text, with the version and sha it is", %{
    user: user,
    name: name
  } do
    conn = user |> with_token() |> get("/api/tools/#{name}/files/skills/#{name}/SKILL.md")

    assert response(conn, 200) =~ "# #{name}\n\nRun it."
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "text/plain"
    assert get_resp_header(conn, "x-tool-version") == ["1.0.0"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    sha = :crypto.hash(:sha256, response(conn, 200)) |> Base.encode16(case: :lower)
    assert get_resp_header(conn, "etag") == [~s("#{sha}")]
  end

  test "a reference file, a declared file and the manifest are all there by path", %{
    user: user,
    name: name
  } do
    conn = with_token(user)

    assert conn
           |> get("/api/tools/#{name}/files/skills/#{name}/references/notes.md")
           |> response(200) ==
             "Notes."

    assert with_token(user) |> get("/api/tools/#{name}/files/files/helper.sh") |> response(200) ==
             "#!/bin/sh\necho hi\n"

    assert with_token(user)
           |> get("/api/tools/#{name}/files/tool.json")
           |> response(200)
           |> Jason.decode!()
           |> Map.fetch!("name") == name
  end

  test "without ?version it is the latest; with one, that version", %{user: user, name: name} do
    skill = "skills/#{name}/SKILL.md"
    new_body = "---\nname: #{name}\ndescription: Does it better.\n---\n\nRun it twice."
    {:ok, _} = Tools.publish(user, package(name, "1.1.0", %{skill => new_body}))

    latest = with_token(user) |> get("/api/tools/#{name}/files/#{skill}")
    assert response(latest, 200) =~ "Run it twice."
    assert get_resp_header(latest, "x-tool-version") == ["1.1.0"]

    old = with_token(user) |> get("/api/tools/#{name}/files/#{skill}?version=1.0.0")
    assert response(old, 200) =~ "Run it."
    refute response(old, 200) =~ "twice"
    assert get_resp_header(old, "x-tool-version") == ["1.0.0"]
  end

  test "bytes that are not text are a download under their own name", %{user: user} do
    name = unique_name()
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 255, 254>>

    {:ok, _} =
      Tools.publish(
        user,
        package(name, "1.0.0", %{
          "skills/#{name}/assets/logo.png" => png
        })
      )

    conn = with_token(user) |> get("/api/tools/#{name}/files/skills/#{name}/assets/logo.png")

    assert response(conn, 200) == png
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "application/octet-stream"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(attachment; filename="logo.png")
  end

  test "a path that isn't in the package is a 404 naming it and the version", %{
    user: user,
    name: name
  } do
    assert %{"error" => error} =
             with_token(user)
             |> get("/api/tools/#{name}/files/skills/#{name}/nope.md")
             |> json_response(404)

    assert error =~ "skills/#{name}/nope.md"
    assert error =~ "1.0.0"

    # A path that climbs is just a path that isn't there: files are looked up
    # by their exact path in the package, never on disk.
    assert with_token(user)
           |> get("/api/tools/#{name}/files/skills/../tool.json")
           |> json_response(404)
  end

  test "a missing version is a 404", %{user: user, name: name} do
    assert with_token(user)
           |> get("/api/tools/#{name}/files/tool.json?version=9.9.9")
           |> json_response(404)
  end

  test "no access is a 404 that reads like a Tool that doesn't exist", %{name: name} do
    stranger = user_fixture("files-stranger@example.com")

    assert %{"error" => hidden} =
             stranger
             |> with_token()
             |> get("/api/tools/#{name}/files/tool.json")
             |> json_response(404)

    assert %{"error" => missing} =
             stranger
             |> with_token()
             |> get("/api/tools/nope-#{name}/files/tool.json")
             |> json_response(404)

    assert String.replace(missing, "nope-", "") == hidden
  end

  test "somebody who sees it only by its listing gets the listed version, not a newer one", %{
    user: user,
    name: name,
    v1: v1
  } do
    admin =
      "files-admin@example.com"
      |> user_fixture()
      |> Ecto.Changeset.change(admin: true)
      |> Repo.update!()

    {:ok, _} = Tools.request_listing(user, v1)
    {:ok, _} = Tools.approve_listing(admin, Repo.reload(v1))

    skill = "skills/#{name}/SKILL.md"
    new_body = "---\nname: #{name}\ndescription: Unreviewed.\n---\n\nNot approved yet."
    {:ok, _} = Tools.publish(user, package(name, "2.0.0", %{skill => new_body}))

    reader = user_fixture("files-reader@example.com")

    conn = reader |> with_token() |> get("/api/tools/#{name}/files/#{skill}")
    assert response(conn, 200) =~ "Run it."
    assert get_resp_header(conn, "x-tool-version") == ["1.0.0"]

    assert reader
           |> with_token()
           |> get("/api/tools/#{name}/files/#{skill}?version=2.0.0")
           |> json_response(404)
  end

  test "the Tool's JSON says where each skill's SKILL.md and each file is read from", %{
    user: user,
    name: name
  } do
    tool =
      with_token(user) |> get("/api/tools/#{name}") |> json_response(200) |> Map.fetch!("tool")

    skill = Enum.find(tool["skills"], &(&1["name"] == name))
    assert skill["skill_md"] == "/api/tools/#{name}/files/skills/#{name}/SKILL.md?version=1.0.0"

    assert [guide, helper] = tool["files"]
    assert guide["url"] == "/api/tools/#{name}/files/files/guide.md?version=1.0.0"
    assert helper["url"] == "/api/tools/#{name}/files/files/helper.sh?version=1.0.0"

    # Not installed yet: there is no board copy to point at.
    refute Map.has_key?(guide, "board_url")

    # Each address answers.
    assert with_token(user) |> get(skill["skill_md"]) |> response(200) =~ "Run it."
    assert with_token(user) |> get(guide["url"]) |> response(200) == "A guide for the board."
  end

  test "once installed, a board file's board_url fetches the copy on the board", %{
    user: user,
    name: name
  } do
    Slipdock.TestConfig.own_uploads_dir()
    {:ok, %{board: board}} = Tools.install_board(user, Tools.Tool |> Repo.get_by!(slug: name))

    tool =
      with_token(user) |> get("/api/tools/#{name}") |> json_response(200) |> Map.fetch!("tool")

    [guide, helper] = tool["files"]

    assert guide["board_url"] == "/api/boards/#{board.code}/files/Tool/guide.md"
    # A local file goes beside its skill, never onto the board.
    refute Map.has_key?(helper, "board_url")

    assert with_token(user) |> get(guide["board_url"]) |> response(200) ==
             "A guide for the board."
  end
end
