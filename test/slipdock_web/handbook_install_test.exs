defmodule SlipdockWeb.HandbookInstallTest do
  @moduledoc """
  Installing the built-in Handbook Tool over MCP (`install_tool` with
  `tool: "handbook"` and `board`) and REST (`POST /api/tools/handbook/install`)
  — onto a board that exists, never a new one (#1262).
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Handbook}

  defp token_conn(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

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

      first = user |> token_conn() |> mcp(%{"tool" => "handbook", "board" => board.code})
      assert first["isError"] == false, inspect(first["content"])
      assert first["structuredContent"]["board"] == board.code
      assert first["structuredContent"]["created"] == true
      assert "Index" in first["structuredContent"]["added"]["pages"]
      assert Handbook.find(board)

      again = user |> token_conn() |> mcp(%{"tool" => "handbook", "board" => board.code})
      assert again["structuredContent"]["created"] == false
      assert again["structuredContent"]["added"]["pages"] == []
    end

    test "without a board it says to give one", %{user: user} do
      result = user |> token_conn() |> mcp(%{"tool" => "handbook"})
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "give board"
    end

    test "a reader can't install one", %{user: user} do
      other = user_fixture("handbook-owner@example.com")
      board = board_fixture(%{}, owner: other)
      {:ok, _} = Slipdock.Access.grant(board, user, "read", other)

      result = user |> token_conn() |> mcp(%{"tool" => "handbook", "board" => board.code})
      assert result["isError"] == true
      assert Handbook.find(board) == nil
    end
  end

  describe "POST /api/tools/handbook/install" do
    test "201 then 200, on the board given", %{user: user} do
      board = board_fixture(%{}, owner: user)

      first =
        user
        |> token_conn()
        |> post("/api/tools/handbook/install", %{"board" => board.code})
        |> json_response(201)

      assert first["install"]["board"] == board.code
      assert first["install"]["installed_version"] == Handbook.version()

      user
      |> token_conn()
      |> post("/api/tools/handbook/install", %{"board" => board.code})
      |> json_response(200)
    end

    test "422 without a board", %{user: user} do
      assert %{"error" => error} =
               user
               |> token_conn()
               |> post("/api/tools/handbook/install", %{})
               |> json_response(422)

      assert inspect(error) =~ "give board"
    end
  end
end
