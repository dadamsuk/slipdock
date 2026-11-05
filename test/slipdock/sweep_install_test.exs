defmodule Slipdock.SweepInstallTest do
  @moduledoc """
  Installing the built-in Sweep Tool over MCP (`install_tool` with
  `tool: "sweep"` and `board`) and REST (`POST /api/tools/sweep/install`),
  onto a board that exists (#1793); and the docs that say how.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Handbook, Sweep}

  defp token_conn(user) do
    {token, _} = Accounts.create_api_token(user, "agent")

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp mcp(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "install_tool", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  describe "install_tool over MCP" do
    test "installs on the board, then finds it again", %{user: user} do
      board = board_fixture(%{}, owner: user)

      first = user |> token_conn() |> mcp(%{"tool" => "sweep", "board" => board.code})
      assert first["isError"] == false, inspect(first["content"])
      assert first["structuredContent"]["board"] == board.code
      assert first["structuredContent"]["created"] == true
      assert first["structuredContent"]["added"]["lists"] == ["Triage"]
      assert first["structuredContent"]["added"]["pages"] == ["Sweeps"]
      assert Sweep.find(board)
      # The sweep is not the handbook.
      assert Handbook.find(board) == nil

      again = user |> token_conn() |> mcp(%{"tool" => "sweep", "board" => board.code})
      assert again["structuredContent"]["created"] == false
      assert again["structuredContent"]["added"]["pages"] == []
      assert again["structuredContent"]["added"]["cards"] == []
    end

    test "without a board it says to give one", %{user: user} do
      result = user |> token_conn() |> mcp(%{"tool" => "sweep"})
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "the sweep installs onto a board: give board"
    end

    test "a reader can't install one", %{user: user} do
      other = user_fixture("sweep-owner@example.com")
      board = board_fixture(%{}, owner: other)
      {:ok, _} = Slipdock.Access.grant(board, user, "read", other)

      result = user |> token_conn() |> mcp(%{"tool" => "sweep", "board" => board.code})
      assert result["isError"] == true
      assert Sweep.find(board) == nil
    end

    test "the handbook still installs as before", %{user: user} do
      board = board_fixture(%{}, owner: user)
      result = user |> token_conn() |> mcp(%{"tool" => "handbook", "board" => board.code})
      assert result["isError"] == false
      assert Handbook.find(board)
      assert Sweep.find(board) == nil
    end
  end

  describe "POST /api/tools/sweep/install" do
    test "201 then 200, on the board given", %{user: user} do
      board = board_fixture(%{}, owner: user)

      first =
        user
        |> token_conn()
        |> post("/api/tools/sweep/install", %{"board" => board.code})
        |> json_response(201)

      assert first["install"]["board"] == board.code
      assert first["install"]["installed_version"] == Sweep.version()

      user
      |> token_conn()
      |> post("/api/tools/sweep/install", %{"board" => board.code})
      |> json_response(200)
    end

    test "422 without a board", %{user: user} do
      assert %{"error" => error} =
               user
               |> token_conn()
               |> post("/api/tools/sweep/install", %{})
               |> json_response(422)

      assert inspect(error) =~ "the sweep installs onto a board: give board"
    end

    test "404 on a board the caller can't see", %{user: user} do
      other = user_fixture("sweep-other@example.com")
      board = board_fixture(%{}, owner: other)

      conn = user |> token_conn() |> post("/api/tools/sweep/install", %{"board" => board.code})
      assert conn.status in [403, 404]
      assert Sweep.find(board) == nil
    end
  end

  describe "the docs" do
    test "the guide says how to install it and never to take work from Triage" do
      guide = SlipdockWeb.APIGuide.markdown()
      assert guide =~ "### Code sweeps"
      assert {:ok, section} = SlipdockWeb.APIGuide.section("handbook", [])
      assert section =~ "### Code sweeps"
      assert guide =~ "slipdock tools install-board sweep --board"
      assert guide =~ "Never take work from a Triage list"
    end

    test "the manual, tool-packages, agents.md and both skills say so" do
      assert File.read!("docs/manual.md") =~ "**The code sweep**"
      assert File.read!("docs/manual.md") =~ "**A Triage list is never fed.**"
      assert File.read!("docs/tool-packages.md") =~ "`triage`"
      assert File.read!("docs/agents.md") =~ "Triage"

      assert File.read!("priv/skills/slipdock-loop/SKILL.md") =~
               "Never take a card from a **Triage** list"

      assert File.read!("priv/skills/slipdock/SKILL.md") =~ "install-board sweep --board B"
    end

    test "the MCP tool's description names it" do
      assert SlipdockWeb.MCP.Tools.InstallTool.description() =~ ~s(tool: "sweep")
    end
  end
end
