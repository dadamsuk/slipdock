defmodule SlipdockWeb.VisualiseLiveTest do
  @moduledoc """
  The board's Visualise page (#1185): who may open it, where it is reached
  from, the `?days=` window, and its Pulse tiles (#1189).
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.{CardMove, Wait}
  alias SlipdockWeb.BoardLive.VisualiseComponents

  setup %{user: user} do
    board = board_fixture(%{"name" => "Seen"}, owner: user)
    [_backlog, todo, doing, done] = board.columns
    %{board: board, todo: todo, doing: doing, done: done}
  end

  describe "access" do
    test "the owner sees the page, h1 and board name", %{conn: conn, board: board} do
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/visualise")
      assert html =~ "Visualise · Seen"
      assert has_element?(view, "h1", "Visualise")
      assert has_element?(view, "#visualise p", "Seen")
      assert has_element?(view, "#pulse")
    end

    test "someone the board is shared with can read it", %{board: board} do
      reader = user_fixture("reader#{System.unique_integer([:positive])}@example.com")
      share_fixture(board, [reader], "read")
      {:ok, view, _} = live(log_in_user(build_conn(), reader), ~p"/boards/#{board}/visualise")
      assert has_element?(view, "#pulse")
    end

    test "a stranger is sent home, as the board page does", %{board: board} do
      stranger = user_fixture("stranger#{System.unique_integer([:positive])}@example.com")

      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(log_in_user(build_conn(), stranger), ~p"/boards/#{board}/visualise")

      assert message =~ "don't have access"
    end

    test "a board that isn't there is refused", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/boards/0/visualise")
    end
  end

  describe "entry point" do
    test "the board's view menu offers it beside Timeline and Prioritise",
         %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(
               view,
               ~s|#view-menu a[href="/boards/#{board.id}/visualise"]|,
               "Visualise"
             )

      assert has_element?(view, ~s|#view-menu a[href="/boards/#{board.id}/timeline"]|)

      # And the page names itself in the same menu.
      {:ok, page, _} = live(conn, ~p"/boards/#{board}/visualise")
      assert has_element?(page, ~s|#view-menu [aria-label="View: Visualise"]|)
    end

    test "a simple board leaves it out, as it does Timeline and Prioritise",
         %{conn: conn, board: board} do
      {:ok, _} = Boards.update_board(board, %{"simple" => true})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      refute has_element?(view, ~s|#view-menu a[href="/boards/#{board.id}/visualise"]|)
      refute has_element?(view, ~s|#view-menu a[href="/boards/#{board.id}/prioritise"]|)
    end
  end

  describe "the window" do
    test "30 days unless asked, and the switch puts the choice in the URL",
         %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")
      assert has_element?(view, ~s|#window-30[aria-pressed="true"]|)
      assert has_element?(view, ~s|#window-7[aria-pressed="false"]|)

      view |> element("#window-90") |> render_click()
      assert_patch(view, ~p"/boards/#{board}/visualise?days=90")
      assert has_element?(view, ~s|#window-90[aria-pressed="true"]|)
      assert has_element?(view, ~s|#window-30[aria-pressed="false"]|)
    end

    test "a link with days reproduces the view, held to 7, 30 or 90",
         %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise?days=7")
      assert has_element?(view, ~s|#window-7[aria-pressed="true"]|)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise?days=45")
      assert has_element?(view, ~s|#window-90[aria-pressed="true"]|)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise?days=soon")
      assert has_element?(view, ~s|#window-30[aria-pressed="true"]|)
    end
  end

  describe "pulse tiles" do
    test "each tile's figures from the board", %{conn: conn, user: user} = ctx do
      card_fixture(ctx.doing, %{"title" => "Underway"})
      asked = card_fixture(ctx.doing, %{"title" => "Asked", "flags" => ["waiting"]})
      moved = card_fixture(ctx.todo, %{"title" => "Forward"})
      # Into the done list completes it.
      :ok = Boards.move_card(moved.id, ctx.done.id, nil, actor: Slipdock.Actor.web(user))
      assert Repo.get!(Slipdock.Boards.Card, moved.id).completed

      now = DateTime.utc_now(:second)

      Repo.insert!(%Wait{
        card_id: asked.id,
        needs: "Which?",
        inserted_at: DateTime.add(now, -(3600 + 23 * 60)),
        closed_at: now,
        close_reason: "answered"
      })

      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")

      assert has_element?(view, "#pulse", "Last 7 days")
      assert has_element?(view, "#tile-throughput [data-value]", "1")
      assert has_element?(view, "#tile-throughput", "1 today")
      assert has_element?(view, "#tile-wip [data-value]", "2")
      assert has_element?(view, "#tile-wip", "no WIP limit set")
      refute has_element?(view, "#wip-at-limit")
      assert has_element?(view, "#tile-waiting [data-value]", "1")
      assert has_element?(view, "#tile-waiting", "last answered in 1h 23m")
      assert has_element?(view, "#tile-moves [data-value]", "1")
      assert has_element?(view, "#tile-moves", "1 forward · 0 back")
      assert has_element?(view, "#tile-cycle", "1 card (90 days)")
    end

    test "WIP is shown against the doing list's limit, with a chip at it", %{conn: conn} = ctx do
      {:ok, _} = Boards.update_column(ctx.doing, %{"wip_limit" => 2})
      card_fixture(ctx.doing)

      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, "#tile-wip [data-value]", "1 / 2")
      refute has_element?(view, "#wip-at-limit")

      card_fixture(ctx.doing)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, "#tile-wip [data-value]", "2 / 2")
      assert has_element?(view, "#wip-at-limit", "At limit")
    end

    test "idea to production shows only while delivery metrics are on", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      refute has_element?(view, "#tile-idea")

      {:ok, _} = Boards.update_board(ctx.board, %{"delivery_metrics" => true})
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, "#tile-idea", "Idea to production P50")
      assert has_element?(view, "#tile-idea", "(30 days)")
    end

    test "a change on the board refreshes the tiles, once it has settled", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, "#tile-wip [data-value]", "0")

      card_fixture(ctx.doing)
      card_fixture(ctx.doing)
      # Not on every change: the board's broadcasts only schedule one refresh.
      assert has_element?(view, "#tile-wip [data-value]", "0")

      send(view.pid, :refresh)
      assert has_element?(view, "#tile-wip [data-value]", "2")
    end
  end

  describe "flow through the board (#1190)" do
    test "one block per list in board order, with counts and 7-day traffic",
         %{conn: conn, user: user} = ctx do
      card_fixture(ctx.todo)
      moved = card_fixture(ctx.todo)
      :ok = Boards.move_card(moved.id, ctx.doing.id, nil, actor: Slipdock.Actor.web(user))
      gone = card_fixture(ctx.done)
      {:ok, _} = Boards.archive_card(Repo.get!(Slipdock.Boards.Card, gone.id))

      {:ok, view, html} = live(conn, ~p"/boards/#{ctx.board}/visualise")

      ids = Regex.scan(~r/id="flow-list-(\d+)"/, html) |> Enum.map(fn [_, id] -> id end)
      assert ids == Enum.map(ctx.board.columns, &to_string(&1.id))

      assert has_element?(view, "#flow-count-#{ctx.todo.id}", "1")
      assert has_element?(view, "#flow-list-#{ctx.todo.id}", "In 2 · Out 1")
      assert has_element?(view, "#flow-count-#{ctx.doing.id}", "1")
      assert has_element?(view, ~s|#flow-list-#{ctx.doing.id}[data-category="doing"]|)
      # The done list's way out is the archive.
      assert has_element?(view, "#flow-list-#{ctx.done.id}", "Archived 1")
      refute has_element?(view, "#flow-list-#{ctx.done.id}", "Out")
      assert has_element?(view, "#flow-list-#{ctx.todo.id}", "Usual stay not known yet")
    end

    test "the doing list shows its count against the WIP limit, warning at it",
         %{conn: conn} = ctx do
      {:ok, _} = Boards.update_column(ctx.doing, %{"wip_limit" => 2})
      card_fixture(ctx.doing)

      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, "#flow-count-#{ctx.doing.id}", "1 / 2")
      refute has_element?(view, "#flow-count-#{ctx.doing.id}.bg-warning\\/15")

      card_fixture(ctx.doing)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, "#flow-count-#{ctx.doing.id}[title='At the WIP limit']", "2 / 2")
    end

    test "uncategorised lists sit at the end, outside the flow", %{conn: conn} = ctx do
      {:ok, later} = Boards.create_column(ctx.board, %{"name" => "Maybe Later", "position" => 0})
      card_fixture(later)

      {:ok, view, html} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      last = Regex.scan(~r/id="flow-list-(\d+)"/, html) |> List.last() |> List.last()
      assert last == to_string(later.id)

      assert has_element?(
               view,
               ~s|#flow-list-#{later.id}[data-category="none"]|,
               "Outside the flow"
             )
    end

    test "the strip wraps on phones, its arrows hidden there", %{conn: conn} = ctx do
      {:ok, _view, html} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert html =~ "flex flex-wrap items-stretch gap-2"
      assert html =~ "hidden items-center text-base-content/40 sm:flex"
    end
  end

  describe "aging work in progress (#1190)" do
    test "nothing open in doing or ready says so", %{conn: conn} = ctx do
      card_fixture(ctx.done)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, "#aging-empty", "Nothing in progress.")
    end

    test "open cards in doing and ready, oldest first, backlog and done left out",
         %{conn: conn} = ctx do
      {:ok, tag} = Boards.create_tag(ctx.board, %{"name" => "infra", "color" => "sky"})
      older = card_fixture(ctx.doing, %{"title" => "Older"})
      newer = card_fixture(ctx.todo, %{"title" => "Newer"})
      Boards.set_card_tags(newer, [tag])
      card_fixture(Enum.at(ctx.board.columns, 0), %{"title" => "Someday"})
      ticked = card_fixture(ctx.doing, %{"title" => "Ticked"})
      {:ok, _} = Boards.toggle_completed(ticked)

      backdate(older, 3 * 3600)
      backdate(newer, 3600)

      {:ok, view, html} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      ids = Regex.scan(~r/id="aging-(\d+)"/, html) |> Enum.map(fn [_, id] -> id end)
      assert ids == [to_string(older.id), to_string(newer.id)]

      assert has_element?(view, "#aging-#{older.id}", "In Progress")
      assert has_element?(view, "#aging-#{older.id}", "#" <> to_string(older.id))
      assert has_element?(view, "#aging-#{newer.id}", "infra")
      assert has_element?(view, "#aging-#{newer.id}", "To Do")
      assert has_element?(view, "#aging-#{older.id}", "no usual stay yet")
    end

    test "past its list's usual stay, the bar warns and says so", %{conn: conn} = ctx do
      # Eight one-hour stays in To Do make its usual stay an hour.
      for _ <- 1..8 do
        c = card_fixture(ctx.todo)
        Repo.delete_all(from m in CardMove, where: m.card_id == ^c.id)
        move_row(c, "created", nil, ctx.todo, -5 * 3600)
        move_row(c, "moved", ctx.todo, ctx.done, -4 * 3600)

        Repo.update_all(from(x in Slipdock.Boards.Card, where: x.id == ^c.id),
          set: [column_id: ctx.done.id]
        )
      end

      slow = card_fixture(ctx.todo, %{"title" => "Slow"})
      quick = card_fixture(ctx.todo, %{"title" => "Quick"})
      backdate(slow, 3 * 3600)
      backdate(quick, 600)

      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, ~s|#aging-#{slow.id}[data-stuck="true"]|, "Past usual stay")
      assert has_element?(view, "#aging-#{slow.id} .bg-warning")
      assert has_element?(view, "#aging-#{slow.id}", "usual 1h 0m")
      assert has_element?(view, ~s|#aging-#{quick.id}[data-stuck="false"]|)
      refute has_element?(view, "#aging-#{quick.id}", "Past usual stay")
    end

    test "agent or human from who drives it", %{conn: conn, user: user} = ctx do
      {:ok, runner, _} =
        Slipdock.Runners.create_runner(ctx.board, %{"name" => "r", "pool" => "dev"})

      busy = card_fixture(ctx.doing, %{"title" => "Busy"})

      Repo.insert!(%Slipdock.Runners.Job{
        pool: "dev",
        kind: "claude",
        prompt: "go",
        status: "running",
        board_id: ctx.board.id,
        root_board_id: ctx.board.id,
        card_id: busy.id,
        runner_id: runner.id,
        claimed_at: DateTime.utc_now(:second)
      })

      by_hand = card_fixture(ctx.todo, %{"title" => "By hand"})
      :ok = Boards.move_card(by_hand.id, ctx.doing.id, nil, actor: Slipdock.Actor.web(user))

      Repo.insert!(%Slipdock.Runners.Job{
        pool: "dev",
        kind: "claude",
        prompt: "go",
        status: "done",
        board_id: ctx.board.id,
        root_board_id: ctx.board.id,
        card_id: by_hand.id
      })

      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, "#aging-#{busy.id}", "Agent")
      assert has_element?(view, "#aging-#{by_hand.id}", "Human")
    end

    test "cards in uncategorised lists are counted in a note, not aged", %{conn: conn} = ctx do
      {:ok, later} = Boards.create_column(ctx.board, %{"name" => "Maybe Later"})
      parked = card_fixture(later)
      card_fixture(later)

      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
      assert has_element?(view, "#aging-outside", "2 in Maybe Later")
      refute has_element?(view, "#aging-#{parked.id}")
    end
  end

  defp backdate(card, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [inserted_at: at])
  end

  defp move_row(card, kind, from, to, offset) do
    Repo.insert!(%CardMove{
      card_id: card.id,
      kind: kind,
      board_id: (to || from).board_id,
      from_column_id: from && from.id,
      from_category: from && from.category,
      to_column_id: to && to.id,
      to_category: to && to.category,
      inserted_at: DateTime.add(DateTime.utc_now(), offset, :second)
    })
  end

  test "durations read as the rest of the app writes them" do
    assert VisualiseComponents.duration(nil) == "–"
    assert VisualiseComponents.duration(47) == "47s"
    assert VisualiseComponents.duration(647) == "10m 47s"
    assert VisualiseComponents.duration(4980) == "1h 23m"
    assert VisualiseComponents.duration(12.8 * 86_400) == "12.8 days"
  end
end
