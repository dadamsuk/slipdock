defmodule SlipdockWeb.VerifiedReopenWebTest do
  @moduledoc """
  Done stays done (#1850) at the doors an agent uses: the CLI's move
  (`POST /api/cards/:id/move`) and `undone` (`PATCH completed: false`), a
  PATCH of the column, and MCP's move_card are refused for a done card with
  the reason, and the card stays done; so is the CLI's move to another
  board (`POST /api/cards/:id/move` with `board`, #1851).
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Reopen", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})
    :ok = Boards.Cards.move_card(card.id, done.id, nil, actor: Actor.web(user))
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    other = board_fixture(%{"name" => "Elsewhere", "code" => unique_code()}, owner: user)

    %{card: card, todo: todo, done: done, agent: agent, user: user, other: other}
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

  defp assert_done(ctx) do
    card = Repo.get!(Card, ctx.card.id)
    assert card.completed
    assert card.column_id == ctx.done.id
  end

  test "the CLI's move to the top of To Do is a 422 with the reason", ctx do
    body =
      ctx.agent
      |> post(~p"/api/cards/#{ctx.card.id}/move", %{"column" => ctx.todo.id, "index" => "0"})
      |> json_response(422)

    assert inspect(body) =~ "an agent can't reopen it"
    assert_done(ctx)
  end

  test "a PATCH moving it, or unticking it, is refused too", ctx do
    ctx.agent
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.todo.id})
    |> json_response(422)

    body =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"completed" => false})
      |> json_response(422)

    assert inspect(body) =~ "a person reopens finished work"
    assert_done(ctx)
  end

  describe "POST /api/cards/:id/move with board (#1851)" do
    test "an agent's move to a list there that isn't done is a 422 with the reason", ctx do
      [_backlog, todo, _doing, _done] = ctx.other.columns

      body =
        ctx.agent
        |> post(~p"/api/cards/#{ctx.card.id}/move", %{
          "board" => ctx.other.id,
          "column" => todo.id
        })
        |> json_response(422)

      assert inspect(body) =~ "an agent can't reopen it"
      assert inspect(body) =~ "a person reopens finished work"
      assert_done(ctx)
    end

    test "an agent's move to its done list goes through, still done", ctx do
      [_backlog, _todo, _doing, done] = ctx.other.columns

      ctx.agent
      |> post(~p"/api/cards/#{ctx.card.id}/move", %{"board" => ctx.other.id, "column" => done.id})
      |> json_response(200)

      card = Repo.get!(Card, ctx.card.id)
      assert card.completed and card.column_id == done.id
    end

    test "an agent's move of a card that isn't done goes through", ctx do
      open = card_fixture(ctx.todo, %{"title" => "Open"})
      [_backlog, todo, _doing, _done] = ctx.other.columns

      ctx.agent
      |> post(~p"/api/cards/#{open.id}/move", %{"board" => ctx.other.id, "column" => todo.id})
      |> json_response(200)

      assert Repo.get!(Card, open.id).column_id == todo.id
    end

    test "a person on the CLI moves the done card there, reopening it", ctx do
      [_backlog, todo, _doing, _done] = ctx.other.columns

      ctx.agent
      |> put_req_header("x-slipdock-client", "cli")
      |> post(~p"/api/cards/#{ctx.card.id}/move", %{"board" => ctx.other.id, "column" => todo.id})
      |> json_response(200)

      card = Repo.get!(Card, ctx.card.id)
      assert card.column_id == todo.id
      refute card.completed
    end
  end

  # MCP has no way to untick a card (update_card takes no `completed`), so
  # moving it is the one way in.
  test "MCP's move_card answers a tool error", ctx do
    result = mcp(ctx.agent, "move_card", %{card: ctx.card.id, column: "#{ctx.todo.id}"})
    assert result["isError"] == true
    assert [%{"text" => text}] = result["content"]
    assert text =~ "an agent can't reopen it"
    assert_done(ctx)
  end
end
