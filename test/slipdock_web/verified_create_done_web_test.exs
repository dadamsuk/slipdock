defmodule SlipdockWeb.VerifiedCreateDoneWebTest do
  @moduledoc """
  #1918 at the doors: an agent creating a card straight into a done list
  over REST (`slipdock add --column Done`) and MCP `create_card` meets what
  completing it would (evidence, verification), and a person on the CLI
  doesn't.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Created done", "code" => unique_code()}, owner: user)
    [_backlog, _todo, _doing, done] = board.columns
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    person = put_req_header(agent, "x-slipdock-client", "cli")
    %{board: board, done: done, agent: agent, person: person}
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

  defp in_done(ctx),
    do: Repo.all(from(c in Card, where: c.column_id == ^ctx.done.id, select: c.title))

  defp create(conn, ctx, attrs),
    do:
      post(
        conn,
        ~p"/api/boards/#{ctx.board.id}/cards",
        Map.merge(%{"column" => ctx.done.name}, attrs)
      )

  describe "with evidence_required on" do
    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"evidence_required" => true})
      %{board: board}
    end

    test "REST refuses an agent's card in a done list with no evidence, and makes none", ctx do
      body = ctx.agent |> create(ctx, %{"title" => "Sneaked in"}) |> json_response(422)

      assert inspect(body) =~ "evidence"
      assert in_done(ctx) == []
    end

    test "REST makes an agent's card in a done list with evidence", ctx do
      ctx.agent
      |> create(ctx, %{"title" => "Shown", "evidence" => "Ran the tests"})
      |> json_response(201)

      assert in_done(ctx) == ["Shown"]
    end

    test "a person on the CLI needs none", ctx do
      ctx.person |> create(ctx, %{"title" => "Theirs"}) |> json_response(201)
      assert in_done(ctx) == ["Theirs"]
    end

    test "MCP create_card refuses an agent's card in a done list, saying where to go", ctx do
      result =
        mcp(ctx.agent, "create_card", %{
          board: "#{ctx.board.id}",
          title: "Sneaked in",
          column: ctx.done.name
        })

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "evidence"
      assert text =~ "complete_card"
      assert in_done(ctx) == []
    end
  end

  describe "with verify_work on" do
    setup ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

      %{board: board}
    end

    test "REST refuses an agent's card in a done list, whatever its evidence", ctx do
      body =
        ctx.agent
        |> create(ctx, %{
          "title" => "Self-accepted",
          "evidence" => "x",
          "evidence_pr" => "https://example.com/pr/1"
        })
        |> json_response(422)

      assert inspect(body) =~ "verifies work"
      assert in_done(ctx) == []
    end

    test "MCP create_card refuses an agent's card in a done list", ctx do
      result =
        mcp(ctx.agent, "create_card", %{
          board: "#{ctx.board.id}",
          title: "Self-accepted",
          column: ctx.done.name
        })

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "verifies work"
      assert in_done(ctx) == []
    end

    test "a person on the CLI still creates one there", ctx do
      ctx.person |> create(ctx, %{"title" => "Theirs"}) |> json_response(201)
      assert in_done(ctx) == ["Theirs"]
    end
  end
end
