defmodule SlipdockWeb.SharedPathsWebTest do
  @moduledoc """
  Shared paths (#1971) at the doors: set and read over REST, MCP and the
  board settings; marked in card JSON, MCP `get_card` and the card panel;
  carried by an export and an import; and an agent's start over the API
  that only overlaps inside a shared path going ahead where any other
  overlap is still refused.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Shared doors", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    running = card_fixture(doing, %{"title" => "Running"})

    {:ok, running} =
      Boards.update_card(running, %{"paths" => ["lib/runners/**", "docs/manual.md"]})

    working_job_fixture(running)
    card = card_fixture(todo, %{"title" => "Next"})
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

  test "empty by default; PATCH /api/boards sets them, as a list or a string, and refuses bad ones",
       ctx do
    board = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
    assert board["board"]["shared_paths"] == []

    resp =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{
        "shared_paths" => ["docs/manual.md", "README.md"]
      })
      |> json_response(200)

    assert resp["board"]["shared_paths"] == ["docs/manual.md", "README.md"]

    ctx.agent
    |> patch(~p"/api/boards/#{ctx.board.id}", %{"shared_paths" => "docs/**,README.md"})
    |> json_response(200)

    assert Boards.get_board!(ctx.board.id).shared_paths == ["docs/**", "README.md"]

    body =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"shared_paths" => ["/etc/passwd"]})
      |> json_response(422)

    assert inspect(body) =~ "relative"
    assert Boards.get_board!(ctx.board.id).shared_paths == ["docs/**", "README.md"]
  end

  test "MCP update_board sets them and get_board shows them; [] clears", ctx do
    result =
      mcp(ctx.agent, "update_board", %{board: "#{ctx.board.id}", shared_paths: ["docs/manual.md"]})

    assert result["isError"] == false
    assert structured(result)["lanes"] == %{"on" => false, "shared_paths" => ["docs/manual.md"]}
    assert Boards.get_board!(ctx.board.id).shared_paths == ["docs/manual.md"]

    got = mcp(ctx.agent, "get_board", %{board: "#{ctx.board.id}"}) |> structured()
    assert got["lanes"]["shared_paths"] == ["docs/manual.md"]

    result = mcp(ctx.agent, "update_board", %{board: "#{ctx.board.id}", shared_paths: []})
    assert result["isError"] == false
    assert Boards.get_board!(ctx.board.id).shared_paths == []

    refute Map.has_key?(
             mcp(ctx.agent, "get_board", %{board: "#{ctx.board.id}"}) |> structured(),
             "lanes"
           )
  end

  test "card JSON and get_card name the board's shared paths and the card's shared ones", ctx do
    refute ctx.agent
           |> get(~p"/api/cards/#{ctx.running.id}")
           |> json_response(200)
           |> get_in(["card"])
           |> Map.has_key?("shared_paths")

    {:ok, _} = Boards.update_board(ctx.board, %{"shared_paths" => ["docs/**"]})
    card = ctx.agent |> get(~p"/api/cards/#{ctx.running.id}") |> json_response(200)
    assert card["card"]["shared_paths"] == ["docs/**"]
    assert card["card"]["paths_shared"] == ["docs/manual.md"]

    got = mcp(ctx.agent, "get_card", %{card: ctx.running.id}) |> structured()
    assert got["paths_shared"] == ["docs/manual.md"]
  end

  test "lanes on: an agent starts a card that only overlaps in a shared path, not otherwise",
       ctx do
    {:ok, board} = Boards.update_board(ctx.board, %{"lanes" => true})
    {:ok, _} = Boards.update_card(ctx.card, %{"paths" => "lib/boards/**,docs/manual.md"})

    # Not shared yet: the manual holds the lane.
    ctx.agent
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.doing.id})
    |> json_response(422)

    {:ok, _} = Boards.update_board(board, %{"shared_paths" => ["docs/manual.md"]})

    ctx.agent
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"column" => ctx.doing.id})
    |> json_response(200)

    assert Repo.get!(Card, ctx.card.id).column_id == ctx.doing.id

    other = card_fixture(ctx.todo, %{"title" => "Runners too"})
    {:ok, _} = Boards.update_card(other, %{"paths" => "lib/runners/a.ex,docs/manual.md"})

    body =
      ctx.agent
      |> patch(~p"/api/cards/#{other.id}", %{"column" => ctx.doing.id})
      |> json_response(422)

    assert body["error"] =~ "##{ctx.running.id} \"Running\""
  end

  test "board settings set them one per line, and the card panel marks the shared ones", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    assert has_element?(view, "#board-shared-paths")

    view
    |> form("#board-form", board: %{"shared_paths" => "docs/manual.md\nREADME.md"})
    |> render_submit()

    assert Boards.get_board!(ctx.board.id).shared_paths == ["docs/manual.md", "README.md"]

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    assert view |> element("#board-shared-paths") |> render() =~ "docs/manual.md\nREADME.md"

    view
    |> form("#board-form", board: %{"shared_paths" => "../outside"})
    |> render_submit()

    assert render(view) =~ "stay inside the repository"
    assert Boards.get_board!(ctx.board.id).shared_paths == ["docs/manual.md", "README.md"]

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.running}")
    assert has_element?(view, "#card-paths-shared", "docs/manual.md")
    refute view |> element("#card-paths-shared") |> render() =~ "lib/runners"

    {:ok, _} = Boards.update_board(Boards.get_board!(ctx.board.id), %{"shared_paths" => []})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.running}")
    refute has_element?(view, "#card-paths-shared")
  end

  test "an export carries them and an import keeps the good ones", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"shared_paths" => ["docs/**", "README.md"]})

    doc = Slipdock.Portable.export(ctx.user, boards: [Boards.get_board!(ctx.board.id)])
    [tree] = doc.boards
    assert tree.root.shared_paths == ["docs/**", "README.md"]

    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(doc))
    assert Boards.get_board!(hd(report.boards).id).shared_paths == ["docs/**", "README.md"]

    # A hand-edited file: the bad globs go, the rest stay.
    doc = put_in(doc, [:boards, Access.at(0), :root, :shared_paths], ["/etc", "../x", "ok.md", 7])
    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(doc))
    assert Boards.get_board!(hd(report.boards).id).shared_paths == ["ok.md"]
  end

  test "the guide's board line lists them on a lanes board", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => true, "shared_paths" => ["docs/**"]})
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    assert guide =~ "shared paths (hold no lane): `docs/**`"
    assert guide =~ "**Shared paths.** A board's `shared_paths`"
  end
end
