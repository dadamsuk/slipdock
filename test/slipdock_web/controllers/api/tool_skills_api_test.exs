defmodule SlipdockWeb.API.ToolSkillsAPITest do
  @moduledoc """
  A Tool's skills for every client (#962): one tar for a skills directory
  (Claude Code and the CLI), a zip per skill for claude.ai's upload and one
  for ChatGPT's, and shas a local copy can be checked against.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Accounts, Skills, Tools}

  setup %{user: user} do
    name = unique_name()
    {:ok, version} = Tools.publish(user, package(name))
    %{name: name, version: version}
  end

  defp with_token(user) do
    {token, _} = Accounts.create_api_token(user, "agent")
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  defp unzip(bytes) do
    {:ok, files} = :zip.extract(bytes, [:memory])
    Map.new(files, fn {path, content} -> {to_string(path), content} end)
  end

  test "the tarball lays the skills out for a skills directory, local files beside", %{
    user: user,
    name: name
  } do
    conn = user |> with_token() |> get("/api/tools/#{name}/skills.tar.gz")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "#{name}-skills.tar.gz"

    {:ok, entries} = :erl_tar.extract({:binary, response(conn, 200)}, [:compressed, :memory])
    files = Map.new(entries, fn {p, c} -> {to_string(p), c} end)

    assert Map.keys(files) |> Enum.sort() ==
             Enum.sort([
               "#{name}/SKILL.md",
               "#{name}/helper.sh",
               "#{name}/references/notes.md",
               "#{name}-setup/SKILL.md"
             ])

    assert files["#{name}/helper.sh"] == "#!/bin/sh\necho hi\n"
    refute Map.has_key?(files, "#{name}/guide.md")
  end

  test "each skill's sha is the one its unpacked files give", %{user: user, name: name} do
    shown = user |> with_token() |> get("/api/tools/#{name}") |> json_response(200)
    bytes = user |> with_token() |> get("/api/tools/#{name}/skills.tar.gz") |> response(200)
    {:ok, entries} = :erl_tar.extract({:binary, bytes}, [:compressed, :memory])
    files = Map.new(entries, fn {p, c} -> {to_string(p), c} end)

    for skill <- shown["tool"]["skills"] do
      local = Enum.map(skill["files"], &{&1, files[Path.join(skill["name"], &1)]})
      assert Skills.digest(local) == skill["sha"]
    end

    # A changed file changes it.
    [main | _] = shown["tool"]["skills"]
    changed = Enum.map(main["files"], &{&1, "edited " <> files[Path.join(main["name"], &1)]})
    refute Skills.digest(changed) == main["sha"]
  end

  test "claude.ai's zip holds one skill's folder, untouched", %{user: user, name: name} do
    shown = user |> with_token() |> get("/api/tools/#{name}") |> json_response(200)
    [skill | _] = shown["tool"]["skills"]
    assert skill["claude_zip"] == "/api/tools/#{name}/skills/#{name}/claude.zip?version=1.0.0"

    files = user |> with_token() |> get(skill["claude_zip"]) |> response(200) |> unzip()

    assert Map.keys(files) |> Enum.sort() ==
             ["#{name}/SKILL.md", "#{name}/helper.sh", "#{name}/references/notes.md"]

    assert files["#{name}/SKILL.md"] == files(name)["skills/#{name}/SKILL.md"]
  end

  test "ChatGPT's zip keeps the front matter first and adds the connector", %{
    user: user,
    name: name
  } do
    files =
      user
      |> with_token()
      |> get("/api/tools/#{name}/skills/#{name}-setup/chatgpt.zip")
      |> response(200)
      |> unzip()

    skill_md = files["#{name}-setup/SKILL.md"]
    assert skill_md =~ ~r/\A---\nname: #{name}-setup\n/
    assert skill_md =~ "## Using this in ChatGPT"
    assert skill_md =~ "/mcp"
    assert skill_md =~ "Call install_tool."
  end

  test "an unknown skill of a visible Tool is a 404", %{user: user, name: name} do
    assert user
           |> with_token()
           |> get("/api/tools/#{name}/skills/nope/claude.zip")
           |> json_response(404)
  end

  test "no access is a 404 that reads exactly like a Tool that doesn't exist", %{name: name} do
    stranger = user_fixture("skills-stranger@example.com")

    for path <- ["skills.tar.gz", "skills/#{name}/claude.zip", "skills/#{name}/chatgpt.zip"] do
      hidden = stranger |> with_token() |> get("/api/tools/#{name}/#{path}") |> json_response(404)

      missing =
        stranger
        |> with_token()
        |> get("/api/tools/no-such-#{name}/#{String.replace(path, name, "no-such-" <> name)}")
        |> json_response(404)

      assert String.replace(hidden["error"], name, "X") ==
               String.replace(missing["error"], "no-such-" <> name, "X")
    end
  end

  test "an old version's skills are there by version", %{user: user, name: name} do
    new_skill = "---\nname: #{name}\ndescription: Newer.\n---\nv2"

    {:ok, _} =
      Tools.publish(user, package(name, "1.1.0", %{"skills/#{name}/SKILL.md" => new_skill}))

    old =
      user |> with_token() |> get("/api/tools/#{name}/skills/#{name}/claude.zip?version=1.0.0")

    new = user |> with_token() |> get("/api/tools/#{name}/skills/#{name}/claude.zip")

    assert unzip(response(old, 200))["#{name}/SKILL.md"] =~ "Run it."
    assert unzip(response(new, 200))["#{name}/SKILL.md"] =~ "v2"
  end
end
