defmodule SlipdockWeb.Ops.DeleteBoardTest do
  @moduledoc """
  `delete_board` defined once (#3187): REST and MCP delete alike and answer
  `{ok, board, code, name}`, both refuse a subcard's board and a board the
  caller doesn't own, and MCP alone asks for the board's code in `confirm`
  first.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{user: user} do
    %{
      a: board_fixture(%{"name" => "Gone A", "code" => "delb3187a"}, owner: user),
      b: board_fixture(%{"name" => "Gone B", "code" => "delb3187b"}, owner: user)
    }
  end

  test "the MCP tool is the definition, confirm and all" do
    tool = SlipdockWeb.MCP.Tools.DeleteBoard
    assert tool.__op__() == SlipdockWeb.Ops.DeleteBoard
    assert tool.input_schema().required == ["board", "confirm"]
    assert tool.destructive?()
  end

  test "REST and MCP delete alike and answer the same shape", ctx do
    rest = ctx.conn |> delete("/api/boards/#{ctx.a.code}") |> json_response(200)

    {false, via_mcp} =
      mcp_call(ctx.conn, "delete_board", %{board: ctx.b.code, confirm: "DELB3187B "})

    assert rest == %{"ok" => true, "board" => ctx.a.id, "code" => "delb3187a", "name" => "Gone A"}

    assert via_mcp == %{
             "ok" => true,
             "board" => ctx.b.id,
             "code" => "delb3187b",
             "name" => "Gone B"
           }

    assert Boards.get_board(ctx.a.id) == nil and Boards.get_board(ctx.b.id) == nil
  end

  test "MCP refuses a wrong or missing confirm, naming the code; REST doesn't ask", ctx do
    for args <- [%{}, %{confirm: "nope"}, %{confirm: true}] do
      assert {true, text} = mcp_call(ctx.conn, "delete_board", Map.put(args, :board, ctx.a.code))
      assert text =~ ~s(confirm must be the board's code, "delb3187a")
      assert text =~ "archive_board"
    end

    assert Boards.get_board(ctx.a.id)
  end

  test "a subcard's board is refused on both, in the same words", ctx do
    card = card_fixture(hd(ctx.a.columns), %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = Boards.create_sub_board(card, t)

    %{"error" => rest} = ctx.conn |> delete("/api/boards/#{sub.id}") |> json_response(422)
    assert rest =~ "goes with its card"

    assert {true, ^rest} =
             mcp_call(ctx.conn, "delete_board", %{board: sub.id, confirm: sub.code})

    assert Boards.get_board(sub.id)
  end

  test "a board the caller can see but doesn't own is refused on both", ctx do
    other = user_fixture("delb.stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "delb3187c"}, owner: other)
    share_fixture(theirs, ctx.user, "write")

    %{"error" => rest} = ctx.conn |> delete("/api/boards/#{theirs.code}") |> json_response(403)

    assert {true, ^rest} =
             mcp_call(ctx.conn, "delete_board", %{board: theirs.code, confirm: theirs.code})

    assert Boards.get_board(theirs.id)
  end
end
