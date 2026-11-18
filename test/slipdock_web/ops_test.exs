defmodule SlipdockWeb.OpsTest do
  @moduledoc """
  An operation defined once (`SlipdockWeb.Ops.MoveCard`) is the
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

  test "with no index, REST and MCP both put the card at the bottom", ctx do
    ctx.conn
    |> post("/api/cards/#{ctx.a.id}/move", %{column: ctx.doing.name})
    |> json_response(200)

    {false, _} = mcp(ctx.conn, "move_card", %{card: ctx.b.id, column: ctx.doing.name})

    assert titles(ctx.doing) == ["A", "B"]
  end

  test "REST and MCP answer the same move with the same JSON", ctx do
    # The same move twice (A to the top of Doing): the second changes nothing,
    # so the two answers are the same card, word for word.
    rest =
      ctx.conn
      |> post("/api/cards/#{ctx.a.id}/move", %{column: ctx.doing.name, index: "top"})
      |> json_response(200)

    {false, via_mcp} =
      mcp(ctx.conn, "move_card", %{card: ctx.a.id, column: ctx.doing.name, index: "top"})

    assert rest["card"]["column_id"] == ctx.doing.id
    assert Map.delete(via_mcp["card"], "updated_at") == Map.delete(rest["card"], "updated_at")
    assert Map.keys(via_mcp) == Map.keys(rest)
  end

  test "to another board, REST and MCP both answer {card, moved}", ctx do
    other = board_fixture(%{"name" => "Elsewhere", "code" => "ops3185b"}, owner: ctx.user)
    [target | _] = other.columns

    rest =
      ctx.conn
      |> post("/api/cards/#{ctx.a.id}/move", %{board: other.code, column: target.name})
      |> json_response(200)

    {false, via_mcp} =
      mcp(ctx.conn, "move_card", %{card: ctx.b.id, board: other.code, column: target.name})

    assert rest["card"]["board_id"] == other.id
    assert via_mcp["card"]["board_id"] == other.id
    assert via_mcp["moved"] == rest["moved"]
  end

  defp titles(column) do
    import Ecto.Query

    Slipdock.Repo.all(
      from(c in Slipdock.Boards.Card,
        where: c.column_id == ^column.id and is_nil(c.archived_at),
        order_by: c.position,
        select: c.title
      )
    )
  end

  test "REST (400) and MCP refuse a bad index with the same words, and nothing moves", ctx do
    for bad <- ["middle", 1.5, -1, true] do
      %{"error" => rest} =
        ctx.conn
        |> post("/api/cards/#{ctx.a.id}/move", %{column: ctx.doing.name, index: bad})
        |> json_response(400)

      assert rest =~ "index must be top, bottom or a place in the list"

      assert {true, ^rest} =
               mcp(ctx.conn, "move_card", %{card: ctx.a.id, column: ctx.doing.name, index: bad})
    end

    assert titles(ctx.doing) == []
  end

  test "MCP refuses the old `position` and names `index`, rather than ignoring it", ctx do
    assert {true, text} =
             mcp(ctx.conn, "move_card", %{card: ctx.a.id, column: ctx.doing.name, position: "top"})

    assert text =~ ~s(no argument "position")
    assert text =~ "index"
    assert titles(ctx.doing) == []
  end

  test "a card that isn't there is a 404 on REST and a refusal on MCP", ctx do
    assert ctx.conn |> post("/api/cards/999999999/move", %{}) |> json_response(404)
    assert {true, text} = mcp(ctx.conn, "move_card", %{card: 999_999_999})
    assert is_binary(text)
  end

  test "the guide's reference line comes from the definition" do
    reference = Ops.reference()

    assert reference[{"POST", "/api/cards/:id/move"}] ==
             "move_card: takes column, index (default bottom), board; needs write on the card"

    # Required, a default and a ceiling are each said; the path's params are the path's.
    assert reference[{"GET", "/api/boards/:board/activity"}] =~
             "takes card, limit (default 30, at most 200), view (default log), since;"

    assert reference[{"POST", "/api/notes"}] ==
             "quick_note: takes text (required); needs write on the wiki"

    assert reference[{"DELETE", "/api/boards/:board"}] ==
             "delete_board: no params; needs to own the board"

    assert map_size(reference) == length(Ops.all())
  end

  test "the guide's Every endpoint list gives a defined route its definition's line (#3191)" do
    [_, section] = String.split(SlipdockWeb.APIGuide.markdown(), "\n## Every endpoint\n")
    [section | _] = String.split(section, "\n## ", parts: 2)

    assert section =~
             "    POST   /api/cards/:id/move\n" <>
               "           move_card: takes column, index (default bottom), board; needs write on the card\n"

    # Under the route, wrapped to stay readable in the code block.
    assert section =~
             "    POST   /api/cards/:id/handoff\n" <>
               "           leave_handoff: takes next_step, body, clear (default false), delete (default false);\n" <>
               "           needs comment on the card\n"

    under = for line <- String.split(section, "\n"), line =~ ~r/^ {11}\S/, do: line
    assert Enum.all?(under, &(String.length(&1) <= 99))

    # A route no operation is defined for is its verb and path alone.
    assert section =~ "    POST   /api/cards/:id/copy\n    POST"

    for {{verb, path}, line} <- Ops.reference() do
      first = line |> String.split(" ") |> hd()
      assert section =~ "#{String.pad_trailing(verb, 7)}#{path}\n           #{first} "
    end
  end

  # Regenerate with OPS_MANIFEST=write mix test test/slipdock_web/ops_test.exs
  test "the CLI's manifest is the definitions as they are now" do
    if System.get_env("OPS_MANIFEST") == "write", do: File.write!(@manifest, Ops.manifest_json())
    assert File.read!(@manifest) == Ops.manifest_json()
  end
end
