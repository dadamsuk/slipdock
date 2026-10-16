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
end
