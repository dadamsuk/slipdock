defmodule SlipdockWeb.VisualiseLiveTest do
  @moduledoc """
  The board's Visualise page (#1185): who may open it, where it is reached
  from, the `?days=` window, and its Pulse tiles (#1189).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.Wait
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

  test "durations read as the rest of the app writes them" do
    assert VisualiseComponents.duration(nil) == "–"
    assert VisualiseComponents.duration(47) == "47s"
    assert VisualiseComponents.duration(647) == "10m 47s"
    assert VisualiseComponents.duration(4980) == "1h 23m"
    assert VisualiseComponents.duration(12.8 * 86_400) == "12.8 days"
  end
end
