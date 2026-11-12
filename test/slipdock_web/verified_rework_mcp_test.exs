defmodule SlipdockWeb.VerifiedReworkMCPTest do
  @moduledoc """
  Rework (#1659): `get_card` carries a rejected card's reason (`rejection`),
  so an agent doesn't depend on the handoff for it; any other card has none.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card

  setup %{user: owner} do
    board = board_fixture(%{"code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    [_backlog, _todo, doing | _] = board.columns
    card = card_fixture(doing, %{"title" => "Parser"})

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    {:ok, card} = Boards.Cards.update_card(card, %{"completed" => true}, actor: agent.("builder"))
    %{owner: owner, card: card, checker: agent.("checker")}
  end

  defp get_card(user, id) do
    result =
      user
      |> conn_as()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "get_card", arguments: %{card: id}}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert result["isError"] == false, inspect(result["content"])
    result["structuredContent"]
  end

  test "a pending card has no rejection", ctx do
    assert %{"rejection" => nil, "verify_state" => "pending"} = get_card(ctx.owner, ctx.card.id)
  end

  test "a rejected card names the reason, who rejected it and how often", ctx do
    {:ok, _} =
      Verified.decide(
        Repo.get!(Card, ctx.card.id),
        "reject",
        %{"reason" => "bar 1: The empty list case fails"},
        ctx.checker,
        ctx.owner
      )

    assert %{
             "rejection" => %{
               "reason" => "bar 1: The empty list case fails",
               "by" => "agent “checker”",
               "rejections" => 1,
               "at" => at
             }
           } = get_card(ctx.owner, ctx.card.id)

    assert is_binary(at)
  end
end
