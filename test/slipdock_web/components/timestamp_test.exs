defmodule SlipdockWeb.TimestampTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  import SlipdockWeb.RelativeTimeHelpers

  alias SlipdockWeb.SlipdockComponents

  test "writes the relative time, with the exact time in the title" do
    at = DateTime.add(DateTime.utc_now(), -5 * 60)

    {html, before, later} =
      rendered_around(fn ->
        render_component(&SlipdockComponents.timestamp/1, at: at, id: "t")
      end)

    {:ok, doc} = Floki.parse_fragment(html)
    [el] = Floki.find(doc, "time#t")

    assert Floki.text(el) in expected_labels(at, "5 min ago", before, later)
    assert Floki.attribute(el, "datetime") == [DateTime.to_iso8601(at)]
    assert Floki.attribute(el, "title") == [SlipdockWeb.Dates.exact(at)]
    assert [_] = Floki.attribute(el, "data-role")
  end

  test "takes the viewer's zone and another format" do
    html =
      render_component(&SlipdockComponents.timestamp/1,
        at: ~U[2025-11-18 23:30:00Z],
        zone: "Pacific/Auckland",
        format: :datetime
      )

    assert html =~ "19 Nov 2025, 12:30"
    assert html =~ ~s(title="19 Nov 2025, 12:30 NZDT")
  end

  test "the time alone, for a line in a job's log (#1871)" do
    html =
      render_component(&SlipdockComponents.timestamp/1,
        at: ~U[2025-11-18 23:30:00Z],
        zone: "Pacific/Auckland",
        format: :time
      )

    assert html =~ ">12:30</time>"
    assert html =~ ~s(title="19 Nov 2025, 12:30 NZDT")
  end

  test "a naive datetime is UTC and a bare date is a day" do
    assert render_component(&SlipdockComponents.timestamp/1,
             at: ~N[2025-03-04 10:00:00],
             format: :long
           ) =~ ~s(datetime="2025-03-04T10:00:00Z")

    html = render_component(&SlipdockComponents.timestamp/1, at: ~D[2025-03-04], format: :long)
    assert html =~ "4 Mar 2025"
    assert html =~ ~s(title="Tuesday 4 March 2025")
  end

  test "nil renders nothing" do
    assigns = %{}

    assert rendered_to_string(~H"""
           <SlipdockComponents.timestamp at={nil} />
           """)
           |> String.trim() == ""
  end

  test "relative_time/1 is the same words" do
    assert SlipdockComponents.relative_time(DateTime.add(DateTime.utc_now(), -3 * 86_400)) ==
             "3 days ago"
  end

  describe "ticking in the browser (#2025)" do
    defp time_el(html) do
      {:ok, doc} = Floki.parse_fragment(html)
      [el] = Floki.find(doc, "time")
      el
    end

    test "a relative moment is marked past, with the zone it was written in" do
      el =
        render_component(&SlipdockComponents.timestamp/1,
          at: DateTime.add(DateTime.utc_now(), -3 * 86_400),
          zone: "Pacific/Auckland"
        )
        |> time_el()

      assert Floki.attribute(el, "data-relative") == ["past"]
      assert Floki.attribute(el, "data-zone") == ["Pacific/Auckland"]
      assert Floki.text(el) == "3 days ago"
    end

    test "a moment ahead is marked future" do
      el =
        render_component(&SlipdockComponents.timestamp/1,
          at: DateTime.add(DateTime.utc_now(), 3 * 86_400)
        )
        |> time_el()

      assert Floki.attribute(el, "data-relative") == ["future"]
      assert Floki.text(el) == "in 3 days"
    end

    test "with no zone given, the process's zone, else UTC" do
      at = DateTime.add(DateTime.utc_now(), -3 * 86_400)

      el = render_component(&SlipdockComponents.timestamp/1, at: at) |> time_el()
      assert Floki.attribute(el, "data-zone") == ["Etc/UTC"]

      SlipdockWeb.Dates.put_zone("America/New_York")
      on_exit(fn -> SlipdockWeb.Dates.put_zone(nil) end)

      el = render_component(&SlipdockComponents.timestamp/1, at: at) |> time_el()
      assert Floki.attribute(el, "data-zone") == ["America/New_York"]
    end

    test "a naive datetime is UTC and is marked too" do
      el =
        render_component(&SlipdockComponents.timestamp/1, at: ~N[2025-03-04 10:00:00])
        |> time_el()

      assert Floki.attribute(el, "data-relative") == ["past"]
      assert Floki.text(el) == "4 Mar 2025"
    end

    test "fixed formats and bare dates don't tick" do
      for {at, format} <- [
            {~U[2025-11-18 23:30:00Z], :datetime},
            {~U[2025-11-18 23:30:00Z], :time},
            {~U[2025-11-18 23:30:00Z], :short},
            {~D[2025-03-04], :relative},
            {~D[2025-03-04], :long}
          ] do
        el =
          render_component(&SlipdockComponents.timestamp/1, at: at, format: format) |> time_el()

        assert Floki.attribute(el, "data-relative") == [], "#{inspect(at)} #{format}"
        assert Floki.attribute(el, "data-zone") == [], "#{inspect(at)} #{format}"
      end
    end
  end
end
