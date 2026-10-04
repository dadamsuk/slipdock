defmodule SlipdockWeb.API.BoardPartsTest do
  # The pieces a board is made of, through the API: its lists, fields,
  # milestones and tags, its activity, and the board itself going away.
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Parts"}, owner: user)
    %{conn: put_req_header(conn, "accept", "application/json"), board: board}
  end

  describe "lists" do
    test "listing counts each list's cards", %{conn: conn, board: board} do
      card_fixture(hd(board.columns), %{"title" => "One"})

      columns = conn |> get(~p"/api/boards/#{board.id}/columns") |> json_response(200)

      assert [%{"name" => "Backlog", "cards" => 1} | rest] = columns["columns"]
      assert Enum.all?(rest, &(&1["cards"] == 0))
    end

    test "create, rename and delete", %{conn: conn, board: board} do
      created =
        conn
        |> post(~p"/api/boards/#{board.id}/columns", %{"name" => "Review", "wip_limit" => 3})
        |> json_response(201)

      assert %{"id" => id, "name" => "Review", "wip_limit" => 3} = created["column"]

      renamed =
        conn
        |> patch(~p"/api/boards/#{board.id}/columns/#{id}", %{"name" => "QA"})
        |> json_response(200)

      assert renamed["column"]["name"] == "QA"

      assert %{"ok" => true} =
               conn |> delete(~p"/api/boards/#{board.id}/columns/#{id}") |> json_response(200)

      refute Enum.any?(Boards.get_board!(board.id).columns, &(&1.id == id))
    end

    test "a list's category is set on create and update, and cleared with an empty one",
         %{conn: conn, board: board} do
      created =
        conn
        |> post(~p"/api/boards/#{board.id}/columns", %{
          "name" => "Parked",
          "category" => "dropped"
        })
        |> json_response(201)

      assert %{"id" => id, "category" => "dropped"} = created["column"]

      path = ~p"/api/boards/#{board.id}/columns/#{id}"
      assert conn |> patch(path, %{"category" => "todo"}) |> json_response(200)
      assert {:ok, %{category: "todo"}} = Boards.find_column(board, id)

      assert %{"column" => %{"category" => nil}} =
               conn |> patch(path, %{"category" => ""}) |> json_response(200)
    end

    test "an unknown category is refused, not ignored", %{conn: conn, board: board} do
      column = hd(board.columns)

      assert %{"details" => %{"category" => [_]}} =
               conn
               |> patch(~p"/api/boards/#{board.id}/columns/#{column.id}", %{"category" => "bogus"})
               |> json_response(422)

      assert {:ok, %{category: category}} = Boards.find_column(board, column.id)
      assert category == column.category
    end

    test "a list on another board is not found", %{conn: conn, board: board, user: user} do
      other = board_fixture(%{}, owner: user)
      column = hd(other.columns)

      assert conn
             |> patch(~p"/api/boards/#{board.id}/columns/#{column.id}", %{"name" => "X"})
             |> json_response(404)

      assert Boards.get_board!(other.id).columns |> hd() |> Map.get(:name) == column.name
    end

    test "a list with no name is refused", %{conn: conn, board: board} do
      assert %{"details" => %{"name" => [_]}} =
               conn
               |> post(~p"/api/boards/#{board.id}/columns", %{"name" => ""})
               |> json_response(422)
    end
  end

  describe "fields" do
    test "create, list, rename and delete", %{conn: conn, board: board} do
      created =
        conn
        |> post(~p"/api/boards/#{board.id}/fields", %{
          "name" => "Story points",
          "key" => "points",
          "kind" => "number"
        })
        |> json_response(201)

      assert %{"id" => id, "key" => "points", "kind" => "number"} = created["field"]

      listed = conn |> get(~p"/api/boards/#{board.id}/fields") |> json_response(200)
      assert [%{"key" => "points"}] = listed["fields"]

      # Found by key as well as by id.
      renamed =
        conn
        |> patch(~p"/api/boards/#{board.id}/fields/points", %{"name" => "Points"})
        |> json_response(200)

      assert renamed["field"]["name"] == "Points"

      assert %{"ok" => true} =
               conn |> delete(~p"/api/boards/#{board.id}/fields/#{id}") |> json_response(200)

      assert %{"fields" => []} =
               conn |> get(~p"/api/boards/#{board.id}/fields") |> json_response(200)
    end

    test "an unknown field is not found", %{conn: conn, board: board} do
      assert conn
             |> patch(~p"/api/boards/#{board.id}/fields/nope", %{"name" => "X"})
             |> json_response(404)

      assert conn |> delete(~p"/api/boards/#{board.id}/fields/nope") |> json_response(404)
    end

    test "a preset installs its inputs and its formula", %{conn: conn, board: board} do
      body =
        conn |> post(~p"/api/boards/#{board.id}/presets/rice") |> json_response(200)

      assert body["field"]["kind"] == "formula"
      keys = Enum.map(body["fields"], & &1["key"])
      assert Enum.all?(~w(reach impact confidence effort), &(&1 in keys))
    end

    test "an unknown preset is not found", %{conn: conn, board: board} do
      assert conn |> post(~p"/api/boards/#{board.id}/presets/nope") |> json_response(404)
    end
  end

  describe "milestones" do
    test "create, list and delete", %{conn: conn, board: board} do
      created =
        conn
        |> post(~p"/api/boards/#{board.id}/milestones", %{
          "name" => "Launch",
          "date" => "2026-12-01"
        })
        |> json_response(201)

      assert %{"id" => id, "name" => "Launch", "date" => "2026-12-01"} = created["milestone"]

      assert %{"milestones" => [%{"id" => ^id}]} =
               conn |> get(~p"/api/boards/#{board.id}/milestones") |> json_response(200)

      assert %{"ok" => true} =
               conn |> delete(~p"/api/boards/#{board.id}/milestones/#{id}") |> json_response(200)

      assert %{"milestones" => []} =
               conn |> get(~p"/api/boards/#{board.id}/milestones") |> json_response(200)
    end

    test "deleting one that is not there is not found", %{conn: conn, board: board} do
      assert conn |> delete(~p"/api/boards/#{board.id}/milestones/999999") |> json_response(404)
    end
  end

  describe "tags" do
    test "create, list and delete", %{conn: conn, board: board} do
      created =
        conn
        |> post(~p"/api/boards/#{board.id}/tags", %{"name" => "bug", "color" => "rose"})
        |> json_response(201)

      assert %{"id" => id, "name" => "bug", "color" => "rose"} = created["tag"]

      assert %{"tags" => [%{"name" => "bug"}]} =
               conn |> get(~p"/api/boards/#{board.id}/tags") |> json_response(200)

      assert %{"ok" => true} =
               conn |> delete(~p"/api/boards/#{board.id}/tags/#{id}") |> json_response(200)

      assert %{"tags" => []} =
               conn |> get(~p"/api/boards/#{board.id}/tags") |> json_response(200)
    end
  end

  test "activity is newest first, as many as asked for", %{conn: conn, board: board} do
    column = hd(board.columns)
    for title <- ~w(First Second Third), do: card_fixture(column, %{"title" => title})

    body = conn |> get(~p"/api/boards/#{board.id}/activity?limit=2") |> json_response(200)

    assert [newest, _] = body["activity"]
    assert newest["message"] =~ "Third"
  end

  describe "a board shared to read" do
    setup %{board: board} do
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      share_fixture(board, reader, "read")
      %{reader: conn_as(reader) |> put_req_header("accept", "application/json")}
    end

    test "can be read but not changed", %{reader: reader, board: board} do
      assert %{"columns" => [_ | _]} =
               reader |> get(~p"/api/boards/#{board.id}/columns") |> json_response(200)

      assert reader
             |> post(~p"/api/boards/#{board.id}/columns", %{"name" => "Mine"})
             |> json_response(403)

      assert reader
             |> post(~p"/api/boards/#{board.id}/tags", %{"name" => "mine"})
             |> json_response(403)

      assert reader |> post(~p"/api/boards/#{board.id}/presets/rice") |> json_response(403)
    end

    test "cannot be deleted by anyone but its owner", %{reader: reader, board: board} do
      assert reader |> delete(~p"/api/boards/#{board.id}") |> json_response(403)
      assert Boards.get_board(board.id)
    end
  end

  test "the owner deletes the board", %{conn: conn, board: board} do
    assert %{"ok" => true} = conn |> delete(~p"/api/boards/#{board.id}") |> json_response(200)
    refute Boards.get_board(board.id)
  end
end
