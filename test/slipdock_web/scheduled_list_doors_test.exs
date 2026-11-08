defmodule SlipdockWeb.ScheduledListDoorsTest do
  @moduledoc """
  The Scheduled list's category (#2100) over the web doors: set and read
  over REST and MCP, and named in the board JSON beside the ready and done
  lists. (The CLI's are in `cli/test/scheduled_list_test.exs`.)
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Agents", "code" => unique_code()}, owner: user)
    %{conn: put_req_header(conn, "accept", "application/json"), board: board, code: board.code}
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

  describe "REST" do
    test "a list is made Scheduled, read back, and changed away", %{conn: conn, board: board} do
      created =
        conn
        |> post(~p"/api/boards/#{board.id}/columns", %{
          "name" => "Scheduled",
          "category" => "scheduled"
        })
        |> json_response(201)

      assert %{"id" => id, "category" => "scheduled"} = created["column"]
      assert Boards.scheduled_column(board).id == id

      shown = conn |> get(~p"/api/boards/#{board.id}") |> json_response(200)

      assert %{"category" => "scheduled"} =
               Enum.find(shown["board"]["columns"], &(&1["id"] == id))

      changed =
        conn
        |> patch(~p"/api/boards/#{board.id}/columns/#{id}", %{"category" => "todo"})
        |> json_response(200)

      assert changed["column"]["category"] == "todo"
      assert Boards.scheduled_column(board) == nil
    end

    test "an existing list can be given the category", %{conn: conn, board: board} do
      [backlog | _] = board.columns

      conn
      |> patch(~p"/api/boards/#{board.id}/columns/#{backlog.id}", %{"category" => "scheduled"})
      |> json_response(200)

      assert Boards.scheduled_column(board).id == backlog.id
    end
  end

  describe "MCP" do
    test "create_list takes the category, and offers it", %{conn: conn, board: board, code: code} do
      result =
        conn
        |> call("create_list", %{board: code, name: "Scheduled", category: "scheduled"})
        |> ok!()

      assert result["list"]["name"] == "Scheduled"
      assert Boards.scheduled_column(board).name == "Scheduled"

      schema = SlipdockWeb.MCP.Tools.CreateList.input_schema()
      assert "scheduled" in schema.properties.category.enum
      assert SlipdockWeb.MCP.Tools.CreateList.description() =~ "scheduled"
    end

    test "list_boards names the Scheduled list beside the ready and done lists",
         %{conn: conn, board: board} do
      {:ok, _} = Boards.create_column(board, %{"name" => "Nightly", "category" => "scheduled"})

      boards = conn |> call("list_boards", %{}) |> ok!() |> Map.fetch!("boards")
      mine = Enum.find(boards, &(&1["id"] == board.id))

      assert mine["ready"] == "To Do"
      assert mine["done"] == "Done"
      assert mine["scheduled"] == "Nightly"
      assert %{"category" => "scheduled"} = Enum.find(mine["lists"], &(&1["name"] == "Nightly"))
    end

    test "list_boards gives no Scheduled list on a board without one", %{conn: conn, board: board} do
      boards = conn |> call("list_boards", %{}) |> ok!() |> Map.fetch!("boards")
      assert Enum.find(boards, &(&1["id"] == board.id))["scheduled"] == nil
    end

    test "get_board gives the list its role", %{conn: conn, board: board, code: code} do
      {:ok, _} = Boards.create_column(board, %{"name" => "Scheduled", "category" => "scheduled"})

      lists = conn |> call("get_board", %{board: code}) |> ok!() |> Map.fetch!("lists")
      assert %{"role" => "scheduled"} = Enum.find(lists, &(&1["name"] == "Scheduled"))
      assert %{"role" => "ready"} = Enum.find(lists, &(&1["name"] == "To Do"))
    end
  end

  test "the guide over REST says never to take work from it", %{conn: conn, board: board} do
    {:ok, _} = Boards.create_column(board, %{"name" => "Scheduled", "category" => "scheduled"})
    guide = conn |> get(~p"/api/guide") |> response(200)
    assert guide =~ "Scheduled (scheduled: worked by feed rules, never take work from it"
    assert guide =~ "Never take work from a Scheduled list"
  end
end
