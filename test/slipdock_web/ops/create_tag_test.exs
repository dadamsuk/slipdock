defmodule SlipdockWeb.Ops.CreateTagTest do
  @moduledoc """
  `create_tag` defined once (#3187): REST's `POST /api/boards/:board/tags`
  and the MCP tool make a tag alike, answer `{tag, created}`, hand back the
  one already there by that name (in any case) rather than a second, and
  refuse the same calls in the same words.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{user: user} do
    %{board: board_fixture(%{"name" => "Tags", "code" => "tag3187"}, owner: user)}
  end

  defp names(board), do: board.id |> Boards.Tags.list_tags() |> Enum.map(& &1.name) |> Enum.sort()

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.CreateTag
    assert tool.__op__() == SlipdockWeb.Ops.CreateTag
    assert tool.input_schema().required == ["board", "name"]
    assert tool.input_schema().properties.color.enum == Slipdock.Palette.names()
  end

  test "REST (201) and MCP make a tag alike, colour and all", ctx do
    rest =
      ctx.conn
      |> post("/api/boards/#{ctx.board.code}/tags", %{name: "infra", color: "red"})
      |> json_response(201)

    {false, via_mcp} =
      mcp_call(ctx.conn, "create_tag", %{board: ctx.board.code, name: "ops", color: "red"})

    assert rest["created"] == true and via_mcp["created"] == true
    assert Map.delete(via_mcp["tag"], "id") == %{Map.delete(rest["tag"], "id") | "name" => "ops"}
    assert names(ctx.board) == ["infra", "ops"]
  end

  test "a tag of that name in any case is answered as it is, not doubled (200 on REST)", ctx do
    {:ok, tag} = Boards.Tags.create_tag(ctx.board, %{"name" => "Infra"})

    rest =
      ctx.conn
      |> post("/api/boards/#{ctx.board.code}/tags", %{name: "infra"})
      |> json_response(200)

    {false, via_mcp} = mcp_call(ctx.conn, "create_tag", %{board: ctx.board.code, name: "INFRA "})

    assert rest == via_mcp
    assert rest == %{"created" => false, "tag" => SlipdockWeb.API.JSON.tag(tag) |> json()}
    assert names(ctx.board) == ["Infra"]
  end

  test "the same refusals in the same words, and nothing made", ctx do
    for args <- [%{name: "x", color: "plaid"}, %{name: " "}] do
      %{"error" => rest} =
        ctx.conn |> post("/api/boards/#{ctx.board.code}/tags", args) |> json_response(400)

      assert {true, ^rest} =
               mcp_call(ctx.conn, "create_tag", Map.put(args, :board, ctx.board.code))
    end

    # A changeset's refusal: REST's details, MCP's sentence, the same words.
    long = %{name: String.duplicate("x", 31)}

    %{"details" => %{"name" => [rest]}} =
      ctx.conn |> post("/api/boards/#{ctx.board.code}/tags", long) |> json_response(422)

    assert {true, text} = mcp_call(ctx.conn, "create_tag", Map.put(long, :board, ctx.board.code))
    assert text == "not saved: name #{rest}."

    assert names(ctx.board) == []
  end

  test "someone else's board is refused on both", ctx do
    other = user_fixture("tag.stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "tag3187b"}, owner: other)

    assert ctx.conn |> post("/api/boards/#{theirs.code}/tags", %{name: "x"}) |> json_response(404)
    assert {true, text} = mcp_call(ctx.conn, "create_tag", %{board: theirs.code, name: "x"})
    assert text =~ "no board"
    assert names(theirs) == []
  end

  defp json(map), do: map |> Jason.encode!() |> Jason.decode!()
end
