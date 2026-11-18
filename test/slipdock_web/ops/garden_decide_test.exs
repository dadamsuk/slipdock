defmodule SlipdockWeb.Ops.GardenDecideTest do
  @moduledoc """
  `garden_decide` defined once (#3188): REST's `POST
  /api/garden/suggestions/:id/:decision` and the MCP tool apply, dismiss and
  undo a suggestion alike and answer `{suggestion}`; MCP alone asks for
  `confirm: true` first; both refuse an unknown field and the same calls in
  the same words.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Gardener, Repo}
  alias Slipdock.Gardener.Suggestion

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Garden", "code" => "gd3188"}, owner: owner)
    [_backlog, _todo, doing, _done] = board.columns
    card_fixture(doing, %{"title" => "Stray", "completed" => true})
    card_fixture(doing, %{"title" => "Stray too", "completed" => true})
    {:ok, _} = Gardener.run(board, only: ["completed_not_done"])
    [one, two] = Gardener.list_open(board)
    %{board: board, one: one, two: two}
  end

  defp state(s), do: Repo.get!(Suggestion, s.id).state

  test "the MCP tool is the definition, and asks for confirm" do
    tool = SlipdockWeb.MCP.Tools.GardenDecide
    assert tool.__op__() == SlipdockWeb.Ops.GardenDecide
    assert tool.input_schema().required == ["suggestion", "decision", "confirm"]
    assert tool.input_schema().properties.decision.enum == ["apply", "dismiss", "undo"]
  end

  test "REST and MCP decide alike and answer {suggestion}", ctx do
    rest =
      ctx.conn
      |> post("/api/garden/suggestions/#{ctx.one.id}/apply", %{})
      |> json_response(200)

    {false, via_mcp} =
      call_mcp_tool(ctx.conn, "garden_decide", %{
        suggestion: ctx.two.id,
        decision: "apply",
        confirm: true
      })

    assert rest["suggestion"]["state"] == "applied"
    assert Map.keys(rest) == Map.keys(via_mcp)
    assert Map.keys(rest["suggestion"]) == Map.keys(via_mcp["suggestion"])
    assert {state(ctx.one), state(ctx.two)} == {"applied", "applied"}

    # Undone on both, the same way.
    assert ctx.conn
           |> post("/api/garden/suggestions/#{ctx.one.id}/undo", %{})
           |> json_response(200)

    assert {false, _} =
             call_mcp_tool(ctx.conn, "garden_decide", %{
               suggestion: ctx.two.id,
               decision: "undo",
               confirm: true
             })

    assert {state(ctx.one), state(ctx.two)} == {"open", "open"}
  end

  test "MCP refuses until confirm is true; REST never asks, and ignores one sent", ctx do
    for confirm <- [false, nil] do
      args = %{suggestion: ctx.one.id, decision: "dismiss", confirm: confirm}
      assert {true, text} = call_mcp_tool(ctx.conn, "garden_decide", args)
      assert text =~ "needs confirm = true"
    end

    assert state(ctx.one) == "open"

    assert ctx.conn
           |> post("/api/garden/suggestions/#{ctx.one.id}/dismiss", %{confirm: true})
           |> json_response(200)

    assert state(ctx.one) == "dismissed"
  end

  test "an unknown decision, an unknown field and a decided one are refused alike", ctx do
    {:ok, _} = Gardener.dismiss(ctx.two, ctx.user)

    for {id, decision, extra, status} <- [
          {ctx.one.id, "maybe", %{}, 400},
          {ctx.two.id, "apply", %{}, 422}
        ] do
      %{"error" => rest} =
        ctx.conn
        |> post("/api/garden/suggestions/#{id}/#{decision}", extra)
        |> json_response(status)

      args = Map.merge(%{suggestion: id, decision: decision, confirm: true}, extra)
      assert {true, ^rest} = call_mcp_tool(ctx.conn, "garden_decide", args)
    end

    # A field it doesn't take: REST names it, MCP too.
    assert %{"error" => "unknown field(s): kep"} =
             ctx.conn
             |> post("/api/garden/suggestions/#{ctx.one.id}/apply", %{kep: 1})
             |> json_response(400)

    assert {true, text} =
             call_mcp_tool(ctx.conn, "garden_decide", %{
               suggestion: ctx.one.id,
               decision: "apply",
               confirm: true,
               kep: 1
             })

    assert text =~ ~s(no argument "kep")
    assert state(ctx.one) == "open"
  end

  test "a reader is refused alike; a stranger finds no suggestion", ctx do
    reader = user_fixture("gd3188.reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)
    stranger = user_fixture("gd3188.stranger@example.com")
    args = %{suggestion: ctx.one.id, decision: "dismiss", confirm: true}

    %{"error" => rest} =
      reader
      |> conn_as()
      |> post("/api/garden/suggestions/#{ctx.one.id}/dismiss", %{})
      |> json_response(403)

    assert {true, ^rest} = call_mcp_tool(conn_as(reader), "garden_decide", args)

    assert stranger
           |> conn_as()
           |> post("/api/garden/suggestions/#{ctx.one.id}/dismiss", %{})
           |> json_response(404)

    assert {true, text} = call_mcp_tool(conn_as(stranger), "garden_decide", args)
    assert text =~ "no suggestion"
    assert state(ctx.one) == "open"
  end
end
