defmodule SlipdockWeb.VerifiedBarWebTest do
  @moduledoc """
  Verified work 1 (#1631) at the doors: the switch over the API and in board
  settings, the bar refused or locked for an agent over the API and MCP but
  not for a person on the CLI, the bar in card JSON and the card panel, and
  the guide describing it only for a board that has it on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Bars", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Work"})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    person = put_req_header(agent, "x-slipdock-client", "cli")
    %{board: board, todo: todo, doing: doing, card: card, agent: agent, person: person}
  end

  defp on(ctx), do: Boards.update_board(ctx.board, %{"bar_required" => true})

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

  test "the switch is off by default, and PATCH /api/boards turns it on", ctx do
    board = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
    assert board["board"]["bar_required"] == false

    resp =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"bar_required" => true})
      |> json_response(200)

    assert resp["board"]["bar_required"] == true
  end

  test "a card with no bar has no bar keys in its JSON", ctx do
    card = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    refute Map.has_key?(card["card"], "bar")
    refute Map.has_key?(card["card"], "bar_locked_at")
  end

  test "off: an agent moves a card with no bar into progress", ctx do
    ctx.agent
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.doing.id})
    |> json_response(200)

    assert Repo.get!(Card, ctx.card.id).column_id == ctx.doing.id
  end

  test "on: an agent is refused over PATCH and move; a person on the CLI is not", ctx do
    {:ok, _} = on(ctx)

    body =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.doing.id})
      |> json_response(422)

    assert body["error"] =~ "bar"

    ctx.agent
    |> post(~p"/api/cards/#{ctx.card.id}/move", %{"column" => ctx.doing.id})
    |> json_response(422)

    assert Repo.get!(Card, ctx.card.id).column_id == ctx.todo.id

    ctx.person
    |> post(~p"/api/cards/#{ctx.card.id}/move", %{"column" => ctx.doing.id})
    |> json_response(200)

    assert Repo.get!(Card, ctx.card.id).column_id == ctx.doing.id
  end

  test "on: the bar is written, locks when work starts, and is refused to an agent after",
       ctx do
    {:ok, _} = on(ctx)

    ctx.agent
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"bar" => "Tests pass"})
    |> json_response(200)

    card =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.doing.id})
      |> json_response(200)

    assert card["card"]["bar"] == "Tests pass"
    assert card["card"]["bar_locked_at"]

    body =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"bar" => "Less"})
      |> json_response(422)

    assert inspect(body["details"]) =~ "locked"

    ctx.person
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"bar" => "Less"})
    |> json_response(200)

    assert Repo.get!(Card, ctx.card.id).bar == "Less"
  end

  test "on: MCP's move_card refuses with the reason, and update_card writes the bar", ctx do
    {:ok, _} = on(ctx)

    result = mcp(ctx.agent, "move_card", %{card: ctx.card.id, column: "#{ctx.doing.id}"})
    assert result["isError"] == true
    assert [%{"text" => text}] = result["content"]
    assert text =~ "bar"

    result = mcp(ctx.agent, "update_card", %{card: ctx.card.id, bar: "Docs updated"})
    assert result["isError"] == false

    result = mcp(ctx.agent, "move_card", %{card: ctx.card.id, column: "#{ctx.doing.id}"})
    assert result["isError"] == false
    assert Repo.get!(Card, ctx.card.id).bar_locked_at
  end

  test "the guide describes the bar only when a board has it on", ctx do
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    refute guide =~ "## Verified work"
    refute guide =~ "verified work:"

    {:ok, _} = on(ctx)
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    assert guide =~ "## Verified work"
    assert guide =~ "**A bar before work starts.**"
    assert guide =~ "verified work: a bar before work starts"
  end

  test "board settings turn it on, and the card panel shows the bar and its lock", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    refute has_element?(view, "#board-bar-required[checked]")

    view |> form("#board-form", board: %{"bar_required" => "true"}) |> render_submit()
    assert Boards.get_board!(ctx.board.id).bar_required

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-bar")
    refute has_element?(view, "#card-bar-locked")

    view |> form("#card-bar-form", card: %{"bar" => "Tests pass"}) |> render_change()
    assert Repo.get!(Card, ctx.card.id).bar == "Tests pass"

    :ok = Boards.move_card(ctx.card.id, ctx.doing.id)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-bar-locked")
  end

  test "with the switch off and no bar, the card panel has no bar section", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    refute has_element?(view, "#card-bar")
  end
end
