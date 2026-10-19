defmodule SlipdockWeb.MCP.ToolToolsTest do
  @moduledoc """
  The Tools over MCP: `install_tool` builds the board and answers with its
  code (#961), whichever client is asking.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Accounts, Tools}

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
               "file needs tool"

      stranger = user_fixture("mcp-file-stranger@example.com")

      assert stranger
             |> token_conn()
             |> call("list_tools", %{"tool" => name, "file" => "tool.json"})
             |> error!() =~ "no Tool you can see"
    end
  end
end
