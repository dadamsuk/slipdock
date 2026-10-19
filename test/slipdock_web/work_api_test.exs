defmodule SlipdockWeb.WorkAPITest do
  @moduledoc """
  Waiting on you without the UI (#1118, R16): `GET /api/work` gives the
  section with the assigned cards behind it, `GET /api/me` and MCP `whoami`
  give its count, and the plan-my-day prompt lists the same items in the
  same order.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo}
  alias Slipdock.Boards.Wait

  setup %{user: user} do
    board = board_fixture(%{"name" => "Ops"}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    other = board_fixture(%{"name" => "Side"}, owner: user)
    dana = user_fixture("dana@example.com")
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", user)
    {:ok, _} = Slipdock.Access.grant(other, dana, "write", user)
    asker = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: dana.id}
    %{board: board, todo: todo, doing: doing, other: other, dana: dana, asker: asker}
  end

  defp with_token(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "laptop", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp wait_on(ctx, card, user, seconds, attrs \\ %{}) do
    {:ok, wait} =
      Boards.open_wait(
        card,
        ctx.asker,
        Map.merge(%{"needs" => "Which region?", "on_user_id" => user.id}, attrs)
      )

    from(w in Wait, where: w.id == ^wait.id) |> Repo.update_all(set: [inserted_at: ago(seconds)])
    wait
  end

  defp mcp(conn, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
    |> json_response(200)
    |> Map.fetch!("result")
  end

  # Three things waiting on the user, made in a scrambled order.
  defp three(ctx) do
    newest = card_fixture(ctx.todo, %{"title" => "Newest"})
    wait_on(ctx, newest, ctx.user, 60, %{"choices" => ["eu", "us"]})
    oldest = card_fixture(ctx.todo, %{"title" => "Oldest"})
    wait_on(ctx, oldest, ctx.user, 9000)
    middle = card_fixture(Enum.at(ctx.other.columns, 1), %{"title" => "Middle"})
    wait_on(ctx, middle, ctx.user, 3000)
    [oldest, middle, newest]
  end

  test "GET /api/work: waiting first, oldest first, then the assigned sections", ctx do
    [oldest, middle, newest] = three(ctx)
    _due = card_fixture(ctx.todo, %{"title" => "Mine", "assignee_ids" => [ctx.user.id]})

    body = ctx.user |> with_token() |> get("/api/work") |> json_response(200)

    assert body["waiting_count"] == 3
    assert Enum.map(body["waiting"], & &1["card"]["id"]) == [oldest.id, middle.id, newest.id]

    [_, _, last] = body["waiting"]
    assert last["reason"] == "wait"
    assert last["text"] == "Waiting on you: Which region?"
    assert last["path"] == ["Ops"]
    assert last["card"]["column"] == "To Do"
    assert last["wait"]["choices"] == ["eu", "us"]
    assert last["wait"]["needs"] == "Which region?"
    assert {:ok, _, _} = DateTime.from_iso8601(last["since"])

    assert [%{"key" => "none", "label" => "No due date", "cards" => [mine]}] = body["sections"]
    assert mine["title"] == "Mine"
    assert mine["path"] == ["Ops"]
  end

  test "?board keeps to that tree; an unknown board is a 404", ctx do
    [_oldest, middle, _newest] = three(ctx)
    conn = with_token(ctx.user)

    body = conn |> get("/api/work", board: ctx.other.id) |> json_response(200)
    assert Enum.map(body["waiting"], & &1["card"]["id"]) == [middle.id]

    assert conn |> get("/api/work", board: "nowhere-at-all") |> json_response(404)
  end

  test "a board-scoped token sees only its boards' waiting and count", ctx do
    [oldest, _middle, newest] = three(ctx)
    conn = with_token(ctx.user, scope_boards: [ctx.board.id])

    body = conn |> get("/api/work") |> json_response(200)
    assert Enum.map(body["waiting"], & &1["card"]["id"]) == [oldest.id, newest.id]
    assert body["waiting_count"] == 2
    assert (conn |> get("/api/me") |> json_response(200))["waiting_on_you"] == 2
  end

  test "REST, whoami and plan-my-day agree on the items and their order", ctx do
    [oldest, middle, newest] = three(ctx)
    conn = with_token(ctx.user)

    rest = conn |> get("/api/work") |> json_response(200)
    rest_ids = Enum.map(rest["waiting"], & &1["card"]["id"])

    assert (conn |> get("/api/me") |> json_response(200))["waiting_on_you"] == 3

    whoami =
      conn
      |> mcp("tools/call", %{name: "whoami", arguments: %{}})
      |> then(fn %{"content" => [%{"text" => text}]} -> Jason.decode!(text) end)

    assert whoami["waiting_on_you"] == 3

    %{"messages" => [%{"content" => %{"text" => text}}]} =
      mcp(conn, "prompts/get", %{name: "plan-my-day", arguments: %{}})

    [_, waiting] = String.split(text, "## Waiting on you\n", parts: 2)
    [waiting, _] = String.split(waiting, "\n\n## Overdue", parts: 2)

    prompt_ids =
      for [_, id] <- Regex.scan(~r/^- #(\d+) /m, waiting), do: String.to_integer(id)

    assert prompt_ids == rest_ids
    assert rest_ids == [oldest.id, middle.id, newest.id]
  end

  test "nothing waiting: an empty section and a zero", ctx do
    conn = with_token(ctx.dana)
    body = conn |> get("/api/work") |> json_response(200)
    assert body["waiting"] == []
    assert body["waiting_count"] == 0
    assert (conn |> get("/api/me") |> json_response(200))["waiting_on_you"] == 0
  end
end
