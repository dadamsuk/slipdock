defmodule SlipdockWeb.TimestampTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias SlipdockWeb.SlipdockComponents

  test "writes the relative time, with the exact time in the title" do
    at = DateTime.add(DateTime.utc_now(), -5 * 60)

    html = render_component(&SlipdockComponents.timestamp/1, at: at, id: "t")
    {:ok, doc} = Floki.parse_fragment(html)
    [el] = Floki.find(doc, "time#t")

    assert Floki.text(el) == "5 min ago"
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
end
