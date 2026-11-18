defmodule SlipdockWeb.Ops.ActivityTest do
  @moduledoc """
  `activity` defined once (#3188): REST's `GET /api/boards/:board/activity`
  and the MCP tool answer the log alike (`{board, activity}`); REST's `GET
  /api/boards/:board/ledger` is the same definition's ledger view, and
  answers what MCP's `view: "ledger"` does; both refuse the same calls in
  the same words.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.Repo
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Activity", "code" => "act3188"}, owner: user)
    [todo | _] = board.columns
    a = card_fixture(todo, %{"title" => "First"})
    b = card_fixture(todo, %{"title" => "Second"})
    done = List.last(board.columns)
    shipped = card_fixture(done, %{"title" => "Shipped"})

    Repo.update_all(from(c in Card, where: c.id == ^shipped.id),
      set: [completed: true, completed_at: DateTime.add(DateTime.utc_now(:second), -60)]
    )

    %{board: board, a: a, b: b}
  end

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.Activity
    assert tool.__op__() == SlipdockWeb.Ops.Activity
    assert tool.input_schema().required == ["board"]
    assert tool.input_schema().properties.view.enum == ["log", "ledger"]
    assert tool.read_only?()
  end

  test "REST and MCP answer the log alike: {board, activity}, one card's with card", ctx do
    rest = ctx.conn |> get("/api/boards/#{ctx.board.code}/activity") |> json_response(200)
    assert {false, ^rest} = call_mcp_tool(ctx.conn, "activity", %{board: ctx.board.code})
    assert rest["board"] == %{"id" => ctx.board.id, "code" => "act3188", "name" => "Activity"}
    assert length(rest["activity"]) >= 2

    one =
      ctx.conn
      |> get("/api/boards/#{ctx.board.code}/activity", %{card: "##{ctx.a.id}", limit: "1"})
      |> json_response(200)

    assert {false, ^one} =
             call_mcp_tool(ctx.conn, "activity", %{
               board: ctx.board.code,
               card: ctx.a.id,
               limit: 1
             })

    assert [%{"card_id" => id}] = one["activity"]
    assert id == ctx.a.id
  end

  test "REST's ledger route is the ledger view, and answers as MCP's does", ctx do
    rest = ctx.conn |> get("/api/boards/#{ctx.board.code}/ledger") |> json_response(200)

    assert {false, ^rest} =
             call_mcp_tool(ctx.conn, "activity", %{board: ctx.board.code, view: "ledger"})

    assert ^rest =
             ctx.conn
             |> get("/api/boards/#{ctx.board.code}/activity", %{view: "ledger"})
             |> json_response(200)

    assert rest["count"] == 1
  end

  test "a bad limit, view or since is refused in the same words", ctx do
    for {path, args, status} <- [
          {"activity", %{limit: 0}, 400},
          {"activity", %{limit: "lots"}, 400},
          {"activity", %{view: "chart"}, 400},
          {"ledger", %{since: "soon"}, 422}
        ] do
      %{"error" => rest} =
        ctx.conn |> get("/api/boards/#{ctx.board.code}/#{path}", args) |> json_response(status)

      mcp_args = if path == "ledger", do: Map.put(args, :view, "ledger"), else: args

      assert {true, ^rest} =
               call_mcp_tool(ctx.conn, "activity", Map.put(mcp_args, :board, ctx.board.code))
    end
  end

  test "a limit over 200 is 200 on both, not a refusal", ctx do
    assert ctx.conn
           |> get("/api/boards/#{ctx.board.code}/activity", %{limit: "5000"})
           |> json_response(200)

    assert {false, _} = call_mcp_tool(ctx.conn, "activity", %{board: ctx.board.code, limit: 5000})
  end

  test "someone else's board is no board on either", ctx do
    theirs =
      board_fixture(%{"name" => "Theirs", "code" => "act3188x"},
        owner: user_fixture("act3188.stranger@example.com")
      )

    assert ctx.conn |> get("/api/boards/#{theirs.code}/activity") |> json_response(404)
    assert ctx.conn |> get("/api/boards/#{theirs.code}/ledger") |> json_response(404)
    assert {true, text} = call_mcp_tool(ctx.conn, "activity", %{board: theirs.code})
    assert text =~ "no board"
  end
end
