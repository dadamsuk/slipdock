defmodule SlipdockWeb.API.NoteControllerTest do
  @moduledoc "Quick notes over the API and MCP (#1538)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Brain QA"})
    {:ok, _} = Wiki.create_folder(board, %{"name" => "Inbox"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Mind"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
    %{board: board}
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
        params: %{name: "quick_note", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "POST /api/notes saves a note and says where", %{conn: conn, board: board} do
    Slipdock.AIStub.reply_with(%{"title" => "Printers", "folder" => "Inbox"})

    note =
      conn |> post(~p"/api/notes", %{text: "ring them"}) |> json_response(201) |> Map.get("note")

    assert note["title"] =~ ~r/ Printers$/
    assert note["vault"] == "Mind"
    assert note["location"] == "/Inbox"
    assert note["placed_by"] == "ai"
    assert [%{body: "ring them"} = page] = Wiki.list_pages(board)
    assert page.code == note["code"]
  end

  test "an empty note is a 422", %{conn: conn, board: board} do
    assert %{"error" => error} = conn |> post(~p"/api/notes", %{text: " "}) |> json_response(422)
    assert error =~ "something"
    assert Wiki.list_pages(board) == []
  end

  test "text left out is a 422, not a crash", %{conn: conn} do
    assert conn |> post(~p"/api/notes", %{}) |> json_response(422)
  end

  test "the MCP tool saves one", %{conn: conn, board: board} do
    Slipdock.AIStub.reply_with(%{"title" => "Printers"})

    result = mcp(conn, %{text: "ring them"})

    assert result["isError"] == false
    assert result["structuredContent"]["note"]["location"] == "/"
    assert [%{body: "ring them"}] = Wiki.list_pages(board)
  end

  test "the MCP tool wants text", %{conn: conn} do
    assert %{"isError" => true} = mcp(conn, %{text: ""})
  end
end
