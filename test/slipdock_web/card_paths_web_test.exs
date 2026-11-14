defmodule SlipdockWeb.CardPathsWebTest do
  @moduledoc """
  Card paths (#1628) at the doors once lanes went (#3178): written over the
  API and MCP and shown in card JSON and the card panel, carried by an
  export; an agent's move beside an overlapping card in progress goes
  ahead; no lane setting, overlap or guide section is left to read.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Path doors", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    running = card_fixture(doing, %{"title" => "Running"})
    {:ok, running} = Boards.Cards.update_card(running, %{"paths" => ["lib/runners/**"]})
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

  test "the board's JSON has no lane settings, and PATCH ignores them", ctx do
    resp =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{
        "lanes" => true,
        "lane_mode" => "hold",
        "shared_paths" => ["docs/**"]
      })
      |> json_response(200)

    refute Enum.any?(~w(lanes lane_mode shared_paths), &Map.has_key?(resp["board"], &1))
    got = mcp(ctx.agent, "get_board", %{board: "#{ctx.board.id}"})
    refute inspect(got) =~ "lane_mode"
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

  test "an agent starts a card beside an overlapping one, over PATCH and MCP", ctx do
    result = mcp(ctx.agent, "update_card", %{card: ctx.card.id, paths: ["lib/runners/b.ex"]})
    assert result["isError"] == false
    assert Repo.get!(Card, ctx.card.id).paths == ["lib/runners/b.ex"]

    got = mcp(ctx.agent, "get_card", %{card: ctx.card.id})
    assert inspect(got) =~ "lib/runners/b.ex"
    refute inspect(got) =~ "lane_overlap"

    result = mcp(ctx.agent, "move_card", %{card: ctx.card.id, column: "#{ctx.doing.id}"})
    assert result["isError"] == false
    assert Repo.get!(Card, ctx.card.id).column_id == ctx.doing.id

    other = card_fixture(ctx.todo, %{"title" => "Other"})
    {:ok, _} = Boards.Cards.update_card(other, %{"paths" => ["lib/runners/c.ex"]})

    ctx.agent
    |> patch(~p"/api/cards/#{other.id}", %{"column" => ctx.doing.id})
    |> json_response(200)

    assert Repo.get!(Card, other.id).column_id == ctx.doing.id

    card = ctx.agent |> get(~p"/api/cards/#{other.id}") |> json_response(200)
    refute Enum.any?(~w(lane_overlap paths_broad shared_paths), &Map.has_key?(card["card"], &1))
  end

  test "the guide has no Lanes section", ctx do
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    refute guide =~ "## Lanes"
    refute guide =~ "lanes: on"
  end

  test "the card panel shows the paths and no overlap; the settings page has no lanes", ctx do
    {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
    refute has_element?(view, "#board-lanes")
    refute has_element?(view, "#board-shared-paths")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    refute has_element?(view, "#card-paths")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.running}")
    assert has_element?(view, "#card-paths", "lib/runners/**")

    view
    |> form("#card-paths-form", card: %{"paths" => "lib/runners/a.ex\ndocs/x.md"})
    |> render_change()

    assert Repo.get!(Card, ctx.running.id).paths == ["lib/runners/a.ex", "docs/x.md"]
    refute has_element?(view, "#card-paths-overlap")
    refute has_element?(view, "#card-paths-broad")
  end

  test "an export carries the paths and no lane settings, and an import keeps them", ctx do
    doc = Slipdock.Portable.export(ctx.user, boards: [Boards.get_board!(ctx.board.id)])
    [tree] = doc.boards
    refute Map.has_key?(tree.root, :lane_mode)

    # An older export's lane settings are ignored.
    old =
      put_in(doc.boards, [
        Map.update!(tree, :root, &Map.merge(&1, %{lanes: true, lane_mode: "hold"}))
      ])

    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(old))
    imported = Boards.get_board!(hd(report.boards).id)
    assert Repo.get_by!(Card, board_id: imported.id, title: "Running").paths == ["lib/runners/**"]
  end
end
