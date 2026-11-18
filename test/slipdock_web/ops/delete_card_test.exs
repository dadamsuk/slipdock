defmodule SlipdockWeb.Ops.DeleteCardTest do
  @moduledoc """
  `delete_card` defined once (#3187): REST and MCP delete alike and answer
  the same `{ok, card, title, board_id}`; MCP alone asks `confirm: true`
  first, and refuses without it before anything is looked up or deleted.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{user: user} do
    board = board_fixture(%{"name" => "Del", "code" => "del3187"}, owner: user)
    [todo | _] = board.columns
    %{a: card_fixture(todo, %{"title" => "A"}), b: card_fixture(todo, %{"title" => "B"})}
  end

  test "the MCP tool is the definition, confirm and all" do
    tool = SlipdockWeb.MCP.Tools.DeleteCard
    assert tool.__op__() == SlipdockWeb.Ops.DeleteCard
    assert tool.input_schema().required == ["card", "confirm"]
    assert tool.input_schema().properties.confirm.type == "boolean"
    assert tool.destructive?()
    refute tool.read_only?()
  end

  test "REST and MCP delete alike and answer the same shape", ctx do
    rest = ctx.conn |> delete("/api/cards/#{ctx.a.id}") |> json_response(200)
    {false, via_mcp} = call_mcp_tool(ctx.conn, "delete_card", %{card: ctx.b.id, confirm: true})

    assert rest == %{
             "ok" => true,
             "card" => ctx.a.id,
             "title" => "A",
             "board_id" => ctx.a.board_id
           }

    assert via_mcp == %{rest | "card" => ctx.b.id, "title" => "B"}
    assert Boards.Cards.get_card(ctx.a.id) == nil and Boards.Cards.get_card(ctx.b.id) == nil
  end

  test "MCP refuses without confirm = true and deletes nothing; REST doesn't ask", ctx do
    for args <- [%{}, %{confirm: false}, %{confirm: "yes"}] do
      assert {true, text} = call_mcp_tool(ctx.conn, "delete_card", Map.put(args, :card, ctx.a.id))
      assert text =~ "needs confirm = true"
      assert text =~ "archive_card"
    end

    assert Boards.Cards.get_card(ctx.a.id)

    # REST never asked, and a `confirm` sent there changes nothing.
    assert ctx.conn |> delete("/api/cards/#{ctx.a.id}", %{confirm: false}) |> json_response(200)
    assert Boards.Cards.get_card(ctx.a.id) == nil
  end

  test "a card that isn't there, or someone else's, is refused alike", ctx do
    assert %{"error" => _} = ctx.conn |> delete("/api/cards/999999999") |> json_response(404)

    assert {true, "no card you can see matches that"} =
             call_mcp_tool(ctx.conn, "delete_card", %{card: 999_999_999, confirm: true})

    other = user_fixture("del.stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "del3187b"}, owner: other)
    card = card_fixture(hd(theirs.columns), %{"title" => "Theirs"})

    %{"error" => rest} = ctx.conn |> delete("/api/cards/#{card.id}") |> json_response(403)
    assert {true, ^rest} = call_mcp_tool(ctx.conn, "delete_card", %{card: card.id, confirm: true})
    assert Boards.Cards.get_card(card.id)
  end
end
