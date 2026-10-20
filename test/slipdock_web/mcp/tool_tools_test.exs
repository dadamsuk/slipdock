defmodule SlipdockWeb.MCP.ToolToolsTest do
  @moduledoc """
  The Tools over MCP: `install_tool` builds the board and answers with its
  code (#961), whichever client is asking.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Accounts, Repo, Tools}

  setup %{user: user} do
    Slipdock.TestConfig.own_uploads_dir()
    name = unique_name()
    {:ok, version} = Tools.publish(user, package(name))
    %{name: name, tool: version.tool}
  end

  defp call(conn, tool, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ok!(result) do
    assert result["isError"] == false, inspect(result["content"])
    result["structuredContent"]
  end

  defp error!(result) do
    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    text
  end

  defp token_conn(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "mcp", opts)
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "install_tool" do
    test "builds the board, answers with its code, and finds it again", %{user: user, name: name} do
      first = user |> token_conn() |> call("install_tool", %{"tool" => name}) |> ok!()

      assert first["created"] == true
      assert first["board"] =~ ~r/^[a-z0-9-]+$/
      assert first["url"] =~ "/boards/#{first["board_id"]}"
      assert first["added"]["lists"] == ["Found", "Doing", "Closed"]
      assert first["installed_version"] == "1.0.0"

      again = user |> token_conn() |> call("install_tool", %{"tool" => name}) |> ok!()
      assert again["created"] == false
      assert again["upgraded"] == false
      assert again["board"] == first["board"]

      {:ok, _} = Tools.publish(user, package(name, "1.1.0"))
      upgraded = user |> token_conn() |> call("install_tool", %{"tool" => name}) |> ok!()
      assert upgraded["upgraded"] == true
      assert upgraded["installed_version"] == "1.1.0"
      assert upgraded["board"] == first["board"]
      assert "Found" in upgraded["skipped"]["lists"]
    end

    test "a Tool the caller can't see reads as one that doesn't exist", %{name: name} do
      stranger = user_fixture("mcp-tool-stranger@example.com")
      hidden = stranger |> token_conn() |> call("install_tool", %{"tool" => name}) |> error!()

      missing =
        stranger |> token_conn() |> call("install_tool", %{"tool" => "zz-none"}) |> error!()

      assert hidden =~ "no Tool you can see is called"
      assert String.replace(hidden, name, "X") == String.replace(missing, "zz-none", "X")
    end

    test "a version that isn't there is an error", %{user: user, name: name} do
      text =
        user
        |> token_conn()
        |> call("install_tool", %{"tool" => name, "version" => "7.0.0"})
        |> error!()

      assert text =~ "no such version"
    end

    test "a read-only token can't install", %{user: user, name: name} do
      text =
        user |> token_conn(scope: "read") |> call("install_tool", %{"tool" => name}) |> error!()

      assert text =~ "read-only"
    end

    test "a token confined to some boards can't make one", %{user: user, name: name} do
      board = board_fixture(%{}, owner: user)
      conn = token_conn(user, scope_boards: [board.id])

      assert call(conn, "install_tool", %{"tool" => name}) |> error!() =~
               "confined to some boards"
    end
  end

  describe "list_tools" do
    test "gives each kind, and the board an install made", %{user: user, name: name, tool: tool} do
      friend = user_fixture("mcp-list-friend@example.com")
      {:ok, _} = Tools.share(user, tool, friend)

      mine = user |> token_conn() |> call("list_tools", %{}) |> ok!()

      assert %{"kind" => "mine", "installed" => nil} =
               Enum.find(mine["tools"], &(&1["name"] == name))

      {:ok, %{board: board}} = Tools.install_board(friend, tool)
      theirs = friend |> token_conn(scope: "read") |> call("list_tools", %{}) |> ok!()
      entry = Enum.find(theirs["tools"], &(&1["name"] == name))
      assert entry["kind"] == "shared"
      assert entry["installed"]["board"] == board.code
    end

    test "with tool, gives the blueprint and skills; a hidden one is an error", %{
      user: user,
      name: name
    } do
      full = user |> token_conn() |> call("list_tools", %{"tool" => name}) |> ok!()
      assert full["tool"]["board"]["folders"] == ["Config"]
      assert length(full["tool"]["skills"]) == 2
      assert full["tool"]["listing"]["this_version"] == "not requested"

      stranger = user_fixture("mcp-list-stranger@example.com")

      assert stranger |> token_conn() |> call("list_tools", %{"tool" => name}) |> error!() =~
               "no Tool"

      listed = stranger |> token_conn() |> call("list_tools", %{}) |> ok!()
      refute Enum.any?(listed["tools"], &(&1["name"] == name))
    end
  end

  describe "list_tools with file (#1156)" do
    test "gives one file's text from the latest version, or the version asked for", %{
      user: user,
      name: name
    } do
      path = "skills/#{name}/SKILL.md"

      first =
        user |> token_conn() |> call("list_tools", %{"tool" => name, "file" => path}) |> ok!()

      assert first["tool"] == name
      assert first["version"] == "1.0.0"
      assert first["path"] == path
      assert first["text"] =~ "Run it."

      assert first["sha256"] ==
               :crypto.hash(:sha256, first["text"]) |> Base.encode16(case: :lower)

      assert first["size"] == byte_size(first["text"])

      body = "---\nname: #{name}\ndescription: Better.\n---\n\nRun it better."
      {:ok, _} = Tools.publish(user, package(name, "1.1.0", %{path => body}))

      latest =
        user |> token_conn() |> call("list_tools", %{"tool" => name, "file" => path}) |> ok!()

      assert latest["version"] == "1.1.0"
      assert latest["text"] =~ "Run it better."

      old =
        user
        |> token_conn()
        |> call("list_tools", %{"tool" => name, "file" => "/" <> path, "version" => "1.0.0"})
        |> ok!()

      assert old["version"] == "1.0.0"
      assert old["path"] == path
      refute old["text"] =~ "better"
    end

    test "a path that isn't in the package is an error naming it", %{user: user, name: name} do
      text =
        user
        |> token_conn()
        |> call("list_tools", %{"tool" => name, "file" => "files/nope.md"})
        |> error!()

      assert text =~ "has no file files/nope.md"
    end

    test "a file that isn't text, or is too big to read here, points at the API", %{user: user} do
      name = unique_name()
      big = String.duplicate("a", 200_001)

      {:ok, _} =
        Tools.publish(
          user,
          package(name, "1.0.0", %{
            "skills/#{name}/logo.png" => <<137, 80, 78, 71, 255, 254>>,
            "skills/#{name}/big.md" => big
          })
        )

      binary =
        user
        |> token_conn()
        |> call("list_tools", %{"tool" => name, "file" => "skills/#{name}/logo.png"})
        |> error!()

      assert binary =~ "not text"
      assert binary =~ "/api/tools/#{name}/files/skills/#{name}/logo.png?version=1.0.0"

      too_big =
        user
        |> token_conn()
        |> call("list_tools", %{"tool" => name, "file" => "skills/#{name}/big.md"})
        |> error!()

      assert too_big =~ "too big"
      assert too_big =~ "/api/tools/#{name}/files/skills/#{name}/big.md"
    end

    test "file needs tool, and a hidden Tool's file reads as no Tool at all",
         %{name: name} = ctx do
      assert ctx.user |> token_conn() |> call("list_tools", %{"file" => "tool.json"}) |> error!() =~
               "file, skill, link and package need tool"

      stranger = user_fixture("mcp-file-stranger@example.com")

      assert stranger
             |> token_conn()
             |> call("list_tools", %{"tool" => name, "file" => "tool.json"})
             |> error!() =~ "no Tool you can see"
    end
  end

  describe "list_tools with skill and link (#1158)" do
    defp curl_get(url), do: get(build_conn(), URI.parse(url).path)

    defp list(user, args, opts \\ []),
      do: user |> token_conn(opts) |> call("list_tools", args)

    test "skill gives its SKILL.md; with file, a path in its folder, local files included", %{
      user: user,
      name: name
    } do
      skill_md = list(user, %{"tool" => name, "skill" => name}) |> ok!()
      assert skill_md["path"] == "skills/#{name}/SKILL.md"
      assert skill_md["version"] == "1.0.0"
      assert skill_md["text"] =~ "Run it."

      ref =
        list(user, %{"tool" => name, "skill" => name, "file" => "references/notes.md"}) |> ok!()

      assert ref["path"] == "skills/#{name}/references/notes.md"
      assert ref["text"] == "Notes."

      # helper.sh is declared `local` beside the skill, so it lives under files/.
      local = list(user, %{"tool" => name, "skill" => name, "file" => "helper.sh"}) |> ok!()
      assert local["path"] == "files/helper.sh"
      assert local["text"] =~ "echo hi"

      other = list(user, %{"tool" => name, "skill" => "#{name}-setup"}) |> ok!()
      assert other["text"] =~ "Call install_tool."
    end

    test "an unknown skill, a missing file in it, and skill or link without tool are errors", %{
      user: user,
      name: name
    } do
      assert list(user, %{"tool" => name, "skill" => "nope"}) |> error!() =~
               "has no skill nope"

      assert list(user, %{"tool" => name, "skill" => name, "file" => "references/x.md"})
             |> error!() =~ "has no file skills/#{name}/references/x.md"

      assert list(user, %{"skill" => name}) |> error!() =~ "need tool"
      assert list(user, %{"link" => true}) |> error!() =~ "need tool"
      assert list(user, %{"tool" => name, "link" => "maybe"}) |> error!() =~ "true or false"
    end

    test "link with neither gives the skills archive, once, without a token", %{
      user: user,
      name: name
    } do
      answer = list(user, %{"tool" => name, "link" => true}) |> ok!()
      assert answer["filename"] == "#{name}-skills.tar.gz"
      assert answer["download_url"] =~ ~r"/api/download/[\w-]{40,}\z"
      assert answer["curl"] == "curl -fsSo #{name}-skills.tar.gz #{answer["download_url"]}"
      refute Map.has_key?(answer, "text")

      conn = curl_get(answer["download_url"])
      bytes = response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["application/gzip"]
      assert get_resp_header(conn, "x-tool-version") == ["1.0.0"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      {:ok, entries} = :erl_tar.extract({:binary, bytes}, [:compressed, :memory])
      names = Enum.map(entries, fn {n, _} -> to_string(n) end)
      assert "#{name}/SKILL.md" in names
      assert "#{name}/helper.sh" in names
      assert "#{name}-setup/SKILL.md" in names

      assert json_response(curl_get(answer["download_url"]), 410)["error"] =~ "link_gone"
    end

    test "package gives a link to the whole package, every file at its path", %{
      user: user,
      name: name
    } do
      answer = list(user, %{"tool" => name, "package" => true}) |> ok!()
      assert answer["filename"] == "#{name}-1.0.0.tar.gz"
      assert answer["version"] == "1.0.0"

      conn = curl_get(answer["download_url"])
      assert get_resp_header(conn, "content-type") == ["application/gzip"]
      {:ok, entries} = :erl_tar.extract({:binary, response(conn, 200)}, [:compressed, :memory])

      assert entries |> Enum.map(&to_string(elem(&1, 0))) |> Enum.sort() ==
               files(name) |> Map.keys() |> Enum.sort()

      assert json_response(curl_get(answer["download_url"]), 410)["error"] =~ "link_gone"
    end

    test "package with file or skill, or without tool, is an error", %{user: user, name: name} do
      assert list(user, %{"package" => true}) |> error!() =~ "package need tool"

      for extra <- [%{"file" => "tool.json"}, %{"skill" => name}] do
        assert list(user, Map.merge(%{"tool" => name, "package" => true}, extra)) |> error!() =~
                 "leave out file and skill"
      end

      assert list(user, %{"tool" => name, "package" => "yes"}) |> error!() =~ "true or false"

      stranger = user_fixture("mcp-package-stranger@example.com")

      assert list(stranger, %{"tool" => name, "package" => true}) |> error!() =~
               "no Tool you can see"
    end

    test "link with skill gives its claude.ai zip; with file, the file's bytes", %{
      user: user
    } do
      name = unique_name()
      png = <<137, 80, 78, 71, 255, 254>>
      {:ok, _} = Tools.publish(user, package(name, "1.0.0", %{"skills/#{name}/logo.png" => png}))

      zip = list(user, %{"tool" => name, "skill" => name, "link" => true}) |> ok!()
      assert zip["filename"] == "#{name}.zip"
      assert zip["skill"] == name
      conn = curl_get(zip["download_url"])
      {:ok, files} = :zip.unzip(response(conn, 200), [:memory])
      assert {_, skill_md} = List.keyfind(files, ~c"#{name}/SKILL.md", 0)
      assert skill_md =~ "Run it."

      # Binary isn't read as text, and the refusal offers the link.
      assert list(user, %{"tool" => name, "file" => "skills/#{name}/logo.png"}) |> error!() =~
               "fetch it with link: true"

      file =
        list(user, %{"tool" => name, "skill" => name, "file" => "logo.png", "link" => true})
        |> ok!()

      assert file["path"] == "skills/#{name}/logo.png"
      assert file["filename"] == "logo.png"
      assert file["sha256"] == :crypto.hash(:sha256, png) |> Base.encode16(case: :lower)
      assert response(curl_get(file["download_url"]), 200) == png

      assert list(user, %{"tool" => name, "file" => "nope.md", "link" => true}) |> error!() =~
               "has no file nope.md"

      assert list(user, %{"tool" => name, "skill" => "nope", "link" => true}) |> error!() =~
               "has no skill nope"
    end

    test "a read-only token may have one, and it keeps the version it was made for", %{
      user: user,
      name: name
    } do
      answer =
        list(user, %{"tool" => name, "file" => "files/guide.md", "link" => true}, scope: "read")
        |> ok!()

      {:ok, _} = Tools.publish(user, package(name, "1.1.0", %{"files/guide.md" => "Newer."}))

      conn = curl_get(answer["download_url"])
      assert response(conn, 200) == "A guide for the board."
      assert get_resp_header(conn, "x-tool-version") == ["1.0.0"]
    end

    test "access is the Tool page's, checked again when the link is used", %{
      user: user,
      name: name,
      tool: tool
    } do
      stranger = user_fixture("mcp-link-stranger@example.com")

      assert list(stranger, %{"tool" => name, "link" => true}) |> error!() =~
               "no Tool you can see"

      friend = user_fixture("mcp-link-friend@example.com")
      {:ok, grant} = Tools.share(user, tool, friend)
      answer = list(friend, %{"tool" => name, "link" => true}) |> ok!()

      {:ok, _} = Tools.unshare(user, tool, grant.id)
      assert json_response(curl_get(answer["download_url"]), 404)

      # Refused, not spent: shared again before it expires, the same link works.
      {:ok, _} = Tools.share(user, tool, friend)
      assert response(curl_get(answer["download_url"]), 200)
    end

    test "somebody who sees it by its listing gets links to the listed version only", %{
      user: user,
      name: name,
      tool: tool
    } do
      admin =
        "mcp-link-admin@example.com"
        |> user_fixture()
        |> Ecto.Changeset.change(admin: true)
        |> Repo.update!()

      v1 = Tools.visible_version(user, tool)
      {:ok, _} = Tools.request_listing(user, v1)
      {:ok, _} = Tools.approve_listing(admin, Repo.reload(v1))
      {:ok, _} = Tools.publish(user, package(name, "2.0.0"))

      reader = user_fixture("mcp-link-reader@example.com")
      answer = list(reader, %{"tool" => name, "skill" => name, "link" => true}) |> ok!()
      assert answer["version"] == "1.0.0"
      assert get_resp_header(curl_get(answer["download_url"]), "x-tool-version") == ["1.0.0"]

      assert list(reader, %{"tool" => name, "version" => "2.0.0", "link" => true}) |> error!() =~
               "no Tool you can see"
    end
  end
end
