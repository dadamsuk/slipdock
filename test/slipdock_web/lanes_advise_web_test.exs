defmodule SlipdockWeb.LanesAdviseWebTest do
  @moduledoc """
  Advisory lanes (#1972) at the doors: the mode set and read over REST, MCP
  and the board settings, `lanes: true` still meaning `hold`; an agent's
  overlapping start over the API going ahead under `advise`; the overlap
  shown as advisory in the card panel and card JSON; and an export and an
  import carrying the mode.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Advise doors", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    running = card_fixture(doing, %{"title" => "Running"})
    {:ok, running} = Boards.update_card(running, %{"paths" => ["lib/runners/**"]})
    working_job_fixture(running)
    card = card_fixture(todo, %{"title" => "Next"})
    {:ok, card} = Boards.update_card(card, %{"paths" => ["lib/runners/a.ex"]})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, todo: todo, doing: doing, running: running, card: card, agent: agent}
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

  defp structured(result) do
    [%{"text" => text}] = result["content"]
    Jason.decode!(text)
  end

  test "REST: lane_mode is read and written, lanes: true still means hold, a bad mode is refused",
       ctx do
    board = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
    assert {board["board"]["lanes"], board["board"]["lane_mode"]} == {false, "off"}

    resp =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"lane_mode" => "advise"})
      |> json_response(200)

    assert {resp["board"]["lanes"], resp["board"]["lane_mode"]} == {true, "advise"}

    resp =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"lanes" => true})
      |> json_response(200)

    assert resp["board"]["lane_mode"] == "hold"

    body =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"lane_mode" => "loose"})
      |> json_response(422)

    assert inspect(body) =~ "off, hold, advise"
  end

  test "MCP: update_board sets lane_mode, get_board says the mode", ctx do
    result = mcp(ctx.agent, "update_board", %{board: "#{ctx.board.id}", lane_mode: "advise"})
    assert result["isError"] == false
    assert structured(result)["lanes"]["mode"] == "advise"

    got = mcp(ctx.agent, "get_board", %{board: "#{ctx.board.id}"}) |> structured()
    assert got["lanes"] == %{"on" => true, "mode" => "advise", "shared_paths" => []}

    result = mcp(ctx.agent, "update_board", %{board: "#{ctx.board.id}", lanes: false})
    assert result["isError"] == false
    assert Boards.get_board!(ctx.board.id).lane_mode == "off"
  end

  test "under advise an agent's overlapping start over the API goes ahead, and the card JSON says so",
       ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"lane_mode" => "advise"})

    card = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)

    assert card["card"]["lane_overlap"] == %{
             "card" => ctx.running.id,
             "title" => "Running",
             "mode" => "advise"
           }

    ctx.agent
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.doing.id})
    |> json_response(200)

    assert Repo.get!(Card, ctx.card.id).column_id == ctx.doing.id

    got = mcp(ctx.agent, "get_card", %{card: ctx.card.id}) |> structured()
    assert got["lane_overlap"]["mode"] == "advise"
  end

  test "under hold the card JSON's overlap says hold; with lanes off there is none", ctx do
    refute ctx.agent
           |> get(~p"/api/cards/#{ctx.card.id}")
           |> json_response(200)
           |> get_in(["card"])
           |> Map.has_key?("lane_overlap")

    {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => true})
    card = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert card["card"]["lane_overlap"]["mode"] == "hold"
  end

  test "board settings choose the mode; the card panel calls the overlap advisory", ctx do
    {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
    view |> form("#agentic-form", board: %{"lane_mode" => "advise"}) |> render_submit()
    assert Boards.get_board!(ctx.board.id).lane_mode == "advise"
    assert Boards.get_board!(ctx.board.id).lanes

    {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
    assert has_element?(view, "#board-lanes option[value=advise][selected]")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-paths-overlap", "in progress, advisory")
    refute has_element?(view, "#card-paths-overlap", "can't start")

    {:ok, _} = Boards.update_board(Boards.get_board!(ctx.board.id), %{"lane_mode" => "hold"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-paths-overlap", "an agent can't start this card")
  end

  test "an export carries the mode; an import keeps it, and an older file's lanes is hold", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"lane_mode" => "advise"})
    doc = Slipdock.Portable.export(ctx.user, boards: [Boards.get_board!(ctx.board.id)])
    [tree] = doc.boards
    assert tree.root.lane_mode == "advise"

    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(doc))
    imported = Boards.get_board!(hd(report.boards).id)
    assert {imported.lane_mode, imported.lanes} == {"advise", true}

    older =
      update_in(
        doc,
        [:boards, Access.at(0), :root],
        &(&1 |> Map.delete(:lane_mode) |> Map.put(:lanes, true))
      )

    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(older))
    assert Boards.get_board!(hd(report.boards).id).lane_mode == "hold"
  end
end
