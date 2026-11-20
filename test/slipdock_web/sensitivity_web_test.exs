defmodule SlipdockWeb.SensitivityWebTest do
  @moduledoc """
  A tree's sensitivity (#3552) at the doors: `PATCH /api/boards/:id` and
  the board JSON (a sub-board's write refused, naming the root, and read
  back as the root's), MCP `update_board`, the Agentic Building page (a
  sub-board shows the root's, read-only) and the guide's board line, which
  names a level other than medium.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Sense", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"agentic_building" => true})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    [_backlog, todo | _] = board.columns
    %{board: board, agent: agent, todo: todo}
  end

  defp sub!(todo) do
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card_fixture(todo, %{"title" => "Epic"}), t)
    sub
  end

  describe "REST" do
    test "PATCH sets it and the board JSON reads it; a bad level is a 422", %{
      agent: agent,
      board: board
    } do
      assert agent
             |> get(~p"/api/boards/#{board.id}")
             |> json_response(200)
             |> get_in(["board", "sensitivity"]) ==
               "medium"

      body =
        agent
        |> patch(~p"/api/boards/#{board.id}", %{"sensitivity" => "low"})
        |> json_response(200)

      assert body["board"]["sensitivity"] == "low"
      assert Boards.get_board!(board.id).sensitivity == "low"

      body =
        agent
        |> patch(~p"/api/boards/#{board.id}", %{"sensitivity" => "extreme"})
        |> json_response(422)

      assert inspect(body) =~ "must be low, medium or high"
      assert Boards.get_board!(board.id).sensitivity == "low"
    end

    test "a sub-board's write is refused and its JSON reads the root's", %{
      agent: agent,
      board: board,
      todo: todo
    } do
      sub = sub!(todo)
      {:ok, _} = Boards.update_board(board, %{"sensitivity" => "high"})

      body =
        agent |> patch(~p"/api/boards/#{sub.id}", %{"sensitivity" => "low"}) |> json_response(422)

      assert inspect(body) =~ "root board (##{board.id})"

      assert agent
             |> get(~p"/api/boards/#{sub.id}")
             |> json_response(200)
             |> get_in(["board", "sensitivity"]) ==
               "high"
    end
  end

  test "MCP update_board sets it", %{agent: agent, board: board} do
    {false, _} =
      call_mcp_tool(agent, "update_board", %{board: "#{board.id}", sensitivity: "high"})

    assert Boards.get_board!(board.id).sensitivity == "high"

    {true, text} =
      call_mcp_tool(agent, "update_board", %{board: "#{board.id}", sensitivity: "nope"})

    assert text =~ "low, medium or high"
  end

  describe "the Agentic Building page" do
    test "the owner sets it, and the strip says so", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/agentic")
      assert has_element?(view, ~s(#agentic-rule-sensitivity[data-on=false]))

      view
      |> form("#agentic-form", board: %{"sensitivity" => "low"})
      |> render_submit()

      assert Boards.get_board!(board.id).sensitivity == "low"
      assert has_element?(view, ~s(#agentic-rule-sensitivity[data-on=true]), "low")
    end

    test "a sub-board shows the root's, read-only", %{conn: conn, board: board, todo: todo} do
      sub = sub!(todo)
      {:ok, _} = Boards.update_board(board, %{"sensitivity" => "high"})
      {:ok, view, _} = live(conn, ~p"/boards/#{sub}/agentic")
      refute has_element?(view, "#board-sensitivity-level")
      assert element(view, "#board-sensitivity-read") |> render() =~ "High: agents ask more"
    end
  end

  test "the guide's board line names a level other than medium", %{agent: agent, board: board} do
    guide = agent |> get(~p"/api/guide") |> response(200)
    refute guide =~ "sensitivity: "

    {:ok, _} = Boards.update_board(board, %{"sensitivity" => "low"})
    guide = agent |> get(~p"/api/guide") |> response(200)
    assert guide =~ "sensitivity: low — decide implementation choices yourself"
  end
end
