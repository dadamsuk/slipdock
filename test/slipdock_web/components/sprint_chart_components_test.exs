defmodule SlipdockWeb.Components.SprintChartComponentsTest do
  @moduledoc """
  What the sprint charts draw, not just that they draw: the burndown's ideal
  and actual polylines, the velocity chart's bar heights and average line,
  and the labels under the bars. The charts are built from hand-made maps in
  the shapes `Slipdock.Sprints.burndown/2` and `velocity/2` return, so
  nothing here reads the database.

  The drawing area is 560 × 200 with margins of 32 (left), 12 (right),
  12 (top) and 28 (bottom): x runs from 32 to 548, y from 12 (the top
  value) down to 172 (zero).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SlipdockWeb.SprintChartComponents

  defp day(date, ideal, remaining), do: %{date: date, ideal: ideal, remaining: remaining}

  defp burndown(days, total, done \\ 0) do
    %{sprint: %{id: 7, title: "Sprint 3"}, days: days, total: total, done: done}
  end

  defp render_burndown(chart),
    do: render_component(&SprintChartComponents.burndown_chart/1, chart: chart)

  defp render_velocity(sprints, average),
    do:
      render_component(&SprintChartComponents.velocity_chart/1,
        velocity: %{sprints: sprints, average: average}
      )

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp attrs(html, selector, name) do
    html |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp sprint(title, committed, completed, finished) do
    %{title: title, committed: committed, completed: completed, finished: finished}
  end

  describe "burndown_chart/1" do
    test "draws the ideal line across every day and the actual line through the known ones" do
      html =
        burndown(
          [
            day(~D[2026-11-02], 4, 4),
            day(~D[2026-11-03], 2, 3),
            day(~D[2026-11-04], 0, 1)
          ],
          4,
          3
        )
        |> render_burndown()

      assert [ideal, actual] = attrs(html, "#burndown-7 polyline", "points")
      # x: 32, 32 + 516/2, 548; y: 4 → 12 (top), 2 → 92, 0 → 172 (base).
      assert ideal == "32.0,12.0 290.0,92.0 548.0,172.0"
      # 3 of 4 left → 52, 1 of 4 → 132: lower values are lower on the chart.
      assert actual == "32.0,12.0 290.0,52.0 548.0,132.0"

      assert attrs(html, "#burndown-7 circle", "cy") == ["12.0", "52.0", "132.0"]
      assert html =~ "3 of 4 cards done"
    end

    test "days with no remaining value are skipped in the line and the dots, not drawn at zero" do
      html =
        burndown(
          [
            day(~D[2026-11-02], 2, 2),
            day(~D[2026-11-03], 1, nil),
            day(~D[2026-11-04], 0, nil)
          ],
          2
        )
        |> render_burndown()

      assert [ideal, actual] = attrs(html, "#burndown-7 polyline", "points")
      assert ideal == "32.0,12.0 290.0,92.0 548.0,172.0"
      assert actual == "32.0,12.0"
      assert attrs(html, "#burndown-7 circle", "cx") == ["32.0"]

      # A day in the middle with no value is skipped and the line joins its neighbours.
      html =
        burndown(
          [
            day(~D[2026-11-02], 2, 2),
            day(~D[2026-11-03], 1, nil),
            day(~D[2026-11-04], 0, 1)
          ],
          2
        )
        |> render_burndown()

      assert [_, "32.0,12.0 548.0,92.0"] = attrs(html, "#burndown-7 polyline", "points")
      assert attrs(html, "#burndown-7 circle", "cx") == ["32.0", "548.0"]
    end

    test "draws no actual line when no day has a remaining value yet" do
      html =
        burndown([day(~D[2026-11-02], 3, nil), day(~D[2026-11-03], 0, nil)], 3)
        |> render_burndown()

      assert attrs(html, "#burndown-7 polyline", "points") == ["32.0,12.0 548.0,172.0"]
      assert attrs(html, "#burndown-7 circle", "cx") == []
    end

    test "a one-day sprint puts its only day at the left edge rather than dividing by zero" do
      html = burndown([day(~D[2026-11-02], 2, 1)], 2) |> render_burndown()

      assert attrs(html, "#burndown-7 polyline", "points") == ["32.0,12.0", "32.0,92.0"]
      assert attrs(html, "#burndown-7 circle", "cx") == ["32"]
      assert attrs(html, "#burndown-7 circle", "cy") == ["92.0"]
    end

    test "an empty sprint says so and draws no chart" do
      html = burndown([day(~D[2026-11-02], 0, 0)], 0) |> render_burndown()

      assert html =~ "Nothing in this sprint yet"
      assert attrs(html, "svg", "id") == []
    end
  end

  describe "velocity_chart/1" do
    test "draws each sprint's committed and completed bars to scale, and the average line" do
      html =
        render_velocity(
          [sprint("Sprint 11", 4, 2, true), sprint("Sprint 12", 2, 1, false)],
          1.5
        )

      # Two slots of 258; bars 28 wide, committed left of the slot's middle (161, 419).
      assert attrs(html, "#velocity-chart rect", "x") == ["133.0", "161.0", "391.0", "419.0"]
      assert attrs(html, "#velocity-chart rect", "width") == ["28", "28", "28", "28"]
      # The top is the most committed (4): 4 → 12, 2 → 92, 1 → 132; the base is 172.
      assert attrs(html, "#velocity-chart rect", "y") == ["12.0", "92.0", "92.0", "132.0"]
      assert attrs(html, "#velocity-chart rect", "height") == ["160.0", "80.0", "80.0", "40.0"]

      assert attrs(html, "#velocity-chart rect", "class") == [
               "fill-base-content/20",
               "fill-primary",
               "fill-base-content/20",
               "fill-primary/50"
             ]

      # The average (1.5 of 4) is a dashed line across the whole width at 112.
      dashed = "#velocity-chart line[stroke-dasharray]"
      assert attrs(html, dashed, "y1") == ["112.0"]
      assert attrs(html, dashed, "y2") == ["112.0"]
      assert attrs(html, dashed, "x1") == ["32"]
      assert attrs(html, dashed, "x2") == ["548"]
      assert html =~ "1.5 cards a sprint, on average"
      assert html =~ "average"
    end

    test "with no average there is no dashed line and no average in the caption or legend" do
      html = render_velocity([sprint("Sprint 1", 3, 0, false)], nil)

      assert attrs(html, "#velocity-chart line[stroke-dasharray]", "y1") == []
      refute html =~ "on average"
      refute html =~ "╌"
      # One slot of 516: the bar is capped at 28, and nothing completed is a zero-height bar.
      assert attrs(html, "#velocity-chart rect", "x") == ["262.0", "290.0"]
      assert attrs(html, "#velocity-chart rect", "height") == ["160.0", "0.0"]
    end

    test "an empty list says No sprints yet. and draws no chart" do
      html = render_velocity([], nil)

      assert html =~ "No sprints yet."
      assert attrs(html, "#velocity-chart", "id") == []
      refute html =~ "committed"
    end

    test "labels a numbered sprint S<n> and cuts any other title to eight characters" do
      html =
        render_velocity(
          [
            sprint("Sprint 12", 1, 1, true),
            sprint("  sprint 7: polish", 1, 1, true),
            sprint("Hardening week", 1, 1, true),
            sprint("Sprint twelve", 1, 1, true)
          ],
          nil
        )

      labels =
        html
        |> doc()
        |> LazyHTML.query("#velocity-chart text[text-anchor=middle]")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert labels == ["S12", "S7", "Hardenin", "Sprint t"]
    end
  end
end
