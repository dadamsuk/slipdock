defmodule SlipdockWeb.VisualiseChartsTest do
  @moduledoc """
  The Visualise page's trend charts (#1191): the geometry against small
  fixed series, each chart's empty state and takeaway, and the window
  switch driving them.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias SlipdockWeb.BoardLive.VisualiseCharts, as: C

  describe "ticks/1" do
    test "round steps of 1, 2 or 5 reaching past the top" do
      assert C.ticks(0) == {1, [0, 1]}
      assert C.ticks(1) == {1, [0, 1]}
      assert C.ticks(3) == {3, [0, 1, 2, 3]}
      assert C.ticks(7) == {8, [0, 2, 4, 6, 8]}
      assert C.ticks(43) == {60, [0, 20, 40, 60]}
      assert C.ticks(120) == {150, [0, 50, 100, 150]}
      assert C.ticks(2.4) == {3, [0, 1, 2, 3]}
    end
  end

  describe "geometry" do
    test "days sit mid-slot, values from the bottom" do
      assert C.x(0, 1) == 300.0
      assert C.x(0, 2) == 150.0
      assert C.x(1, 2) == 450.0
      assert C.y(0, 10) == 180.0
      assert C.y(10, 10) == 0.0
      assert C.y(5, 10) == 90.0
    end

    test "a line through all zeros lies on the floor; a single day is one point" do
      assert C.line_path([0, 0], 1) == "150.0,180.0 450.0,180.0"
      assert C.line_path([4], 4) == "300.0,0.0"
    end

    test "stacked areas run between the running totals" do
      [{"a", a}, {"b", b}] = C.area_paths([{"a", [1, 2]}, {"b", [1, 0]}], 4)
      assert a == "M150.0,135.0 L450.0,90.0 L450.0,180.0 L150.0,180.0 Z"
      assert b == "M150.0,90.0 L450.0,90.0 L450.0,90.0 L150.0,135.0 Z"
    end

    test "the rolling mean trails over what there is" do
      assert C.rolling([2, 4, 6, 8], 2) == [2.0, 3.0, 5.0, 7.0]
      assert C.rolling([], 7) == []
    end

    test "the log scale puts a minute at the floor and a day at the top, holding the rest" do
      assert C.log_y(60) == 180.0
      assert C.log_y(86_400) == 0.0
      assert C.log_y(1) == 180.0
      assert C.log_y(9 * 86_400) == 0.0
      assert C.log_y(3600) < C.log_y(600)
    end

    test "five date labels across the window, or every day when fewer" do
      dates = Enum.map(0..29, &Date.add(~D[2026-09-20], &1))
      labels = C.date_labels(dates)
      assert length(labels) == 5
      assert hd(labels) == {"20 Sep", 1.67}
      assert List.last(labels) == {"19 Oct", 98.33}
      assert [{"1 Oct", 50.0}] = C.date_labels([~D[2026-10-01]])
    end

    test "a dot's nudge is steady and stays within its day" do
      assert C.jitter(42, 30) == C.jitter(42, 30)
      assert abs(C.jitter(42, 30)) <= 0.3 * 600 / 30
    end
  end

  describe "on the page" do
    setup %{user: user} do
      board = board_fixture(%{"name" => "Charts"}, owner: user)
      %{board: board}
    end

    test "an empty window shows a line instead of each chart", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")

      for id <- ~w(chart-cfd chart-velocity chart-burndown chart-cycle) do
        assert has_element?(view, "##{id}-empty")
        refute has_element?(view, "##{id} svg")
      end
    end

    test "with history each chart draws, saying its takeaway", %{conn: conn, board: board} do
      [_backlog, todo, doing, done] = board.columns
      card_fixture(todo)
      card_fixture(doing)
      finished = card_fixture(doing, %{"title" => "Shipped"})
      :ok = Slipdock.Boards.move_card(finished.id, done.id, nil)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")

      assert has_element?(
               view,
               ~s|#chart-cfd svg[role="img"][aria-label^="Cumulative flow: today"]|
             )

      assert has_element?(view, ~s|#chart-cfd path[data-band="doing"]|)

      assert has_element?(
               view,
               ~s|#chart-velocity svg[aria-label="Velocity: 1 cards completed, 0.0 a day on average"]|
             )

      assert has_element?(view, "#chart-velocity", "a day on average")
      assert has_element?(view, ~s|#chart-velocity polyline[data-line="rolling"]|)

      assert has_element?(
               view,
               ~s|#chart-burndown svg[aria-label^="Backlog burndown: 2 open now"]|
             )

      assert has_element?(view, "#chart-burndown", "open now")
      assert has_element?(view, ~s|#chart-burndown polyline[data-line="even"][stroke-dasharray]|)
      assert has_element?(view, ~s|#chart-cycle circle[data-card="#{finished.id}"]|)
      assert has_element?(view, ~s|#chart-cycle line[data-line="p85"][stroke-dasharray]|)
      assert has_element?(view, ~s|#chart-cycle line[data-line="p50"]|)
      assert has_element?(view, "#chart-cycle", "1m")
    end

    test "the switch changes the window of every chart; 90 days goes weekly",
         %{conn: conn, board: board} do
      [_backlog, _todo, doing, done] = board.columns
      c = card_fixture(doing)
      :ok = Slipdock.Boards.move_card(c.id, done.id, nil)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")
      assert has_element?(view, "#trends", "Last 30 days")
      assert has_element?(view, "#chart-velocity", "a day on average")

      view |> element("#window-7") |> render_click()
      assert has_element?(view, "#trends", "Last 7 days")

      view |> element("#window-90") |> render_click()
      assert has_element?(view, "#trends", "Last 90 days")
      assert has_element?(view, "#chart-velocity", "a week on average")
      assert has_element?(view, "#chart-velocity", "Cards completed each week")
    end
  end
end
