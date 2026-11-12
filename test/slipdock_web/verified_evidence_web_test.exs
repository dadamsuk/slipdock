defmodule SlipdockWeb.VerifiedEvidenceWebTest do
  @moduledoc """
  Verified work 2 (#1632) at the doors: the switch over the API and in
  settings, MCP's complete_card refused without evidence and completing with
  it, the evidence in card JSON and the card panel, and the guide describing
  it only when a board has it on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Evidence", "code" => unique_code()}, owner: user)
    [_backlog, _todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, doing: doing, done: done, card: card, agent: agent}
  end

  defp on(ctx), do: Boards.update_board(ctx.board, %{"evidence_required" => true})

  defp mcp(conn, tool, args) do
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
  end

  test "the switch is off by default and PATCH /api/boards turns it on", ctx do
    board = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
    assert board["board"]["evidence_required"] == false

    resp =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"evidence_required" => true})
      |> json_response(200)

    assert resp["board"]["evidence_required"] == true
  end

  test "off: complete_card closes with no evidence, and a card has no evidence keys", ctx do
    result = mcp(ctx.agent, "complete_card", %{card: ctx.card.id})
    assert result["isError"] == false

    card = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert card["card"]["completed"]
    refute Map.has_key?(card["card"], "evidence")
  end

  test "on: complete_card is refused without evidence and closes with it", ctx do
    {:ok, _} = on(ctx)

    result = mcp(ctx.agent, "complete_card", %{card: ctx.card.id})
    assert result["isError"] == true
    assert [%{"text" => text}] = result["content"]
    assert text =~ "evidence"
    card = Repo.get!(Card, ctx.card.id)
    refute card.completed
    assert card.column_id == ctx.doing.id

    result =
      mcp(ctx.agent, "complete_card", %{
        card: ctx.card.id,
        evidence: "mix test: 3 passed",
        commit: "abc1234"
      })

    assert result["isError"] == false
    card = Repo.get!(Card, ctx.card.id)
    assert card.completed
    assert card.column_id == ctx.done.id

    json = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert json["card"]["evidence"] == "mix test: 3 passed"
    assert json["card"]["evidence_commit"] == "abc1234"
  end

  test "on: complete_card takes structured evidence, shown in JSON and on the card (#1623)",
       ctx do
    {:ok, _} = on(ctx)

    result =
      mcp(ctx.agent, "complete_card", %{
        card: ctx.card.id,
        commit: "abc1234",
        branch: "main",
        tests: ["test/x_test.exs"],
        suite: %{result: "passed", passed: 12, failed: 0}
      })

    assert result["isError"] == false

    json = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert json["card"]["evidence_branch"] == "main"
    assert json["card"]["evidence_tests"] == ["test/x_test.exs"]

    assert json["card"]["evidence_suite"] == %{
             "result" => "passed",
             "passed" => 12,
             "failed" => 0
           }

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-evidence-suite", "passed (12 passed, 0 failed)")
    assert has_element?(view, "#card-evidence-tests", "test/x_test.exs")
    assert has_element?(view, "#card-evidence", "main")
  end

  test "a malformed suite over MCP is refused with the reason", ctx do
    result =
      mcp(ctx.agent, "complete_card", %{card: ctx.card.id, suite: %{result: "passed", passed: -2}})

    assert result["isError"] == true
  end

  test "on: PATCH completed without evidence is a 422 naming evidence", ctx do
    {:ok, _} = on(ctx)

    body =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"completed" => true})
      |> json_response(422)

    assert Map.has_key?(body["details"], "evidence")
  end

  test "the guide describes evidence only when a board has it on", ctx do
    refute ctx.agent |> get(~p"/api/guide") |> response(200) =~ "Evidence on completion"

    {:ok, _} = on(ctx)
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    assert guide =~ "**Evidence on completion.**"
    assert guide =~ "verified work: evidence on completion"
    refute guide =~ "**A bar before work starts.**"
  end

  test "settings turn it on, and the card panel shows the evidence and its commit", ctx do
    {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
    view |> form("#agentic-form", board: %{"evidence_required" => "true"}) |> render_submit()
    assert Boards.get_board!(ctx.board.id).evidence_required

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    refute has_element?(view, "#card-evidence")

    {:ok, _} =
      Boards.Cards.update_card(ctx.card, %{
        "evidence" => "Looked at it",
        "evidence_commit" => "abc1234"
      })

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-evidence", "Looked at it")
    assert has_element?(view, "#card-evidence code", "abc1234")
  end
end
