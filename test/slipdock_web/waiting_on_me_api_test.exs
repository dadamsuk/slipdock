defmodule SlipdockWeb.WaitingOnMeApiTest do
  @moduledoc """
  `waiting_on_me` (#2095) at REST and MCP `get_card` / `get_board`: what in
  an epic's tree, or a board's, waits on the caller, with each card's
  reason as the same `Slipdock.Work` item `GET /api/work` gives.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards}

  setup do
    owner = user_fixture("wom-owner@example.com")
    dana = user_fixture("wom-dana@example.com")
    board = board_fixture(%{"name" => "Doors", "code" => unique_code()}, owner: owner)
    [_backlog, todo | _] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)

    epic = card_fixture(todo, %{"title" => "Epic"})
    plain = card_fixture(todo, %{"title" => "Plain"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    asked = card_fixture(hd(sub.columns), %{"title" => "Region"})
    theirs = card_fixture(hd(sub.columns), %{"title" => "Hers"})

    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id}
    {:ok, _} = Boards.open_wait(asked, agent, %{"needs" => "EU or US?", "on_user_id" => owner.id})
    {:ok, _} = Boards.open_wait(theirs, agent, %{"needs" => "Copy?", "on_user_id" => dana.id})

    %{owner: owner, board: board, epic: epic, plain: plain, asked: asked, theirs: theirs}
  end

  defp with_token(user) do
    {token, _} = Accounts.create_api_token(user, "laptop")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp mcp(conn, name, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })
    )
    |> json_response(200)
    |> then(fn %{"result" => %{"content" => [%{"text" => text}]}} -> Jason.decode!(text) end)
  end

  defp work_item(conn, card_id) do
    conn
    |> get("/api/work")
    |> json_response(200)
    |> Map.fetch!("waiting")
    |> Enum.find(&(&1["card"]["id"] == card_id))
  end

  defp assert_epic_entry(entry, ctx) do
    assert entry["count"] == 1
    assert entry["on_others"] == 1
    assert [card] = entry["cards"]
    assert card["card"]["id"] == ctx.asked.id
    assert card["reason"] == "wait"
    assert card["short"] == "a question"

    assert entry["line"] ==
             "Waiting on you: ##{ctx.asked.id} (a question) and 1 on someone else"

    card
  end

  describe "REST" do
    test "GET /api/cards/:epic carries its tree's, the same item as /api/work", ctx do
      conn = with_token(ctx.owner)
      body = conn |> get("/api/cards/#{ctx.epic.id}") |> json_response(200)
      item = assert_epic_entry(body["card"]["waiting_on_me"], ctx)

      # The same object My work gives, plus its short reason.
      assert Map.delete(item, "short") == work_item(with_token(ctx.owner), ctx.asked.id)
    end

    test "a card with no subcards carries zeros", ctx do
      body = ctx.owner |> with_token() |> get("/api/cards/#{ctx.plain.id}") |> json_response(200)

      assert body["card"]["waiting_on_me"] == %{
               "count" => 0,
               "cards" => [],
               "on_others" => 0,
               "line" => nil
             }
    end

    test "GET /api/boards/:board carries the tree's, and each epic its own", ctx do
      body = ctx.owner |> with_token() |> get("/api/boards/#{ctx.board.id}") |> json_response(200)
      board = body["board"]
      assert board["waiting_on_me"]["count"] == 1
      assert board["waiting_on_me"]["on_others"] == 1

      cards = Enum.flat_map(board["columns"], & &1["cards"])
      epic = Enum.find(cards, &(&1["id"] == ctx.epic.id))
      plain = Enum.find(cards, &(&1["id"] == ctx.plain.id))
      assert_epic_entry(epic["waiting_on_me"], ctx)
      refute Map.has_key?(plain, "waiting_on_me")
    end
  end

  describe "MCP" do
    test "get_card carries the epic's tree's", ctx do
      card = ctx.owner |> with_token() |> mcp("get_card", %{card: ctx.epic.id})
      assert_epic_entry(card["waiting_on_me"], ctx)
    end

    test "get_board carries the tree's, and each epic its own", ctx do
      board = ctx.owner |> with_token() |> mcp("get_board", %{board: ctx.board.code})
      assert board["waiting_on_me"]["count"] == 1

      cards = Enum.flat_map(board["lists"], & &1["cards"])
      assert_epic_entry(Enum.find(cards, &(&1["id"] == ctx.epic.id))["waiting_on_me"], ctx)
      refute Map.has_key?(Enum.find(cards, &(&1["id"] == ctx.plain.id)), "waiting_on_me")
    end
  end
end
