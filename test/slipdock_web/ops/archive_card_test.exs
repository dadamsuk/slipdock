defmodule SlipdockWeb.Ops.ArchiveCardTest do
  @moduledoc """
  `archive_card` defined once (#3187): REST's archive and restore routes and
  the MCP tool are one operation, answering the same call with the same
  `{card}` and the same refusal.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{user: user} do
    board = board_fixture(%{"name" => "Arch", "code" => "arch3187"}, owner: user)
    [todo | _] = board.columns
    %{a: card_fixture(todo, %{"title" => "A"}), b: card_fixture(todo, %{"title" => "B"})}
  end

  defp archived?(card), do: Boards.Cards.get_card!(card.id).archived_at != nil

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.ArchiveCard
    assert tool.__op__() == SlipdockWeb.Ops.ArchiveCard
    assert tool.input_schema().required == ["card"]
    assert Map.keys(tool.input_schema().properties) == [:card, :restore]
  end

  test "REST and MCP archive alike and answer the same {card}", ctx do
    rest = ctx.conn |> post("/api/cards/#{ctx.a.id}/archive") |> json_response(200)
    {false, via_mcp} = mcp_call(ctx.conn, "archive_card", %{card: ctx.b.id})

    assert archived?(ctx.a) and archived?(ctx.b)
    assert Map.keys(via_mcp) == Map.keys(rest)
    assert Map.keys(via_mcp["card"]) == Map.keys(rest["card"])
    assert rest["card"]["archived_at"] && via_mcp["card"]["archived_at"]
  end

  test "REST's restore route is the same operation as restore = true", ctx do
    Boards.Cards.archive_card(ctx.a)
    Boards.Cards.archive_card(ctx.b)

    rest = ctx.conn |> post("/api/cards/#{ctx.a.id}/restore") |> json_response(200)
    {false, via_mcp} = mcp_call(ctx.conn, "archive_card", %{card: ctx.b.id, restore: true})
    by_param = ctx.conn |> post("/api/cards/#{ctx.a.id}/archive", %{restore: true})

    refute archived?(ctx.a) or archived?(ctx.b)
    assert rest["card"]["archived_at"] == nil and via_mcp["card"]["archived_at"] == nil
    assert json_response(by_param, 200)["card"]["archived_at"] == nil
  end

  test "asking for what is already so changes nothing, on either surface", ctx do
    {:ok, archived} = Boards.Cards.archive_card(ctx.a)
    rest = ctx.conn |> post("/api/cards/#{ctx.a.id}/archive") |> json_response(200)
    {false, via_mcp} = mcp_call(ctx.conn, "archive_card", %{card: ctx.a.id})

    when_archived = DateTime.to_iso8601(archived.archived_at)
    assert rest["card"]["archived_at"] == when_archived
    assert via_mcp["card"] == rest["card"]

    live = ctx.conn |> post("/api/cards/#{ctx.b.id}/restore") |> json_response(200)
    assert live["card"]["position"] == ctx.b.position
  end

  test "a bad restore, or a card that isn't there, is refused alike", ctx do
    %{"error" => rest} =
      ctx.conn
      |> post("/api/cards/#{ctx.a.id}/archive", %{restore: "maybe"})
      |> json_response(400)

    assert rest == "restore must be true or false"
    assert {true, ^rest} = mcp_call(ctx.conn, "archive_card", %{card: ctx.a.id, restore: "maybe"})
    refute archived?(ctx.a)

    assert ctx.conn |> post("/api/cards/999999999/archive") |> json_response(404)

    assert {true, "no card you can see matches that"} =
             mcp_call(ctx.conn, "archive_card", %{card: 999_999_999})
  end

  test "someone else's card is refused on both, in the same words", ctx do
    other = user_fixture("arch.stranger@example.com")
    board = board_fixture(%{"name" => "Theirs", "code" => "arch3187b"}, owner: other)
    card = card_fixture(hd(board.columns), %{"title" => "Theirs"})

    %{"error" => rest} = ctx.conn |> post("/api/cards/#{card.id}/archive") |> json_response(403)
    assert {true, ^rest} = mcp_call(ctx.conn, "archive_card", %{card: card.id})
    refute archived?(card)
  end
end
