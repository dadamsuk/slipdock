defmodule SlipdockWeb.Ops.InstallToolTest do
  @moduledoc """
  `install_tool` defined once (#3188): REST's `POST /api/tools/:slug/install`
  and the MCP tool build a Tool's board alike, take the new board's `name`,
  answer `{install}`, and refuse the same calls in the same words.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Accounts, Tools}

  setup %{user: user} do
    Slipdock.TestConfig.own_uploads_dir()
    name = unique_name()
    {:ok, _} = Tools.publish(user, package(name))
    %{name: name}
  end

  defp token_conn(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "ops", opts)
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  test "the MCP tool is the definition: name, not board_name" do
    tool = SlipdockWeb.MCP.Tools.InstallTool
    assert tool.__op__() == SlipdockWeb.Ops.InstallTool
    assert tool.input_schema().required == ["tool"]

    assert Map.keys(tool.input_schema().properties) |> Enum.sort() == [
             :board,
             :name,
             :tool,
             :version
           ]
  end

  test "REST (201) and MCP build it alike and answer {install}", %{user: user, name: name} do
    rest =
      user
      |> token_conn()
      |> post("/api/tools/#{name}/install", %{name: "Mine"})
      |> json_response(201)

    assert %{"install" => %{"board_name" => "Mine", "created" => true}} = rest

    # Installed already: the same board back, created false, on both.
    again = user |> token_conn() |> post("/api/tools/#{name}/install", %{}) |> json_response(200)
    assert {false, ^again} = call_mcp_tool(token_conn(user), "install_tool", %{tool: name})
    assert again["install"]["board"] == rest["install"]["board"]
    assert again["install"]["created"] == false
  end

  test "MCP refuses the old board_name and names name", %{user: user, name: name} do
    boards = Slipdock.Repo.aggregate(Slipdock.Boards.Board, :count)

    assert {true, text} =
             call_mcp_tool(token_conn(user), "install_tool", %{tool: name, board_name: "Mine"})

    assert text =~ ~s(no argument "board_name")
    assert text =~ "name"
    assert Slipdock.Repo.aggregate(Slipdock.Boards.Board, :count) == boards
  end

  test "a missing version and a confined token are refused in the same words",
       %{user: user, name: name} do
    board = board_fixture(%{}, owner: user)

    for {conn, args, status} <- [
          {token_conn(user), %{version: "3.0.0"}, 404},
          {token_conn(user, scope_boards: [board.id]), %{}, 403}
        ] do
      %{"error" => rest} =
        conn |> post("/api/tools/#{name}/install", args) |> json_response(status)

      assert {true, mcp} = call_mcp_tool(conn, "install_tool", Map.put(args, :tool, name))

      if status == 404,
        do: assert(mcp =~ "version 3.0.0 of Tool" and rest =~ "version 3.0.0 of Tool"),
        else: assert(mcp == rest)
    end
  end

  test "the handbook without a board is refused alike (422)", %{user: user} do
    %{"error" => rest} =
      user |> token_conn() |> post("/api/tools/handbook/install", %{}) |> json_response(422)

    assert {true, ^rest} = call_mcp_tool(token_conn(user), "install_tool", %{tool: "handbook"})
    assert rest =~ "give board"
  end
end
