defmodule SlipdockWeb.LanesBroadWebTest do
  @moduledoc """
  Broad lanes (#2698) at the doors: the card panel's Paths section, the
  card's REST JSON and MCP `get_card` mark a glob that claims a whole
  top-level directory, and the `lane_overlap` entry names whose glob is
  broad. Advice only: the overlapping start still goes ahead under advise.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Broad doors", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"lane_mode" => "advise"})
    [_backlog, todo, doing, _done] = board.columns
    running = card_fixture(doing, %{"title" => "Running"})
    {:ok, running} = Boards.Cards.update_card(running, %{"paths" => ["lib/**"]})
    working_job_fixture(running)
    card = card_fixture(todo, %{"title" => "Next"})

    {:ok, card} =
      Boards.Cards.update_card(card, %{"paths" => ["lib/slipdock/runners/a.ex", "docs/**"]})

    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, doing: doing, running: running, card: card, agent: agent}
  end

  defp get_card(conn, id) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "get_card", arguments: %{card: id}}
      })
    )
    |> json_response(200)
    |> get_in(["result", "content", Access.at(0), "text"])
    |> Jason.decode!()
  end

  test "the card panel marks a broad glob with the reason, and a narrow card says nothing", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-paths-broad", "docs/**")
    assert has_element?(view, "#card-paths-broad", "it overlaps most cards")
    assert has_element?(view, "#card-paths-broad", "Advice only")
    refute has_element?(view, "#card-paths-broad", "lib/slipdock/runners/a.ex")

    {:ok, _} = Boards.Cards.update_card(ctx.card, %{"paths" => ["lib/slipdock/runners/a.ex"]})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    refute has_element?(view, "#card-paths-broad")
  end

  test "a broad glob inside the board's shared paths isn't marked", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"shared_paths" => ["docs/**"]})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    refute has_element?(view, "#card-paths-broad")

    card = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    refute Map.has_key?(card["card"], "paths_broad")
  end

  test "a broad glob inside the board's shared paths names no side of the overlap", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"shared_paths" => ["docs/**"]})

    {:ok, _} =
      Boards.Cards.update_card(ctx.running, %{
        "paths" => ["lib/slipdock/runners/a.ex", "docs/a.md"]
      })

    card = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert card["card"]["lane_overlap"]["card"] == ctx.running.id
    refute Map.has_key?(card["card"]["lane_overlap"], "broad")
    refute Map.has_key?(card["card"]["lane_overlap"], "broad_paths")

    got = get_card(ctx.agent, ctx.card.id)
    assert got["lane_overlap"]["card"] == ctx.running.id
    refute Map.has_key?(got["lane_overlap"], "broad")
  end

  test "REST and get_card list the broad globs and name the broad side of the overlap", ctx do
    card = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert card["card"]["paths_broad"] == ["docs/**"]
    assert card["card"]["paths_broad_reason"] =~ "name the files or the deepest directory"

    assert card["card"]["lane_overlap"] == %{
             "card" => ctx.running.id,
             "title" => "Running",
             "mode" => "advise",
             "broad" => "other",
             "broad_paths" => ["lib/**"]
           }

    got = get_card(ctx.agent, ctx.card.id)
    assert got["paths_broad"] == ["docs/**"]
    assert got["lane_overlap"]["broad"] == "other"
    assert got["lane_overlap"]["broad_paths"] == ["lib/**"]

    # Advice, not a refusal: the start goes ahead.
    ctx.agent
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.doing.id})
    |> json_response(200)

    assert Repo.get!(Card, ctx.card.id).column_id == ctx.doing.id
  end

  test "this card's own broad glob is its side; a narrow overlap names no side", ctx do
    {:ok, _} = Boards.Cards.update_card(ctx.card, %{"paths" => ["lib/slipdock/**"]})
    got = get_card(ctx.agent, ctx.card.id)
    assert got["lane_overlap"]["broad"] == "both"
    assert got["lane_overlap"]["broad_paths"] == ["lib/slipdock/**", "lib/**"]

    {:ok, _} = Boards.Cards.update_card(ctx.running, %{"paths" => ["lib/slipdock/runners/**"]})
    {:ok, _} = Boards.Cards.update_card(ctx.card, %{"paths" => ["lib/slipdock/runners/a.ex"]})
    got = get_card(ctx.agent, ctx.card.id)
    assert got["lane_overlap"]["card"] == ctx.running.id
    refute Map.has_key?(got["lane_overlap"], "broad")
    refute Map.has_key?(got, "paths_broad")

    {:ok, _} = Boards.Cards.update_card(ctx.running, %{"paths" => ["lib/slipdock/runners/a.ex"]})
    {:ok, _} = Boards.Cards.update_card(ctx.card, %{"paths" => ["lib/**"]})
    assert get_card(ctx.agent, ctx.card.id)["lane_overlap"]["broad"] == "this"
  end
end
