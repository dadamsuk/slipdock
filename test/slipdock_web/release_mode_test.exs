defmodule SlipdockWeb.ReleaseModeTest do
  @moduledoc """
  Batched releases at every door (#2834): `release_mode` and
  `release_age_cap_hours` through `PATCH /api/boards/:id` (a sub-board's
  refused, naming the root, and read back as the root's), MCP
  `update_board` and `list_boards`, the Agentic Building page (a sub-board
  shows them read-only); and a merged
  card's `release` in the card JSON, `get_card` and the card panel.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Deployments, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Rel", "code" => unique_code()}, owner: user)

    {:ok, board} =
      Boards.update_board(board, %{"delivery_metrics" => true, "agentic_building" => true})

    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    [_backlog, todo | _] = board.columns
    %{board: board, agent: agent, todo: todo}
  end

  defp mcp(conn, tool, args) do
    result =
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

    [%{"text" => text}] = result["content"]
    {result["isError"], text}
  end

  defp sub!(todo) do
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card_fixture(todo, %{"title" => "Epic"}), t)
    sub
  end

  defp merge!(card) do
    Repo.update_all(
      from(c in Card, where: c.id == ^card.id),
      set: [
        completed: true,
        completed_at: ~U[2026-11-12 10:04:00Z],
        verify_state: "accepted",
        merge_sha: "abc1234def5678"
      ]
    )

    Repo.get!(Card, card.id)
  end

  describe "PATCH /api/boards/:id" do
    test "sets both and the board's JSON reads them back", %{agent: agent, board: board} do
      json = agent |> get(~p"/api/boards/#{board.id}") |> json_response(200)

      assert {json["board"]["release_mode"], json["board"]["release_age_cap_hours"]} ==
               {"on_merge", nil}

      json =
        agent
        |> patch(~p"/api/boards/#{board.id}", %{
          "release_mode" => "batched",
          "release_age_cap_hours" => 24
        })
        |> json_response(200)

      assert json["board"]["release_mode"] == "batched"
      assert json["board"]["release_age_cap_hours"] == 24

      json = agent |> get(~p"/api/boards/#{board.id}") |> json_response(200)
      assert json["board"]["release_mode"] == "batched"
    end

    test "a bad mode is a 422", %{agent: agent, board: board} do
      body =
        agent
        |> patch(~p"/api/boards/#{board.id}", %{"release_mode" => "nightly"})
        |> json_response(422)

      assert inspect(body) =~ "must be on_merge or batched"
    end

    test "a sub-board's is refused, naming the root, and reads the root's", %{
      agent: agent,
      board: board,
      todo: todo
    } do
      sub = sub!(todo)

      body =
        agent
        |> patch(~p"/api/boards/#{sub.id}", %{"release_mode" => "batched"})
        |> json_response(422)

      assert inspect(body) =~ "is set on the tree's root board (#{board.code})"

      {:ok, _} =
        Boards.update_board(board, %{"release_mode" => "batched", "release_age_cap_hours" => 6})

      json = agent |> get(~p"/api/boards/#{sub.id}") |> json_response(200)

      assert {json["board"]["release_mode"], json["board"]["release_age_cap_hours"]} ==
               {"batched", 6}
    end
  end

  describe "a board's summary" do
    test "a sub-board's reads the root's mode and cap, not its own columns", %{
      board: board,
      todo: todo
    } do
      {:ok, _} =
        Boards.update_board(board, %{"release_mode" => "batched", "release_age_cap_hours" => 6})

      sub = sub!(todo)
      assert {sub.release_mode, sub.release_age_cap_hours} == {"on_merge", nil}

      summary = SlipdockWeb.API.JSON.board_summary(sub)
      assert {summary.release_mode, summary.release_age_cap_hours} == {"batched", 6}
    end

    test "GET /api/boards gives each board's", %{agent: agent, board: board} do
      {:ok, _} =
        Boards.update_board(board, %{"release_mode" => "batched", "release_age_cap_hours" => 6})

      listed =
        agent
        |> get(~p"/api/boards")
        |> json_response(200)
        |> Map.fetch!("boards")
        |> Enum.find(&(&1["id"] == board.id))

      assert {listed["release_mode"], listed["release_age_cap_hours"]} == {"batched", 6}
    end
  end

  describe "MCP" do
    test "update_board sets them and list_boards shows a batched tree", %{
      agent: agent,
      board: board
    } do
      {_, text} = mcp(agent, "list_boards", %{})
      refute Enum.find(Jason.decode!(text)["boards"], &(&1["id"] == board.id))["release"]

      {false, _} =
        mcp(agent, "update_board", %{
          board: "#{board.id}",
          release_mode: "batched",
          release_age_cap_hours: 48
        })

      assert %{release_mode: "batched", release_age_cap_hours: 48} = Boards.get_board!(board.id)

      {_, text} = mcp(agent, "list_boards", %{})

      assert Enum.find(Jason.decode!(text)["boards"], &(&1["id"] == board.id))["release"] ==
               %{"mode" => "batched", "age_cap_hours" => 48}

      {false, _} = mcp(agent, "update_board", %{board: "#{board.id}", release_age_cap_hours: nil})
      assert Boards.get_board!(board.id).release_age_cap_hours == nil
    end
  end

  describe "the Agentic Building page" do
    test "the owner sets them, and the strip says so", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/agentic")
      assert has_element?(view, "#board-release-mode")

      view
      |> form("#agentic-form",
        board: %{"release_mode" => "batched", "release_age_cap_hours" => "12"}
      )
      |> render_submit()

      assert %{release_mode: "batched", release_age_cap_hours: 12} = Boards.get_board!(board.id)
      assert render(view) =~ "at most 12h"
    end

    test "the strip is off on an on_merge board, even with a cap left set", %{
      conn: conn,
      board: board
    } do
      {:ok, _} = Boards.update_board(board, %{"release_age_cap_hours" => 12})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/agentic")
      assert has_element?(view, ~s(#agentic-rule-release[data-on=false]))
      refute element(view, "#agentic-rule-release") |> render() =~ "at most"

      {:ok, _} = Boards.update_board(board, %{"release_mode" => "batched"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/agentic")
      assert has_element?(view, ~s(#agentic-rule-release[data-on=true]), "at most 12h")
    end

    test "a sub-board's strip reads the root's", %{conn: conn, board: board, todo: todo} do
      {:ok, _} =
        Boards.update_board(board, %{"release_mode" => "batched", "release_age_cap_hours" => 8})

      sub = sub!(todo)
      {:ok, view, _} = live(conn, ~p"/boards/#{sub}/agentic")
      assert has_element?(view, ~s(#agentic-rule-release[data-on=true]), "at most 8h")
    end

    test "a sub-board's read-only text: batched with no cap, and on merge", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      sub = sub!(todo)

      {:ok, view, _} = live(conn, ~p"/boards/#{sub}/agentic")
      assert element(view, "#board-releases-read") |> render() =~ "On merge: each merge deploys."
      refute element(view, "#board-releases-read") |> render() =~ "Batched"

      {:ok, _} = Boards.update_board(board, %{"release_mode" => "batched"})
      {:ok, view, _} = live(conn, ~p"/boards/#{sub}/agentic")

      assert element(view, "#board-releases-read") |> render() =~
               "Batched: merges wait for a release, with no age cap."
    end

    test "a sub-board shows the root's, read-only, linking to it", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      {:ok, _} =
        Boards.update_board(board, %{"release_mode" => "batched", "release_age_cap_hours" => 8})

      sub = sub!(todo)

      {:ok, view, _} = live(conn, ~p"/boards/#{sub}/agentic")
      refute has_element?(view, "#board-release-mode")
      assert has_element?(view, "#board-releases-read", "at most 8 hours")

      assert has_element?(
               view,
               ~s(#board-releases [data-role=set-on-root] a[href="/boards/#{board.id}/agentic"])
             )
    end
  end

  test "the app's help says what batched releases are and where they are set", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/boards")
    assert html =~ "Batched releases"
    assert html =~ "merged, awaiting release"
  end

  describe "a card's release" do
    test "nothing on an on_merge board", %{conn: conn, agent: agent, todo: todo} do
      card = todo |> card_fixture(%{"title" => "Feature"}) |> merge!()
      body = agent |> get(~p"/api/cards/#{card.id}") |> json_response(200)
      refute Map.has_key?(body["card"], "release")

      {_, text} = mcp(conn, "get_card", %{card: card.id})
      refute Map.has_key?(Jason.decode!(text), "release")
    end

    test "awaiting, then released, in the JSON, get_card and the panel", %{
      conn: conn,
      agent: agent,
      board: board,
      todo: todo
    } do
      {:ok, board} = Boards.update_board(board, %{"release_mode" => "batched"})
      card = todo |> card_fixture(%{"title" => "Feature"}) |> merge!()

      body = agent |> get(~p"/api/cards/#{card.id}") |> json_response(200)

      assert %{
               "state" => "awaiting",
               "sha" => "abc1234def5678",
               "text" => "Merged abc1234, awaiting release · since 12 Nov 10:04"
             } = body["card"]["release"]

      # Still done: the release doesn't change that.
      assert body["card"]["completed"] == true

      {_, text} = mcp(conn, "get_card", %{card: card.id})
      assert Jason.decode!(text)["release"]["state"] == "awaiting"

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      assert has_element?(view, ~s(#card-release[data-state=awaiting]), "awaiting release")

      {:ok, _} =
        Deployments.start(board, %{
          environment: "production",
          sha: "abc1234def5678",
          status: "succeeded",
          started_at: ~U[2026-11-12 14:32:00.000000Z],
          finished_at: ~U[2026-11-12 14:32:00.000000Z],
          commits: [%{"sha" => "abc1234def5678", "subject" => "feat ##{card.id}"}]
        })

      body = agent |> get(~p"/api/cards/#{card.id}") |> json_response(200)

      assert %{"state" => "released", "environment" => "production", "text" => released} =
               body["card"]["release"]

      assert released == "Released to production · 12 Nov 14:32"

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      assert has_element?(view, ~s(#card-release[data-state=released]), released)
    end
  end
end
