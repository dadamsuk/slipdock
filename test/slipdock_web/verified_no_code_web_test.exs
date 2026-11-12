defmodule SlipdockWeb.VerifiedNoCodeWebTest do
  @moduledoc """
  A card that changes no code, at the doors (#1938): REST `evidence_no_code`
  and MCP `complete_card` `no_code` complete it on a pull request board
  without a PR; without either it is still refused; the card's JSON, the
  panel, the guide and a verify job's prompt carry it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  @why "a read-only sweep: filed two cards"

  setup %{user: user} do
    board = board_fixture(%{"name" => "No code", "code" => unique_code()}, owner: user)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "evidence_required" => true,
        "ship_via" => "pull_request"
      })

    [_backlog, _todo, doing, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Sweep"})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, card: card, agent: agent}
  end

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

  test "PATCH /api/cards: refused without it, submitted with it, and the JSON carries it",
       ctx do
    body =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"completed" => true, "evidence" => "swept"})
      |> json_response(422)

    assert Map.has_key?(body["details"], "evidence_pr")

    json =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{
        "completed" => true,
        "evidence" => "swept",
        "evidence_no_code" => @why
      })
      |> json_response(200)

    assert json["card"]["evidence_no_code"] == @why
    assert json["card"]["verify_state"] == "pending"
  end

  test "PATCH /api/cards: a reason beside a PR is refused", ctx do
    body =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{
        "completed" => true,
        "evidence_no_code" => @why,
        "evidence_pr" => "https://github.com/acme/app/pull/7"
      })
      |> json_response(422)

    assert Map.has_key?(body["details"], "evidence_no_code")
  end

  test "MCP complete_card takes no_code, and still refuses without it", ctx do
    result = mcp(ctx.agent, "complete_card", %{card: ctx.card.id, evidence: "swept"})
    assert result["isError"] == true
    assert [%{"text" => text}] = result["content"]
    assert text =~ "no_code"

    result =
      mcp(ctx.agent, "complete_card", %{card: ctx.card.id, evidence: "swept", no_code: @why})

    assert result["isError"] == false
    card = Repo.get!(Card, ctx.card.id)
    assert card.evidence_no_code == @why and card.verify_state == "pending"
  end

  test "MCP complete_card lists no_code in its schema" do
    props = SlipdockWeb.MCP.Tools.CompleteCard.input_schema().properties
    assert props.no_code.description =~ "changes no code"
  end

  test "the card panel shows the reason", ctx do
    {:ok, _} = Boards.Cards.update_card(ctx.card, %{"evidence_no_code" => @why})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert view |> element("#card-evidence-no-code") |> render() =~ @why
  end

  test "the guide says how to complete a card with no code on a PR board", ctx do
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    assert guide =~ "**A card that"
    assert guide =~ "--no-code"
  end

  test "the card's shipping instructions say it too", ctx do
    json = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert json["card"]["shipping"]["instructions"] =~ "--no-code"
  end
end
