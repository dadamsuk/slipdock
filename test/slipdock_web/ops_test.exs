defmodule SlipdockWeb.OpsTest do
  @moduledoc """
  Spike #3165: an operation defined once (`SlipdockWeb.Ops.MoveCard`) is the
  same operation on every surface — the MCP tool's schema is the definition's,
  REST and MCP answer the same call with the same JSON and the same refusal,
  and the CLI's manifest (`cli/priv/ops.json`) is the definition as it is now.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias SlipdockWeb.Ops

  @manifest Path.expand("../../cli/priv/ops.json", __DIR__)

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Ops", "code" => "ops3165"}, owner: user)
    [todo, doing | _] = board.columns
    a = card_fixture(todo, %{"title" => "A"})
    b = card_fixture(todo, %{"title" => "B"})
    %{conn: conn, board: board, todo: todo, doing: doing, a: a, b: b}
  end

  defp mcp(conn, tool, args) do
    result =
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

    case result do
      %{"isError" => true, "content" => [%{"text" => text}]} -> {true, text}
      _ -> {false, mcp_data(result)}
    end
  end

  test "the MCP tool is the definition: name, schema, read-only hint" do
    tool = SlipdockWeb.MCP.Tools.MoveCard
    assert tool.name() == "move_card"
    assert tool.input_schema() == Ops.input_schema(Ops.MoveCard)
    assert tool.input_schema().required == ["card"]
    refute tool.read_only?()
  end

  test "REST and MCP answer the same move with the same JSON", ctx do
    rest =
      ctx.conn
      |> post("/api/cards/#{ctx.a.id}/move", %{column: ctx.doing.name})
      |> json_response(200)

    {false, via_mcp} = mcp(ctx.conn, "move_card", %{card: ctx.b.id, column: ctx.doing.name})

    # Both at the bottom by default: A first, then B after it.
    assert rest["card"]["column_id"] == ctx.doing.id
    assert via_mcp["card"]["column_id"] == ctx.doing.id
    assert via_mcp["card"]["position"] > rest["card"]["position"]
    assert Map.keys(rest) == Map.keys(via_mcp)
    assert Map.keys(rest["card"]) == Map.keys(via_mcp["card"])
  end

  test "REST and MCP refuse a bad index with the same words", ctx do
    %{"error" => rest} =
      ctx.conn |> post("/api/cards/#{ctx.a.id}/move", %{index: "middle"}) |> json_response(400)

    assert {true, ^rest} = mcp(ctx.conn, "move_card", %{card: ctx.a.id, index: "middle"})
  end

  test "a card that isn't there is a 404 on REST and a refusal on MCP", ctx do
    assert ctx.conn |> post("/api/cards/999999999/move", %{}) |> json_response(404)
    assert {true, text} = mcp(ctx.conn, "move_card", %{card: 999_999_999})
    assert is_binary(text)
  end

  test "the guide's reference line comes from the definition" do
    assert Ops.reference() =~
             "- `POST /api/cards/:id/move` — Moves a card to a list on its board"

    assert Ops.reference() =~ "`index` (default `bottom`)"
    assert Ops.reference() =~ "Needs write on the card."
  end

  test "the route the definition names is the router's" do
    paths = for r <- Phoenix.Router.routes(SlipdockWeb.Router), do: {r.verb, r.path}

    for op <- Ops.all(), d = op.definition() do
      assert {d.verb, d.path} in paths, "#{d.name}: no #{d.verb} #{d.path} in the router"
    end
  end

  # Regenerate with OPS_MANIFEST=write mix test test/slipdock_web/ops_test.exs
  test "the CLI's manifest is the definitions as they are now" do
    if System.get_env("OPS_MANIFEST") == "write", do: File.write!(@manifest, Ops.manifest_json())
    assert File.read!(@manifest) == Ops.manifest_json()
  end
end
