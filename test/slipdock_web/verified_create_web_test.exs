defmodule SlipdockWeb.VerifiedCreateWebTest do
  @moduledoc """
  #1815 at the doors: an agent creating a card straight into a doing list
  over REST (`slipdock add --column`) and MCP `create_card` meets the bar
  and lane checks a move into it makes, and a person on the CLI doesn't.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Created", "code" => unique_code()}, owner: user)
    [_backlog, _todo, doing, _done] = board.columns
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    person = put_req_header(agent, "x-slipdock-client", "cli")
    %{board: board, doing: doing, agent: agent, person: person}
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

  defp in_doing(ctx),
    do: Repo.all(from(c in Card, where: c.column_id == ^ctx.doing.id, select: c.title))

  describe "with bar_required on" do
    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"bar_required" => true})
      %{board: board}
    end

    test "REST refuses an agent's card in progress with no bar, and makes none", ctx do
      body =
        ctx.agent
        |> post(~p"/api/boards/#{ctx.board.id}/cards", %{
          "title" => "Sneaked in",
          "column" => ctx.doing.name
        })
        |> json_response(422)

      assert inspect(body) =~ "bar"
      assert in_doing(ctx) == []
    end

    test "REST makes an agent's card in progress with a bar, locked", ctx do
      body =
        ctx.agent
        |> post(~p"/api/boards/#{ctx.board.id}/cards", %{
          "title" => "Barred",
          "column" => ctx.doing.name,
          "bar" => "Tests pass"
        })
        |> json_response(201)

      card = Repo.get!(Card, body["card"]["id"])
      assert card.bar_locked_at
    end

    test "a person on the CLI makes one in progress with no bar", ctx do
      ctx.person
      |> post(~p"/api/boards/#{ctx.board.id}/cards", %{
        "title" => "Theirs",
        "column" => ctx.doing.name
      })
      |> json_response(201)

      assert in_doing(ctx) == ["Theirs"]
    end

    test "MCP create_card refuses with the reason, and makes one with a bar", ctx do
      result =
        mcp(ctx.agent, "create_card", %{
          board: "#{ctx.board.id}",
          title: "Sneaked in",
          column: ctx.doing.name
        })

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "bar"
      assert in_doing(ctx) == []

      result =
        mcp(ctx.agent, "create_card", %{
          board: "#{ctx.board.id}",
          title: "Barred",
          column: ctx.doing.name,
          bar: "Docs updated"
        })

      assert result["isError"] == false
      assert [card] = Repo.all(from(c in Card, where: c.column_id == ^ctx.doing.id))
      assert card.bar_locked_at
    end
  end

  test "with lanes on, REST and MCP refuse an agent's overlapping card in progress", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => true})
    held = card_fixture(ctx.doing, %{"title" => "Holding"})
    {:ok, held} = Boards.update_card(held, %{"paths" => ["lib/foo/**"]})
    working_job_fixture(held)

    body =
      ctx.agent
      |> post(~p"/api/boards/#{ctx.board.id}/cards", %{
        "title" => "Overlaps",
        "column" => ctx.doing.name,
        "paths" => "lib/foo/a.ex"
      })
      |> json_response(422)

    assert inspect(body) =~ "##{held.id}"

    result =
      mcp(ctx.agent, "create_card", %{
        board: "#{ctx.board.id}",
        title: "Overlaps",
        column: ctx.doing.name,
        paths: "lib/foo/a.ex"
      })

    assert result["isError"] == true
    assert [%{"text" => text}] = result["content"]
    assert text =~ "##{held.id}"
    assert in_doing(ctx) == ["Holding"]
  end
end
