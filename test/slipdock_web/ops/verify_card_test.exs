defmodule SlipdockWeb.Ops.VerifyCardTest do
  @moduledoc """
  `verify_card` defined once (#3187): REST's `POST /api/cards/:id/verify`
  and the MCP tool decide alike, answer the same `{card}`, and refuse the
  same calls in the same words.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Ver", "code" => "ver3187"}, owner: user)
    {:ok, _} = Boards.update_board(board, %{"verify_work" => true})
    [_backlog, _todo, doing, _done] = board.columns
    builder = agent(user, "builder")

    [a, b] =
      for title <- ["A", "B"] do
        card = card_fixture(doing, %{"title" => title})
        {false, _} = mcp_call(builder, "complete_card", %{card: card.id})
        card
      end

    %{a: a, b: b, builder: builder, checker: agent(user, "checker")}
  end

  defp agent(user, label) do
    {token, _} = Accounts.create_api_token(user, label)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  test "the MCP tool is the definition" do
    tool = SlipdockWeb.MCP.Tools.VerifyCard
    assert tool.__op__() == SlipdockWeb.Ops.VerifyCard
    assert tool.input_schema().required == ["card", "decision"]
    assert tool.input_schema().properties.checks.type == "array"
  end

  test "REST and MCP accept alike and answer the same {card}", ctx do
    rest =
      ctx.checker
      |> post("/api/cards/#{ctx.a.id}/verify", %{decision: "accept"})
      |> json_response(200)

    {false, via_mcp} = mcp_call(ctx.checker, "verify_card", %{card: ctx.b.id, decision: "accept"})

    assert Map.keys(via_mcp) == ["card"] and Map.keys(rest) == ["card"]
    assert Map.keys(via_mcp["card"]) == Map.keys(rest["card"])
    assert rest["card"]["completed"] and via_mcp["card"]["completed"]
  end

  test "a rejection's checks: a list on MCP, a list or a line on REST", ctx do
    checks = ["bar:1=fail:no test"]

    rest =
      ctx.checker
      |> post("/api/cards/#{ctx.a.id}/verify", %{
        decision: "reject",
        reason: "No test",
        checks: "bar:1=fail:no test"
      })
      |> json_response(200)

    {false, via_mcp} =
      mcp_call(ctx.checker, "verify_card", %{
        card: ctx.b.id,
        decision: "reject",
        reason: "No test",
        checks: checks
      })

    refute rest["card"]["completed"] or via_mcp["card"]["completed"]

    assert Boards.Cards.get_card!(ctx.a.id).verify_state ==
             Boards.Cards.get_card!(ctx.b.id).verify_state
  end

  test "the same refusals in the same words, and nothing decided", ctx do
    cases = [
      {%{decision: "maybe"}, 400, "decision must be accept, reject, merged, agree or disagree"},
      {%{}, 400, "decision is required"},
      {%{decision: "reject"}, 422, "a rejection needs its reason"}
    ]

    for {args, status, words} <- cases do
      %{"error" => rest} =
        ctx.checker |> post("/api/cards/#{ctx.a.id}/verify", args) |> json_response(status)

      assert rest =~ words
      assert {true, ^rest} = mcp_call(ctx.checker, "verify_card", Map.put(args, :card, ctx.a.id))
    end

    # The builder can't verify its own work, on either surface.
    %{"error" => rest} =
      ctx.builder
      |> post("/api/cards/#{ctx.a.id}/verify", %{decision: "accept"})
      |> json_response(403)

    assert {true, ^rest} =
             mcp_call(ctx.builder, "verify_card", %{card: ctx.a.id, decision: "accept"})

    assert Boards.Cards.get_card!(ctx.a.id).verify_state == "pending"
  end
end
