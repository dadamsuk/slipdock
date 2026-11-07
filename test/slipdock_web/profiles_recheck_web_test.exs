defmodule SlipdockWeb.ProfilesRecheckWebTest do
  @moduledoc """
  The actual change at the doors (#2017): REST `changed_lines` and
  `changed_files` on a completing PATCH, and MCP `complete_card`'s, raise
  an agent's card's profile on a board with profiles on; a malformed one is
  refused with 422 (a tool error over MCP).
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  @migration "priv/repo/migrations/20261107000000_add_thing.exs"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Rechecked", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"profiles" => true})
    [_backlog, _todo, doing, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Docs", "paths" => "docs/**", "profile" => "docs"})
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

  test "PATCH /api/cards: the change raises the profile, and is not kept on the card", ctx do
    json =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{
        "completed" => true,
        "changed_lines" => 612,
        "changed_files" => ["docs/a.md"]
      })
      |> json_response(200)

    assert json["card"]["profile"] == "feature"
    refute Map.has_key?(json["card"], "changed_lines")
  end

  test "PATCH /api/cards: a malformed change is refused", ctx do
    body =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"completed" => true, "changed_lines" => -3})
      |> json_response(422)

    assert Map.has_key?(body["details"], "changed_lines")
    refute Repo.get!(Card, ctx.card.id).completed
  end

  test "MCP complete_card: changed_files with a migration raises docs to schema", ctx do
    result =
      mcp(ctx.agent, "complete_card", %{
        "card" => ctx.card.id,
        "changed_lines" => 20,
        "changed_files" => ["docs/a.md", @migration]
      })

    refute result["isError"]
    assert Repo.get!(Card, ctx.card.id).profile == "schema"
  end

  test "MCP complete_card: a malformed change is a tool error", ctx do
    result =
      mcp(ctx.agent, "complete_card", %{"card" => ctx.card.id, "changed_files" => [1, 2]})

    assert result["isError"]
    assert Repo.get!(Card, ctx.card.id).profile == "docs"
  end
end
