defmodule SlipdockWeb.ActorAPITest do
  @moduledoc """
  A card move records who made it and through which door (`Slipdock.Actor`),
  whichever way it arrives: a drag on the board, the JSON API with and
  without the CLI's headers, and MCP's `move_card`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, MoveRecorder}

  setup %{user: user} do
    MoveRecorder.attach()
    board = board_fixture(%{"name" => "Doors"}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Moving"})
    %{board: board, todo: todo, doing: doing, card: card}
  end

  defp with_token(user, label, headers \\ []) do
    {token, _} = Accounts.create_api_token(user, label)

    Enum.reduce(
      headers,
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token),
      fn {k, v}, conn -> put_req_header(conn, k, v) end
    )
  end

  defp moved(ctx) do
    id = ctx.card.id
    doing = ctx.doing.id
    assert_receive {:moved, %{card_id: ^id, to_column_id: ^doing, actor: actor}}
    actor
  end

  test "a drag on the board is the person's, on the web", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    render_hook(view, "move_card", %{
      "id" => "#{ctx.card.id}",
      "from" => "#{ctx.todo.id}",
      "to" => "#{ctx.doing.id}",
      "before" => nil
    })

    user_id = ctx.user.id
    assert %{kind: "human", via: "web", user_id: ^user_id, agent: nil} = moved(ctx)
  end

  describe "POST /api/cards/:id/move" do
    defp move(conn, ctx) do
      conn
      |> post("/api/cards/#{ctx.card.id}/move", %{column: ctx.doing.id})
      |> json_response(200)
    end

    test "with a token and no CLI header is an agent's", ctx do
      with_token(ctx.user, "deploy-script") |> move(ctx)
      assert %{kind: "agent", via: "api", agent: "deploy-script", job_id: nil} = moved(ctx)
    end

    test "from the CLI with no agent header is the person's", ctx do
      with_token(ctx.user, "laptop", [{"x-slipdock-client", "cli"}]) |> move(ctx)
      user_id = ctx.user.id
      assert %{kind: "human", via: "cli", agent: "laptop", user_id: ^user_id} = moved(ctx)
    end

    test "from the CLI with the agent and job headers is the agent's, with the job", ctx do
      with_token(ctx.user, "laptop", [
        {"x-slipdock-client", "cli"},
        {"x-slipdock-agent", "1"},
        {"x-slipdock-job", "42"}
      ])
      |> move(ctx)

      assert %{kind: "agent", via: "cli", agent: "laptop", job_id: 42} = moved(ctx)
    end

    test "to another board carries the actor too", ctx do
      other = board_fixture(%{"name" => "Over there"}, owner: ctx.user)
      id = ctx.card.id

      with_token(ctx.user, "deploy-script")
      |> post("/api/cards/#{id}/move", %{board: other.id})
      |> json_response(200)

      assert_receive {:moved, %{card_id: ^id, actor: %{kind: "agent", via: "api"}}}
    end
  end

  test "PATCH /api/cards/:id with a column is classified the same way", ctx do
    with_token(ctx.user, "laptop", [{"x-slipdock-client", "cli"}])
    |> patch("/api/cards/#{ctx.card.id}", %{column: ctx.doing.id})
    |> json_response(200)

    assert %{kind: "human", via: "cli"} = moved(ctx)
  end

  test "MCP move_card is an agent's, over MCP, under the token's label", ctx do
    result =
      with_token(ctx.user, "claude-desktop")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "move_card", arguments: %{card: ctx.card.id, column: ctx.doing.id}}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert result["isError"] == false, inspect(result["content"])
    assert %{kind: "agent", via: "mcp", agent: "claude-desktop"} = moved(ctx)
  end

  test "MCP complete_card's move into the done list is an agent's, over MCP", ctx do
    result =
      with_token(ctx.user, "claude-desktop")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "complete_card", arguments: %{card: ctx.card.id}}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert result["isError"] == false, inspect(result["content"])
    id = ctx.card.id
    done = List.last(ctx.board.columns).id

    assert_receive {:moved,
                    %{
                      card_id: ^id,
                      to_column_id: ^done,
                      actor: %{kind: "agent", via: "mcp", agent: "claude-desktop"}
                    }}
  end
end
