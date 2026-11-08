defmodule SlipdockWeb.NowTest do
  @moduledoc """
  The doors to what is happening right now (#2103): the Right now page
  (`/boards/:id/now`), one click from the board page (the delivery line's
  link, or a line of its own with Agentic Building on), the Agentic Building
  page's link, `GET /api/boards/:board/now` and MCP `get_board now: true`,
  and a reader of a sub-board alone refused the tree's.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo, Runners}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Busy", "code" => unique_code()}, owner: user)
    todo = Enum.find(board.columns, &(&1.category == "todo"))
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "Mac Studio", "pool" => "dev"})
    runner = Repo.update!(Ecto.Changeset.change(runner, last_seen_at: DateTime.utc_now(:second)))
    card = card_fixture(doing, %{"title" => "Being built"})

    working_job_fixture(card, %{
      runner_id: runner.id,
      runner_name: "Mac Studio",
      pool: "dev",
      step: "Writing the tests"
    })

    next = card_fixture(todo, %{"title" => "Up next"})
    queued = working_job_fixture(next, %{status: "queued", pool: "dev"})

    %{board: board, todo: todo, doing: doing, runner: runner, card: card, queued: queued}
  end

  defp with_token(user) do
    {token, _} = Accounts.create_api_token(user, "laptop", [])

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
    |> Map.fetch!("result")
  end

  defp text(%{"content" => [%{"text" => text}]}), do: text

  describe "the page" do
    test "shows each runner and its job's step, the cards in progress and the queue", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/now")

      runner = "#now-runner-#{ctx.runner.id}"
      assert has_element?(view, runner, "Mac Studio")
      assert has_element?(view, runner, "online")
      assert has_element?(view, runner, "Writing the tests")

      assert has_element?(
               view,
               ~s(#{runner} a[href="/boards/#{ctx.board.id}/cards/#{ctx.card.id}"])
             )

      row = "#now-card-#{ctx.card.id}"
      assert has_element?(view, row, "Being built")
      assert has_element?(view, row, "Busy › #{ctx.doing.name}")
      assert has_element?(view, row, "Mac Studio · build")

      assert has_element?(view, "#now-queued-#{ctx.queued.id}", "Up next")
      refute has_element?(view, "#now-no-runners")
    end

    test "a quiet board says so in each section", %{user: user} do
      board = board_fixture(%{}, owner: user)
      {:ok, view, _} = live(build_conn() |> log_in_user(user), ~p"/boards/#{board}/now")

      assert has_element?(view, "#now-no-runners")
      assert has_element?(view, "#now-no-cards")
      assert has_element?(view, "#now-no-queued")
    end

    test "is read again while it is open", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/now")
      later = card_fixture(ctx.doing, %{"title" => "Started since"})
      send(view.pid, :tick)
      assert has_element?(view, "#now-card-#{later.id}", "Started since")
    end

    test "a stranger is sent away", ctx do
      stranger = user_fixture("now-stranger-#{System.unique_integer([:positive])}@example.com")

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(build_conn() |> log_in_user(stranger), ~p"/boards/#{ctx.board}/now")
    end
  end

  describe "one click from the board page" do
    test "the delivery line (the rocket) links to it", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"delivery_metrics" => true})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(
               view,
               ~s(#board-dora #board-now-link[href="/boards/#{ctx.board.id}/now"])
             )

      refute has_element?(view, "#board-now")
    end

    test "with Agentic Building on and no delivery line, a line of its own says what is on",
         ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"agentic_building" => true})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(view, ~s(#board-now[href="/boards/#{ctx.board.id}/now"]))
      assert has_element?(view, "#board-now", "1 runner working · 1 card in progress · 1 queued")
    end

    test "with neither, the board page has no Right now line", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#board-now")
      refute has_element?(view, "#board-now-link")
    end

    test "the Agentic Building page links to it", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"agentic_building" => true})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      assert has_element?(view, ~s(#agentic-now[href="/boards/#{ctx.board.id}/now"]))
    end
  end

  describe "REST and MCP" do
    test "GET /api/boards/:board/now gives the snapshot", ctx do
      body = ctx.user |> with_token() |> get("/api/boards/#{ctx.board.code}/now")
      body = json_response(body, 200)

      assert body["board_id"] == ctx.board.id
      assert [%{"name" => "Mac Studio", "online" => true, "jobs" => [job]}] = body["runners"]
      assert job["step"] == "Writing the tests" and job["card_id"] == ctx.card.id
      assert [%{"title" => "Being built", "list" => _, "board" => "Busy"}] = body["in_progress"]
      assert [%{"id" => id, "card" => "Up next"}] = body["queued"]
      assert id == ctx.queued.id

      assert body["counts"] == %{
               "runners" => 1,
               "online" => 1,
               "working" => 1,
               "in_progress" => 1,
               "queued" => 1
             }
    end

    test "GET refuses a stranger", ctx do
      stranger =
        user_fixture("now-api-stranger-#{System.unique_integer([:positive])}@example.com")

      assert stranger
             |> with_token()
             |> get("/api/boards/#{ctx.board.id}/now")
             |> json_response(404)
    end

    test "get_board now: true gives the same", ctx do
      result = ctx.user |> with_token() |> mcp("get_board", %{board: ctx.board.code, now: true})

      refute result["isError"]
      body = Jason.decode!(text(result))
      assert body["code"] == ctx.board.code
      assert [%{"title" => "Being built"}] = body["in_progress"]
      assert body["counts"]["working"] == 1
    end
  end

  describe "a reader of just a sub-board" do
    setup ctx do
      epic = card_fixture(ctx.todo, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      reader = user_fixture("now-sub-reader-#{System.unique_integer([:positive])}@example.com")
      {:ok, _} = Slipdock.Access.grant(sub, reader, "read", ctx.user)
      %{sub: sub, reader: reader}
    end

    test "is refused the tree's, through every door", ctx do
      conn = with_token(ctx.reader)
      assert conn |> get("/api/boards/#{ctx.sub.id}") |> json_response(200)

      body = conn |> get("/api/boards/#{ctx.sub.id}/now") |> json_response(403)
      assert body["error"] =~ "root board"
      refute inspect(body) =~ "Being built"

      result = mcp(conn, "get_board", %{board: ctx.sub.code, now: true})
      assert result["isError"]
      assert text(result) =~ "root board"

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(build_conn() |> log_in_user(ctx.reader), ~p"/boards/#{ctx.sub}/now")
    end
  end
end
