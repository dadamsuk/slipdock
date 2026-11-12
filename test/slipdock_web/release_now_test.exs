defmodule SlipdockWeb.ReleaseNowTest do
  @moduledoc """
  *Release now* and the release command at every door (#2835): REST
  `GET`/`POST /api/boards/:board/release` (the owner's; a board that
  releases on merge refused), MCP `release_now` (and `check`), the board's
  release banner and the Agentic Building page's button, `release_command`
  through `PATCH /api/boards/:id`, `update_board`, the page and a portable
  export; and the release job as a runner claims it over HTTP.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Releases, Repo, Runners}
  alias Slipdock.Boards.Card
  alias Slipdock.Releases.Request
  alias Slipdock.Runners.Job

  setup %{user: user} do
    user = user |> Ecto.Changeset.change(name: "Dana") |> Repo.update!()
    board = board_fixture(%{"name" => "Rel now", "code" => unique_code()}, owner: user)

    {:ok, board} =
      Boards.update_board(board, %{
        "delivery_metrics" => true,
        "agentic_building" => true,
        "release_mode" => "batched"
      })

    {:ok, runner, runner_token} =
      Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})

    Runners.report_kinds(runner, "merge,release")

    [_backlog, todo | _] = board.columns

    %{
      user: user,
      board: board,
      todo: todo,
      agent: with_token(user, "bot"),
      runner_token: runner_token
    }
  end

  defp with_token(user, label) do
    {token, _} = Accounts.create_api_token(user, label)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
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
    {result["isError"] == true, text}
  end

  defp merged!(todo, title) do
    card = card_fixture(todo, %{"title" => title})

    Repo.update_all(
      from(c in Card, where: c.id == ^card.id),
      set: [
        completed: true,
        completed_at: ~U[2026-11-12 10:04:00Z],
        verify_state: "accepted",
        merge_sha: "abc1234def5678"
      ]
    )

    card
  end

  describe "REST" do
    test "GET says where releases stand; POST starts one, queues one, joins it", ctx do
      card = merged!(ctx.todo, "Feature")

      body = ctx.agent |> get(~p"/api/boards/#{ctx.board.code}/release") |> json_response(200)

      assert %{"mode" => "batched", "running" => nil, "queued" => nil, "last" => nil} =
               body["release"]

      assert [%{"id" => id, "title" => "Feature", "merged_at" => _}] = body["release"]["awaiting"]
      assert id == card.id

      body = ctx.agent |> post(~p"/api/boards/#{ctx.board.code}/release") |> json_response(201)
      assert body["how"] == "started"
      assert body["line"] =~ "Release started"
      assert body["request"]["status"] == "running"
      assert body["request"]["card_ids"] == [card.id]
      assert [%{"trigger" => "manual", "by" => by}] = body["request"]["triggers"]
      # An API token is named by its label.
      assert by =~ "bot"
      assert body["release"]["running"]["id"] == body["request"]["id"]
      assert Repo.get!(Job, body["request"]["job_id"]).kind == "release"

      assert %{"how" => "queued"} =
               ctx.agent |> post(~p"/api/boards/#{ctx.board.id}/release") |> json_response(201)

      body = ctx.agent |> post(~p"/api/boards/#{ctx.board.id}/release") |> json_response(201)
      assert body["how"] == "joined"
      assert length(body["request"]["triggers"]) == 2
      assert Repo.aggregate(Request, :count) == 2
    end

    test "a board that releases on merge answers 409 and starts nothing", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})

      body = ctx.agent |> post(~p"/api/boards/#{ctx.board.id}/release") |> json_response(409)
      assert inspect(body) =~ "releases on merge"
      assert Repo.aggregate(Request, :count) == 0

      assert %{"release" => %{"mode" => "on_merge", "awaiting" => []}} =
               ctx.agent |> get(~p"/api/boards/#{ctx.board.id}/release") |> json_response(200)
    end

    test "someone the board is shared with can read but not release", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")
      conn = with_token(editor, "theirs")

      assert conn |> get(~p"/api/boards/#{ctx.board.id}/release") |> json_response(200)
      assert conn |> post(~p"/api/boards/#{ctx.board.id}/release") |> json_response(403)
      assert Repo.aggregate(Request, :count) == 0
    end

    test "release_command is set by PATCH, read back, and refused when it isn't one line", ctx do
      body =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"release_command" => "make release"})
        |> json_response(200)

      assert body["board"]["release_command"] == "make release"

      assert ctx.agent
             |> get(~p"/api/boards/#{ctx.board.id}")
             |> json_response(200)
             |> get_in(["board", "release_command"]) == "make release"

      body =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"release_command" => "a\nb"})
        |> json_response(422)

      assert inspect(body) =~ "must be one line"
    end
  end

  describe "MCP" do
    test "release_now asks, and check only reads", ctx do
      card = merged!(ctx.todo, "Feature")

      {false, text} = mcp(ctx.agent, "release_now", %{board: "#{ctx.board.id}", check: true})

      assert %{"release" => %{"running" => nil, "awaiting" => [%{"id" => id}]}} =
               Jason.decode!(text)

      assert id == card.id
      assert Repo.aggregate(Request, :count) == 0

      {false, text} = mcp(ctx.agent, "release_now", %{board: ctx.board.code})
      body = Jason.decode!(text)
      assert body["how"] == "started"
      assert body["request"]["card_ids"] == [card.id]
      assert body["release"]["running"]["id"] == body["request"]["id"]
      assert [%Request{status: "running"}] = Repo.all(Request)
    end

    test "release_now is refused on an on_merge board and for someone who isn't the owner", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      theirs = with_token(editor, "theirs")
      {true, _refusal} = mcp(theirs, "release_now", %{board: "#{ctx.board.id}"})
      assert Repo.aggregate(Request, :count) == 0

      # Reading where releases stand is any reader's.
      {false, text} = mcp(theirs, "release_now", %{board: "#{ctx.board.id}", check: true})
      assert Jason.decode!(text)["release"]["mode"] == "batched"
      assert Repo.aggregate(Request, :count) == 0

      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      {true, text} = mcp(ctx.agent, "release_now", %{board: "#{ctx.board.id}"})
      assert text =~ "releases on merge"
    end

    test "update_board sets the release command", ctx do
      {false, _} =
        mcp(ctx.agent, "update_board", %{
          board: "#{ctx.board.id}",
          release_command: "make release"
        })

      assert Boards.get_board!(ctx.board.id).release_command == "make release"

      {false, _} =
        mcp(ctx.agent, "update_board", %{board: "#{ctx.board.id}", release_command: nil})

      assert Boards.get_board!(ctx.board.id).release_command == nil
    end
  end

  describe "the board page" do
    test "a batched board with merged work shows the banner, and Release now starts one", ctx do
      merged!(ctx.todo, "Feature")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(view, "#release-banner-line", "1 merged, awaiting release")

      view |> element("#release-now") |> render_click()

      assert [%Request{status: "running", triggers: [%{"by" => "Dana"}]}] = Repo.all(Request)
      assert has_element?(view, "#release-banner-line", "A release is running (1 cards)")
    end

    test "no banner with nothing to say, or on a board that releases on merge", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#release-banner")

      merged!(ctx.todo, "Feature")
      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#release-banner")
    end

    test "a board switched back to on merge shows none, even with a release still open", ctx do
      {:ok, :started, _} = Releases.release_now(ctx.board, "Dana")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert has_element?(view, "#release-banner")

      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#release-banner")
    end

    test "a release asked for elsewhere shows without a reload", ctx do
      merged!(ctx.todo, "Feature")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      {:ok, :started, _} = Releases.release_now(ctx.board, "Eli")
      assert has_element?(view, "#release-banner-line", "A release is running")
    end

    test "someone it is shared with sees the banner but no button", ctx do
      merged!(ctx.todo, "Feature")
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      {:ok, view, _} = live(log_in_user(build_conn(), editor), ~p"/boards/#{ctx.board}")
      assert has_element?(view, "#release-banner")
      refute has_element?(view, "#release-now")
    end
  end

  describe "the Agentic Building page" do
    test "saves the release command and releases now", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      assert has_element?(view, "#board-release-line", "Nothing merged is awaiting release.")

      view
      |> form("#agentic-form", board: %{"release_command" => "make release"})
      |> render_submit()

      assert Boards.get_board!(ctx.board.id).release_command == "make release"

      view |> element("#board-release-now") |> render_click()

      assert [%Request{status: "running"} = request] = Repo.all(Request)
      assert Repo.get!(Job, request.job_id).prompt == "make release"
      assert has_element?(view, "#board-release-line", "A release is running")
    end

    test "someone it is shared with reads where releases stand, with no button", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      {:ok, view, _} = live(log_in_user(build_conn(), editor), ~p"/boards/#{ctx.board}/agentic")
      assert has_element?(view, "#board-release-line")
      refute has_element?(view, "#board-release-now")
    end

    test "no release block on a board that releases on merge", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      refute has_element?(view, "#board-release-status")
    end
  end

  describe "the help" do
    test "the app's guide, the agents' doors table and the flow page name Release now", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/help/boards")
      assert html =~ "Release now"
      assert html =~ "one follow-up"

      {:ok, _view, html} = live(conn, ~p"/help/agents")
      assert html =~ "Release a batched board&#39;s merged work now"
      assert html =~ "slipdock release, slipdock releases"
      assert html =~ "release_now (check: true to read)"

      {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
      assert html =~ "A batched board releases on a trigger, not on a merge."
    end
  end

  describe "a card released with no deploy recorded" do
    test "reads released, with no environment, in its JSON", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"delivery_metrics" => false})
      card = merged!(ctx.todo, "Feature")
      {:ok, :started, request} = Releases.release_now(board, "Dana")
      {:ok, _} = Releases.finish(request, "released", "the release command ran")

      body = ctx.agent |> get(~p"/api/cards/#{card.id}") |> json_response(200)

      assert %{"state" => "released", "environment" => nil, "text" => "Released · " <> _} =
               body["card"]["release"]
    end
  end

  describe "the runner protocol" do
    test "a runner that takes release claims the job: its kind, the command, no card", ctx do
      {:ok, :started, request} = Releases.release_now(ctx.board, "Dana")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.runner_token)
        |> put_req_header("x-runner-kinds", "merge,release")
        |> put_req_header("content-type", "text/plain")
        |> post("/api/runner/claim?wait=0")

      assert conn.status == 200
      assert conn.resp_body == "gh workflow run release.yml --ref {default_branch}"
      assert get_resp_header(conn, "x-job-kind") == ["release"]
      assert get_resp_header(conn, "x-job-id") == ["#{request.job_id}"]
      assert get_resp_header(conn, "x-card-id") == []

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.runner_token)
        |> put_req_header("content-type", "text/plain")
        |> post(
          "/api/runner/jobs/#{request.job_id}/finish?exit=0",
          "https://github.com/example/app/actions/runs/7"
        )

      assert conn.status in [200, 204]

      assert Repo.get!(Request, request.id).run_url ==
               "https://github.com/example/app/actions/runs/7"
    end

    test "a runner that doesn't say it takes release is handed nothing", ctx do
      {:ok, :started, _} = Releases.release_now(ctx.board, "Dana")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.runner_token)
        |> put_req_header("x-runner-kinds", "claude,merge")
        |> put_req_header("content-type", "text/plain")
        |> post("/api/runner/claim?wait=0")

      assert conn.status == 204
    end
  end

  test "the release command goes out with a portable export and comes back in", ctx do
    {:ok, board} = Boards.update_board(ctx.board, %{"release_command" => "make release"})

    document = Slipdock.Portable.export(ctx.user, boards: [board])
    [tree] = document.boards
    assert tree.root.release_command == "make release"

    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(document))
    assert Boards.get_board!(hd(report.boards).id).release_command == "make release"

    odd = update_in(document.boards, fn [t] -> [put_in(t.root.release_command, "a\nb")] end)
    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(odd))
    assert Boards.get_board!(hd(report.boards).id).release_command == nil

    long = String.duplicate("x", 501)
    odd = update_in(document.boards, fn [t] -> [put_in(t.root.release_command, long)] end)
    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(odd))
    assert Boards.get_board!(hd(report.boards).id).release_command == nil

    fits = String.duplicate("x", 500)
    odd = update_in(document.boards, fn [t] -> [put_in(t.root.release_command, fits)] end)
    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(odd))
    assert Boards.get_board!(hd(report.boards).id).release_command == fits
  end
end
