defmodule SlipdockWeb.Ops.LeaveHandoffTest do
  @moduledoc """
  `leave_handoff` defined once (#3187): REST's POST and DELETE on
  `/api/cards/:id/handoff` and the MCP tool are one operation, answering the
  same call with the same JSON and the same refusal; the way it came in is
  the caller's, not a param.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards.Handoffs

  setup %{user: user} do
    board = board_fixture(%{"name" => "Hand", "code" => "hand3187"}, owner: user)
    [todo | _] = board.columns
    %{a: card_fixture(todo, %{"title" => "A"}), b: card_fixture(todo, %{"title" => "B"})}
  end

  defp same(json), do: Map.drop(json, ["id", "at", "via"])

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.LeaveHandoff
    assert tool.__op__() == SlipdockWeb.Ops.LeaveHandoff

    assert tool.input_schema().properties |> Map.keys() |> Enum.sort() ==
             ~w(body card clear delete next_step)a
  end

  test "REST (201) and MCP write a handoff alike, each recording its own way in", ctx do
    args = %{next_step: "Run CI", body: "State: green"}
    rest = ctx.conn |> post("/api/cards/#{ctx.a.id}/handoff", args) |> json_response(201)
    {false, via_mcp} = call_mcp_tool(ctx.conn, "leave_handoff", Map.put(args, :card, ctx.b.id))

    assert Map.keys(via_mcp) == Map.keys(rest)
    assert same(via_mcp["handoff"]) == same(rest["handoff"])
    assert rest["handoff"]["via"] == "api" and via_mcp["handoff"]["via"] == "mcp"

    cli =
      ctx.conn
      |> put_req_header("x-slipdock-client", "cli")
      |> post("/api/cards/#{ctx.a.id}/handoff", %{next_step: "Again", via: "runner"})
      |> json_response(201)

    assert cli["handoff"]["via"] == "cli"
  end

  test "clear: true clears it, on either surface", ctx do
    rest =
      ctx.conn |> post("/api/cards/#{ctx.a.id}/handoff", %{clear: true}) |> json_response(201)

    {false, via_mcp} = call_mcp_tool(ctx.conn, "leave_handoff", %{card: ctx.b.id, clear: true})

    assert rest["handoff"]["cleared"] and via_mcp["handoff"]["cleared"]
    assert same(via_mcp["handoff"]) == same(rest["handoff"])
  end

  test "REST's DELETE is delete: true, and both answer what went and what is current", ctx do
    for card <- [ctx.a, ctx.b] do
      {:ok, _} = Handoffs.leave_handoff(card, ctx.user, %{next_step: "Old", via: "api"})
      {:ok, _} = Handoffs.leave_handoff(card, ctx.user, %{next_step: "New", via: "api"})
    end

    rest = ctx.conn |> delete("/api/cards/#{ctx.a.id}/handoff") |> json_response(200)
    {false, via_mcp} = call_mcp_tool(ctx.conn, "leave_handoff", %{card: ctx.b.id, delete: true})

    for answer <- [rest, via_mcp] do
      assert answer["deleted"]["next_step"] == "New"
      assert answer["handoff"]["next_step"] == "Old"
    end

    assert Map.keys(via_mcp) == Map.keys(rest)
    by_param = ctx.conn |> post("/api/cards/#{ctx.a.id}/handoff", %{delete: true})
    assert json_response(by_param, 200)["deleted"]["next_step"] == "Old"
  end

  test "refusals read the same: no next step, nothing to delete, no such card", ctx do
    %{"error" => rest} =
      ctx.conn |> post("/api/cards/#{ctx.a.id}/handoff", %{body: "a note"}) |> json_response(422)

    assert {true, text} =
             call_mcp_tool(ctx.conn, "leave_handoff", %{card: ctx.a.id, body: "a note"})

    assert text =~ "next_step"
    assert is_binary(rest)

    assert ctx.conn |> delete("/api/cards/#{ctx.a.id}/handoff") |> json_response(404)

    assert {true, "no handoff you can see matches that"} =
             call_mcp_tool(ctx.conn, "leave_handoff", %{card: ctx.a.id, delete: true})

    %{"error" => rest} =
      ctx.conn |> post("/api/cards/#{ctx.a.id}/handoff", %{clear: "maybe"}) |> json_response(400)

    assert {true, ^rest} =
             call_mcp_tool(ctx.conn, "leave_handoff", %{card: ctx.a.id, clear: "maybe"})

    assert Handoffs.current_handoff(ctx.a) == nil
  end
end
