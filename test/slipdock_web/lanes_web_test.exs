defmodule SlipdockWeb.LanesWebTest do
  @moduledoc """
  Lanes 2 (#1628) at the doors: the switch over the API, MCP and board
  settings; paths written over the API and MCP and shown in card JSON and
  the card panel; an agent's overlapping move refused over the API and MCP
  with the other card named, but not a person's on the CLI or in the web app.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Lane doors", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    running = card_fixture(doing, %{"title" => "Running"})
    {:ok, running} = Boards.update_card(running, %{"paths" => ["lib/runners/**"]})
    working_job_fixture(running)
    card = card_fixture(todo, %{"title" => "Next"})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    person = put_req_header(agent, "x-slipdock-client", "cli")

    %{
      board: board,
      todo: todo,
      doing: doing,
      running: running,
      card: card,
      agent: agent,
      person: person
    }
  end

  defp on(ctx), do: Boards.update_board(ctx.board, %{"lanes" => true})

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

  test "the switch is off by default; PATCH /api/boards and MCP update_board turn it", ctx do
    board = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
    assert board["board"]["lanes"] == false

    resp =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"lanes" => true})
      |> json_response(200)

    assert resp["board"]["lanes"] == true

    result = mcp(ctx.agent, "update_board", %{board: "#{ctx.board.id}", lanes: false})
    assert result["isError"] == false
    refute Boards.get_board!(ctx.board.id).lanes
  end

  test "paths are written over PATCH, shown in card JSON, and left out when there are none",
       ctx do
    refute ctx.agent
           |> get(~p"/api/cards/#{ctx.card.id}")
           |> json_response(200)
           |> get_in(["card"])
           |> Map.has_key?("paths")

    card =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"paths" => ["lib/boards/**", "docs/x.md"]})
      |> json_response(200)

    assert card["card"]["paths"] == ["lib/boards/**", "docs/x.md"]

    body =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"paths" => "/etc/passwd"})
      |> json_response(422)

    assert inspect(body) =~ "relative"
  end

  test "off: an agent starts an overlapping card", ctx do
    {:ok, _} = Boards.update_card(ctx.card, %{"paths" => "lib/runners/a.ex"})

    ctx.agent
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.doing.id})
    |> json_response(200)

    assert Repo.get!(Card, ctx.card.id).column_id == ctx.doing.id
  end

  test "on: an agent is refused over PATCH and move, naming the card; a person on the CLI is not",
       ctx do
    {:ok, _} = on(ctx)
    {:ok, _} = Boards.update_card(ctx.card, %{"paths" => "lib/runners/a.ex"})

    body =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.doing.id})
      |> json_response(422)

    assert body["error"] =~ "##{ctx.running.id} \"Running\""

    ctx.agent
    |> post(~p"/api/cards/#{ctx.card.id}/move", %{"column" => ctx.doing.id})
    |> json_response(422)

    assert Repo.get!(Card, ctx.card.id).column_id == ctx.todo.id

    ctx.person
    |> post(~p"/api/cards/#{ctx.card.id}/move", %{"column" => ctx.doing.id})
    |> json_response(200)

    assert Repo.get!(Card, ctx.card.id).column_id == ctx.doing.id
  end

  test "on: MCP writes paths with update_card, and move_card refuses with the reason", ctx do
    {:ok, _} = on(ctx)

    result = mcp(ctx.agent, "update_card", %{card: ctx.card.id, paths: ["lib/runners/b.ex"]})
    assert result["isError"] == false
    assert Repo.get!(Card, ctx.card.id).paths == ["lib/runners/b.ex"]

    got = mcp(ctx.agent, "get_card", %{card: ctx.card.id})
    assert inspect(got) =~ "lib/runners/b.ex"

    result = mcp(ctx.agent, "move_card", %{card: ctx.card.id, column: "#{ctx.doing.id}"})
    assert result["isError"] == true
    assert [%{"text" => text}] = result["content"]
    assert text =~ "##{ctx.running.id}"

    result = mcp(ctx.agent, "update_card", %{card: ctx.card.id, paths: ["docs/**"]})
    assert result["isError"] == false
    result = mcp(ctx.agent, "move_card", %{card: ctx.card.id, column: "#{ctx.doing.id}"})
    assert result["isError"] == false
  end

  test "the guide describes lanes only when a board has them on", ctx do
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    refute guide =~ "## Lanes"
    refute guide =~ "lanes: on"

    {:ok, _} = on(ctx)
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    assert guide =~ "## Lanes"
    assert guide =~ "lanes: on — write a card's paths before starting it"
  end

  test "board settings turn it on, and the card panel shows the paths and the overlap", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    refute has_element?(view, "#board-lanes[checked]")
    view |> form("#board-form", board: %{"lanes" => "true"}) |> render_submit()
    assert Boards.get_board!(ctx.board.id).lanes

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-paths")
    refute has_element?(view, "#card-paths-overlap")

    view
    |> form("#card-paths-form", card: %{"paths" => "lib/runners/a.ex\ndocs/x.md"})
    |> render_change()

    assert Repo.get!(Card, ctx.card.id).paths == ["lib/runners/a.ex", "docs/x.md"]
    assert has_element?(view, "#card-paths-overlap", "Overlaps ##{ctx.running.id} Running")

    # A person moving it is the override.
    :ok = Boards.move_card(ctx.card.id, ctx.doing.id, nil, actor: Slipdock.Actor.web(ctx.user))
    assert Repo.get!(Card, ctx.card.id).column_id == ctx.doing.id
  end

  test "with the switch off and no paths, the card panel has no paths section", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    refute has_element?(view, "#card-paths")

    # Off, a card with paths shows them, and no overlap is claimed.
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.running}")
    assert has_element?(view, "#card-paths", "lib/runners/**")
    refute has_element?(view, "#card-paths-overlap")
  end

  test "an export carries the switch and the paths, and an import keeps them", ctx do
    {:ok, _} = on(ctx)

    doc = Slipdock.Portable.export(ctx.user, boards: [Boards.get_board!(ctx.board.id)])
    [tree] = doc.boards
    assert tree.root.lanes

    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(doc))
    imported = Boards.get_board!(hd(report.boards).id)
    assert imported.lanes
    assert Repo.get_by!(Card, board_id: imported.id, title: "Running").paths == ["lib/runners/**"]
  end
end
