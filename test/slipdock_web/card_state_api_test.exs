defmodule SlipdockWeb.CardStateAPITest do
  @moduledoc """
  A card's state through the doors agents and scripts use (#1117): `state`,
  `driver`, `age` and `stuck` on REST cards and MCP `card_line`, the
  `stuck` and `driver` filters on `GET /api/boards/:board/cards` and MCP
  `list_cards`, and the same values on a card read alone.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Runners}
  alias Slipdock.Boards.{Card, CardMove}

  setup %{user: user} do
    board = board_fixture(%{"name" => "State API"}, owner: user)
    [_backlog, todo, doing, done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "runner-2", "pool" => "dev"})
    %{user: user, board: board, todo: todo, doing: doing, done: done, runner: runner}
  end

  defp api(user) do
    {token, _} = Accounts.create_api_token(user, "script")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp mcp_json(conn, name, args) do
    %{"content" => [%{"text" => text}]} =
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
      |> Map.fetch!("result")

    Jason.decode!(text)
  end

  defp mcp_error(conn, name, args) do
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
    |> Map.fetch!("result")
  end

  defp runner_rule(board) do
    rule_fixture(board, %{
      "trigger" => %{"type" => "card_created"},
      "actions" => [%{"type" => "runner", "pool" => "elsewhere"}]
    })
  end

  defp ids(cards), do: Enum.map(cards, & &1["id"]) |> Enum.sort()

  # Eight closed 2h stays in Doing, and a card 3h into it.
  defp stuck_card(ctx) do
    start = DateTime.add(DateTime.utc_now(), -3 * 86_400)

    for _ <- 1..8 do
      card = card_fixture(ctx.done)
      Repo.delete_all(from(m in CardMove, where: m.card_id == ^card.id))

      for {kind, from, to, at} <- [
            {"created", nil, ctx.doing, start},
            {"moved", ctx.doing, ctx.done, DateTime.add(start, 7200)}
          ] do
        Repo.insert!(%CardMove{
          card_id: card.id,
          kind: kind,
          board_id: card.board_id,
          from_column_id: from && from.id,
          to_column_id: to.id,
          to_column_name: to.name,
          to_category: to.category,
          inserted_at: at
        })
      end
    end

    card = card_fixture(ctx.doing, %{"title" => "Slow"})
    at = DateTime.add(DateTime.utc_now(), -(3 * 3600 + 30))
    Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [inserted_at: at])
    card
  end

  test "a running job's line, driver and age, the same on REST, a card alone and MCP", ctx do
    card = card_fixture(ctx.doing, %{"title" => "Build"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(ctx.runner)
    {:ok, :ok} = Runners.heartbeat(ctx.runner, job.id)

    Repo.update_all(from(j in Runners.Job, where: j.id == ^job.id),
      set: [started_at: DateTime.utc_now() |> DateTime.add(-425) |> DateTime.truncate(:second)]
    )

    conn = api(ctx.user)

    [listed] =
      conn
      |> get(~p"/api/boards/#{ctx.board.code}/cards")
      |> json_response(200)
      |> Map.fetch!("cards")

    alone = conn |> get(~p"/api/cards/#{card.id}") |> json_response(200) |> Map.fetch!("card")
    [line] = mcp_json(conn, "list_cards", %{"board" => ctx.board.code})["cards"]

    for c <- [listed, alone, line] do
      assert c["state"] == "Running · runner-2 · 7m"
      assert c["driver"] == "agent"
      assert is_integer(c["age"])
    end
  end

  test "a plain board: no state and no driver keys, even for a card an agent moved", ctx do
    card = card_fixture(ctx.todo)

    Boards.move_card(card.id, ctx.doing.id, nil,
      actor: %{Actor.unknown() | kind: "agent", via: "mcp", agent: "claude"}
    )

    {:ok, _} =
      Boards.leave_handoff(Repo.get!(Card, card.id), ctx.user, %{next_step: "x", via: "ui"})

    conn = api(ctx.user)

    [c] =
      conn
      |> get(~p"/api/boards/#{ctx.board.code}/cards")
      |> json_response(200)
      |> Map.fetch!("cards")

    refute Map.has_key?(c, "state")
    refute Map.has_key?(c, "driver")
    refute Map.has_key?(c, "stuck")
    assert is_integer(c["age"])

    [line] = mcp_json(conn, "list_cards", %{"board" => ctx.board.code})["cards"]
    refute Map.has_key?(line, "state")
    refute Map.has_key?(line, "driver")
  end

  test "stuck: REST cards?stuck=true and MCP list_cards stuck:true return the stuck card", ctx do
    slow = stuck_card(ctx)
    card_fixture(ctx.doing, %{"title" => "Fresh"})
    conn = api(ctx.user)

    rest =
      conn
      |> get(~p"/api/boards/#{ctx.board.code}/cards?stuck=true")
      |> json_response(200)
      |> Map.fetch!("cards")

    assert ids(rest) == [slow.id]
    assert [%{"stuck" => true, "usual_stay" => 7200}] = rest
    assert hd(rest)["over_usual"] >= 3600

    mcp = mcp_json(conn, "list_cards", %{"board" => ctx.board.code, "stuck" => true})["cards"]
    assert ids(mcp) == [slow.id]
    assert hd(mcp)["stuck"] == true
  end

  test "driver: REST and MCP agree on agent and human", ctx do
    runner_rule(ctx.board)
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", agent: "claude"}
    by_agent = for _ <- 1..2, do: card_fixture(ctx.todo)
    Enum.each(by_agent, &Boards.move_card(&1.id, ctx.doing.id, nil, actor: agent))
    by_person = card_fixture(ctx.todo)
    Boards.move_card(by_person.id, ctx.doing.id, nil, actor: Actor.web(ctx.user))
    conn = api(ctx.user)

    rest = fn driver ->
      conn
      |> get(~p"/api/boards/#{ctx.board.code}/cards?driver=#{driver}")
      |> json_response(200)
      |> Map.fetch!("cards")
      |> ids()
    end

    mcp = fn driver ->
      ids(mcp_json(conn, "list_cards", %{"board" => ctx.board.code, "driver" => driver})["cards"])
    end

    assert rest.("agent") == Enum.sort(Enum.map(by_agent, & &1.id))
    assert mcp.("agent") == rest.("agent")
    assert rest.("human") == [by_person.id]
    assert mcp.("human") == [by_person.id]
    assert length(rest.("all")) == 3
  end

  test "a driver or stuck that isn't one of the values is refused", ctx do
    conn = api(ctx.user)

    assert %{"error" => error} =
             conn
             |> get(~p"/api/boards/#{ctx.board.code}/cards?driver=robot")
             |> json_response(400)

    assert error =~ "driver must be one of: all, agent, human"

    assert conn
           |> get(~p"/api/boards/#{ctx.board.code}/cards?stuck=maybe")
           |> json_response(400)

    assert %{"isError" => true} =
             mcp_error(conn, "list_cards", %{"board" => ctx.board.code, "driver" => "robot"})
  end
end
