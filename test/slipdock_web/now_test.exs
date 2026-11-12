defmodule SlipdockWeb.NowTest do
  @moduledoc """
  The doors to what is happening right now (#2103): the Right now page
  (`/boards/:id/now`), one click from the board page (the delivery line's
  link, or a line of its own with Agentic Building on), the Agentic Building
  page's tile, `GET /api/boards/:board/now` and MCP `get_board now: true`,
  and a reader of a sub-board alone refused the tree's.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo, Runners}
  alias Slipdock.Boards.CardMove

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

  # Eight closed stays of `secs` in the doing list, the fewest a usual stay
  # is worked out from; and a card's entry into its list moved back.
  defp usual_stay(ctx, secs) do
    done = Enum.find(ctx.board.columns, &(&1.category == "done"))

    for _ <- 1..8 do
      card = card_fixture(done, %{"title" => "Closed"})
      Repo.delete_all(from(m in CardMove, where: m.card_id == ^card.id))
      start = DateTime.add(DateTime.utc_now(), -(secs + 86_400))

      for {kind, from, to, at} <- [
            {"created", nil, ctx.doing, start},
            {"moved", ctx.doing, done, DateTime.add(start, secs)}
          ] do
        Repo.insert!(%CardMove{
          card_id: card.id,
          kind: kind,
          board_id: card.board_id,
          from_column_id: from && from.id,
          to_column_id: to.id,
          inserted_at: at
        })
      end
    end
  end

  defp entered(card, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago)
    Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [inserted_at: at])
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

    test "Stuck, in red, is the health monitor's flag; past the usual stay is amber (#2131)",
         ctx do
      usual_stay(ctx, 3600)
      flagged = card_fixture(ctx.doing, %{"title" => "Flagged", "flags" => ["stuck"]})
      slow = card_fixture(ctx.doing, %{"title" => "Slow"})
      entered(slow, 2 * 3600)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/now")

      assert has_element?(view, "#now-card-#{flagged.id} .badge-error", "Stuck")
      assert has_element?(view, "#now-card-#{slow.id} .badge-warning", "Past usual stay")
      refute has_element?(view, "#now-card-#{slow.id} .badge-error")
      refute has_element?(view, "#now-card-#{ctx.card.id} .badge-warning")
    end

    test "a card a runner builds outside a doing list shows, its list named (#2633)", ctx do
      slipped = card_fixture(ctx.todo, %{"title" => "Slipped through"})

      working_job_fixture(slipped, %{
        runner_id: ctx.runner.id,
        runner_name: "Mac Studio",
        pool: "dev"
      })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/now")

      row = "#now-card-#{slipped.id}"
      assert has_element?(view, row, "Slipped through")
      assert has_element?(view, row, "Busy › #{ctx.todo.name}")
      assert has_element?(view, "#{row}-outside.badge-warning", "Not in a doing list")
      refute has_element?(view, "#now-card-#{ctx.card.id}-outside")
      assert has_element?(view, "#now-cards h2", "2")

      body = ctx.user |> with_token() |> get("/api/boards/#{ctx.board.id}/now")
      cards = json_response(body, 200)["in_progress"]

      assert %{"list" => list, "in_doing" => false} = Enum.find(cards, &(&1["id"] == slipped.id))
      assert list == ctx.todo.name
      assert %{"in_doing" => true} = Enum.find(cards, &(&1["id"] == ctx.card.id))
    end

    test "a quiet board says so in each section", %{user: user} do
      board = board_fixture(%{}, owner: user)
      {:ok, view, _} = live(build_conn() |> log_in_user(user), ~p"/boards/#{board}/now")

      assert has_element?(view, "#now-no-runners")
      assert has_element?(view, "#now-no-cards")
      assert has_element?(view, "#now-no-queued")
      # No runners at all: no idle section either, and no "none working" line.
      refute has_element?(view, "#now-idle")
      refute has_element?(view, "#now-none-working")
    end

    test "idle runners are listed at the bottom of the page, not among the working ones",
         ctx do
      {:ok, idle, _} =
        Runners.create_runner(ctx.board, %{"name" => "Old laptop", "pool" => "dev"})

      {:ok, view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/now")

      # The working runner stays in Runners, with its job.
      assert has_element?(view, "#now-runners #now-runner-#{ctx.runner.id}", "Writing the tests")
      refute has_element?(view, "#now-idle #now-runner-#{ctx.runner.id}")

      # The idle one is only at the bottom, offline as it has never been seen.
      assert has_element?(view, "#now-idle #now-runner-#{idle.id}", "Old laptop")
      assert has_element?(view, "#now-idle #now-runner-#{idle.id}", "offline")
      assert has_element?(view, "#now-idle h2", "Idle runners")
      refute has_element?(view, "#now-runners #now-runner-#{idle.id}")
      refute has_element?(view, "#now-runners", "Idle")
      refute has_element?(view, "#now-none-working")

      # The bottom: after the queue, the last section on the page.
      sections = Regex.scan(~r/<section[^>]* id="(now-[a-z-]+)"/, html, capture: :all_but_first)
      assert List.flatten(sections) == ~w(now-runners now-cards now-queued now-idle)
    end

    test "with every runner idle, Runners says none is working and the idle list holds them",
         %{user: user} do
      board = board_fixture(%{}, owner: user)
      {:ok, a, _} = Runners.create_runner(board, %{"name" => "Box A", "pool" => "dev"})
      a = Repo.update!(Ecto.Changeset.change(a, last_seen_at: DateTime.utc_now(:second)))
      {:ok, view, _} = live(build_conn() |> log_in_user(user), ~p"/boards/#{board}/now")

      assert has_element?(view, "#now-none-working")
      refute has_element?(view, "#now-no-runners")
      refute has_element?(view, "#now-runners #now-runner-#{a.id}")
      assert has_element?(view, "#now-idle #now-runner-#{a.id}", "online")
    end

    test "a runner that takes a job moves up from the idle list when the page is read again",
         ctx do
      {:ok, idle, _} = Runners.create_runner(ctx.board, %{"name" => "Spare", "pool" => "dev"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/now")
      assert has_element?(view, "#now-idle #now-runner-#{idle.id}")

      card = card_fixture(ctx.doing, %{"title" => "Picked up by Spare"})
      working_job_fixture(card, %{runner_id: idle.id, runner_name: "Spare", pool: "dev"})
      send(view.pid, :tick)

      assert has_element?(view, "#now-runners #now-runner-#{idle.id}", "Picked up by Spare")
      refute has_element?(view, "#now-idle")
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
    test "the delivery line no longer carries a Right now link (#2124)", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"delivery_metrics" => true})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(view, "#board-dora")
      refute has_element?(view, "#board-now-link")
      refute render(view) =~ "Right now ›"
      refute has_element?(view, "#board-now")
    end

    test "with Agentic Building on, the pulse line opens it, standing in for its own line (#2124)",
         ctx do
      {:ok, _} =
        Boards.update_board(ctx.board, %{
          "agentic_building" => true,
          "show_pulse" => true,
          "delivery_metrics" => true
        })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(view, ~s(a#board-pulse[href="/boards/#{ctx.board.id}/now"]))
      refute has_element?(view, "#board-now")
      refute has_element?(view, "#board-now-link")

      {:ok, now, _} =
        view |> element("#board-pulse") |> render_click() |> follow_redirect(ctx.conn)

      assert now.module == SlipdockWeb.NowLive.Index
    end

    test "with Agentic Building on and the pulse off, its own line shows beside the delivery line",
         ctx do
      {:ok, _} =
        Boards.update_board(ctx.board, %{"agentic_building" => true, "delivery_metrics" => true})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(view, "#board-dora")
      assert has_element?(view, ~s(#board-now[href="/boards/#{ctx.board.id}/now"]))
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

    test "the Agentic Building page has it as a tile, counting what is on", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"agentic_building" => true})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      tile = ~s(#agentic-tile-now[href="/boards/#{ctx.board.id}/now"])

      assert has_element?(view, tile)
      assert has_element?(view, "#{tile} [data-role=tile-number]", "1")
      assert has_element?(view, "#{tile} [data-role=tile-line]", "1 card in progress, 1 queued")
      refute has_element?(view, "#agentic-now")
    end

    test "the tile on a quiet board says nothing is in progress", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"agentic_building" => true})
      Repo.update_all(Slipdock.Runners.Job, set: [status: "done"])
      Repo.update_all(Slipdock.Boards.Card, set: [completed: true])
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")

      assert has_element?(view, "#agentic-tile-now [data-role=tile-number]", "0")
      assert has_element?(view, "#agentic-tile-now [data-role=tile-line]", "Nothing in progress")
      refute has_element?(view, "#agentic-tile-now[data-attention]")
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

    test "both doors give the same NowJSON view, nothing past its fields", ctx do
      body = ctx.user |> with_token() |> get("/api/boards/#{ctx.board.id}/now")
      body = json_response(body, 200)
      result = ctx.user |> with_token() |> mcp("get_board", %{board: ctx.board.id, now: true})
      mcp_body = Jason.decode!(text(result))

      assert Map.drop(mcp_body, ~w(id code name)) == body
      assert Map.keys(body) |> Enum.sort() == ~w(board_id counts in_progress queued runners)
      assert [runner] = body["runners"]
      assert Map.keys(runner) |> Enum.sort() == ~w(id jobs name online pool session)
      assert [card] = body["in_progress"]

      assert Map.keys(card) |> Enum.sort() ==
               ~w(age board board_id holds id in_doing list loop parent state state_kind title)

      assert card["loop"] == nil or Map.keys(card["loop"]) -- ~w(job_id kind runner) == []
      assert [%{"held" => _} = queued] = body["queued"]

      assert Map.keys(queued) |> Enum.sort() ==
               ~w(board_id card card_id held id kind pool since status step step_at)
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
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
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
