defmodule SlipdockWeb.PulseAPITest do
  @moduledoc """
  A board's pulse (#1113) through the doors agents use: `GET
  /api/boards/:board/pulse` and MCP `get_board` with `pulse: true` give the
  same numbers, on any board the caller can read, strip on or not; and
  `show_pulse` is read and set like the board's other switches.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Beat"}, owner: user)
    [_backlog, todo, doing, _done] = board.columns

    moved = card_fixture(todo, %{"title" => "Started"})
    :ok = Boards.move_card(moved.id, doing.id, nil, actor: Actor.web(user))
    card_fixture(doing, %{"title" => "Asked", "flags" => ["waiting"]})
    finished = card_fixture(todo, %{"title" => "Ticked"})
    {:ok, _} = Boards.toggle_completed(finished)

    conn = put_req_header(conn, "accept", "application/json")
    %{conn: conn, board: board, todo: todo, doing: doing}
  end

  defp rest(conn, board),
    do: conn |> get(~p"/api/boards/#{board.code}/pulse") |> json_response(200)

  defp mcp(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "get_board", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp numbers(pulse), do: Map.delete(pulse, "at")

  test "REST and MCP get_board pulse:true give the same numbers", %{conn: conn, board: board} do
    body = rest(conn, board)
    assert body["board"] == %{"id" => board.id, "code" => board.code}

    pulse = body["pulse"]
    assert pulse["in_progress"] == 2
    assert pulse["waiting"] == 1
    assert pulse["done_7d"] == 1
    assert pulse["done_today"] == 1
    assert pulse["moves_24h"] == %{"forward" => 1, "back" => 0, "total" => 1}
    lists = Map.new(pulse["lists"], &{&1["name"], &1})
    assert %{"in_7d" => 2, "out_7d" => 1, "usual_stay" => nil} = lists["To Do"]
    assert %{"in_7d" => 2, "out_7d" => 0} = lists["In Progress"]

    result = mcp(conn, %{board: board.code, pulse: true})
    assert result["isError"] == false, inspect(result["content"])
    content = result["structuredContent"]
    assert content["code"] == board.code
    refute Map.has_key?(content, "lists")
    assert numbers(content["pulse"]) == numbers(pulse)
  end

  test "without pulse, get_board still gives the lists", %{conn: conn, board: board} do
    content = mcp(conn, %{board: board.code})["structuredContent"]
    assert Enum.map(content["lists"], & &1["name"]) == ["Backlog", "To Do", "In Progress", "Done"]
    refute Map.has_key?(content, "pulse")
  end

  test "an empty board is zeros and nil percentiles", %{conn: conn, user: user} do
    empty = board_fixture(%{"name" => "Quiet"}, owner: user)
    pulse = rest(conn, empty)["pulse"]

    assert %{"in_progress" => 0, "waiting" => 0, "done_7d" => 0, "done_today" => 0} = pulse
    assert pulse["time_to_done"] == %{"p50" => nil, "p85" => nil, "cards" => 0, "lead_time" => 0}
  end

  test "a board the caller can't read is refused, on both doors", %{conn: conn} do
    theirs = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("other@example.com"))

    assert conn |> get(~p"/api/boards/#{theirs.code}/pulse") |> json_response(404)
    assert mcp(conn, %{board: theirs.code, pulse: true})["isError"] == true
  end

  test "it works with the strip off, and show_pulse is read and set", %{conn: conn, board: board} do
    refute Repo.one(
             from(b in Slipdock.Boards.Board, where: b.id == ^board.id, select: b.show_pulse)
           )

    body = conn |> get(~p"/api/boards/#{board.code}") |> json_response(200)
    assert body["board"]["show_pulse"] == false

    body =
      conn
      |> patch(~p"/api/boards/#{board.code}", %{"show_pulse" => true})
      |> json_response(200)

    assert body["board"]["show_pulse"] == true
    assert Boards.get_board!(board.id).show_pulse

    assert conn
           |> patch(~p"/api/boards/#{board.code}", %{"show_pulse" => "sometimes"})
           |> json_response(422)
  end

  test "a card made long ago and ticked off counts as lead time", %{conn: conn, board: board} do
    [_, todo | _] = Boards.get_board!(board.id).columns
    old = card_fixture(todo, %{"title" => "Old"})

    Repo.update_all(from(c in Card, where: c.id == ^old.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -3 * 86_400)]
    )

    {:ok, _} = Boards.toggle_completed(Repo.get!(Card, old.id))
    assert rest(conn, board)["pulse"]["time_to_done"]["lead_time"] == 2
  end
end
