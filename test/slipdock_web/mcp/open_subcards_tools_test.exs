defmodule SlipdockWeb.MCP.OpenSubcardsToolsTest do
  @moduledoc """
  Orchestration fixes 5 (#1758) over MCP: complete_card, and move_card into
  the done list (update_card takes no `completed`), by an agent on a card
  whose sub-board has open cards are tool errors naming them; archived
  subcards don't count.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Epics", "code" => unique_code()}, owner: user)
    [_backlog, _todo, doing, done] = board.columns
    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    column = hd(Boards.get_board!(sub.id).columns)
    one = card_fixture(column, %{"title" => "Foo"})
    two = card_fixture(column, %{"title" => "Bar"})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{epic: epic, one: one, two: two, done: done, agent: agent}
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

  defp refusal(result) do
    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    text
  end

  test "complete_card is refused, naming both, and the card stays where it was", ctx do
    text = ctx.agent |> mcp("complete_card", %{card: ctx.epic.id}) |> refusal()
    assert text =~ "##{ctx.one.id} Foo, ##{ctx.two.id} Bar are still open"
    card = Repo.get!(Card, ctx.epic.id)
    refute card.completed
    refute card.column_id == ctx.done.id
  end

  # update_card takes no `completed`: complete_card is MCP's completion.
  test "move_card into the done list is refused too", ctx do
    text =
      ctx.agent |> mcp("move_card", %{card: ctx.epic.id, column: ctx.done.name}) |> refusal()

    assert text =~ "has open subcards"
    refute Repo.get!(Card, ctx.epic.id).completed
  end

  test "with one done and the other archived, complete_card closes it into done", ctx do
    {:ok, _} = Boards.update_card(ctx.one, %{"completed" => true})
    {:ok, _} = Boards.archive_card(ctx.two)

    result = mcp(ctx.agent, "complete_card", %{card: ctx.epic.id})
    assert result["isError"] == false, inspect(result["content"])
    card = Repo.get!(Card, ctx.epic.id)
    assert card.completed
    assert card.column_id == ctx.done.id
  end
end
