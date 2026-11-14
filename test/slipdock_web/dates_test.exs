defmodule SlipdockWeb.DatesTest do
  use ExUnit.Case, async: true

  alias SlipdockWeb.Dates

  @today ~D[2026-11-18]
  @now ~U[2026-11-18 12:00:00Z]

  setup do
    on_exit(fn -> Dates.put_zone(nil) end)
    :ok
  end

  describe "short/2" do
    test "leaves the year off this year's dates and puts it on others" do
      assert Dates.short(~D[2026-11-18], today: @today) == "18 Nov"
      assert Dates.short(~D[2026-01-03], today: @today) == "3 Jan"
      assert Dates.short(~D[2025-11-18], today: @today) == "18 Nov 2025"
      assert Dates.short(~D[2027-02-01], today: @today) == "1 Feb 2027"
    end

    test "takes datetimes and naive datetimes" do
      assert Dates.short(~U[2026-11-18 09:00:00Z], now: @now) == "18 Nov"
      assert Dates.short(~N[2026-11-18 09:00:00], now: @now) == "18 Nov"
    end

    test "nil reads as nothing" do
      assert Dates.short(nil) == ""
      assert Dates.long(nil) == ""
      assert Dates.weekday(nil) == ""
      assert Dates.weekday_long(nil) == ""
      assert Dates.full(nil) == ""
      assert Dates.datetime(nil) == ""
      assert Dates.time(nil) == ""
      assert Dates.exact(nil) == ""
      assert Dates.relative(nil) == ""
    end
  end

  test "long/2 always has the year" do
    assert Dates.long(~D[2026-11-18]) == "18 Nov 2026"
    assert Dates.long(~U[2025-03-04 10:00:00Z]) == "4 Mar 2025"
  end

  test "weekday_long/2 has the weekday and always the year (#2880)" do
    assert Dates.weekday_long(~D[2026-11-18]) == "Wed 18 Nov 2026"
    assert Dates.weekday_long(~D[2025-03-04]) == "Tue 4 Mar 2025"
    # A moment is read on the viewer's calendar: late on the 18th in UTC is
    # already Thursday the 19th in Auckland.
    assert Dates.weekday_long(~U[2026-11-18 23:30:00Z], zone: "Pacific/Auckland") ==
             "Thu 19 Nov 2026"

    assert Dates.weekday_long(~U[2026-11-18 23:30:00Z], zone: "Etc/UTC") == "Wed 18 Nov 2026"
    assert Dates.weekday_long(~N[2026-11-18 09:00:00]) == "Wed 18 Nov 2026"
  end

  test "weekday/2 and full/2" do
    assert Dates.weekday(~D[2026-11-18], today: @today) == "Wed 18 Nov"
    assert Dates.weekday(~D[2025-11-18], today: @today) == "Tue 18 Nov 2025"
    assert Dates.full(~D[2026-11-18]) == "Wednesday 18 November 2026"
  end

  describe "the viewer's timezone" do
    # 23:30 UTC on the 18th is already the 19th in Auckland, and still the
    # 18th in Los Angeles: the date follows the reader, not the server.
    @late ~U[2026-11-18 23:30:00Z]

    test "a time east of UTC can be the next day" do
      assert Dates.datetime(@late, zone: "Pacific/Auckland", now: @now) == "19 Nov, 12:30"
      assert Dates.short(@late, zone: "Pacific/Auckland", now: @now) == "19 Nov"
    end

    test "a time west of UTC can be the day before" do
      early = ~U[2026-11-18 02:00:00Z]
      assert Dates.datetime(early, zone: "America/Los_Angeles", now: @now) == "17 Nov, 18:00"
      assert Dates.time(early, zone: "America/Los_Angeles") == "18:00"
    end

    test "the process zone applies when no :zone is given" do
      Dates.put_zone("Pacific/Auckland")
      assert Dates.zone() == "Pacific/Auckland"
      assert Dates.datetime(@late, now: @now) == "19 Nov, 12:30"
      Dates.put_zone(nil)
      assert Dates.zone() == "Etc/UTC"
      assert Dates.datetime(@late, now: @now) == "18 Nov, 23:30"
    end

    test "an unknown zone falls back to UTC rather than raising" do
      assert Dates.datetime(@late, zone: "Not/AZone", now: @now) == "18 Nov, 23:30"
    end

    test "a bare date is never shifted" do
      assert Dates.short(~D[2026-11-18], zone: "Pacific/Auckland", today: @today) == "18 Nov"
    end

    test "the year is the viewer's: New Year's Eve in UTC is next year in Auckland" do
      nye = ~U[2026-12-31 20:00:00Z]
      now = ~U[2026-12-31 20:05:00Z]
      assert Dates.short(nye, zone: "Etc/UTC", now: now) == "31 Dec"
      assert Dates.short(nye, zone: "Pacific/Auckland", now: now) == "1 Jan"

      assert Dates.short(nye, zone: "Pacific/Auckland", now: ~U[2026-12-01 00:00:00Z]) ==
               "1 Jan 2027"
    end
  end

  describe "datetime/2, time/2 and exact/2" do
    test "write the clock in 24 hours" do
      assert Dates.datetime(~U[2026-11-04 11:43:00Z], now: @now) == "4 Nov, 11:43"
      assert Dates.datetime(~U[2025-11-04 08:05:00Z], now: @now) == "4 Nov 2025, 08:05"
      assert Dates.time(~T[07:05:00]) == "07:05"
    end

    test "a bare date as datetime is the short date" do
      assert Dates.datetime(~D[2026-11-04], today: @today) == "4 Nov"
    end

    test "exact/2 names the zone" do
      assert Dates.exact(~U[2026-11-04 11:43:00Z]) == "4 Nov 2026, 11:43 UTC"

      assert Dates.exact(~U[2026-07-04 11:43:00Z], zone: "Europe/London") ==
               "4 Jul 2026, 12:43 BST"

      assert Dates.exact(~D[2026-11-04]) == "Wednesday 4 November 2026"
    end
  end

  test "range/3 joins two short dates" do
    assert Dates.range(~D[2026-10-31], ~D[2026-11-05], today: @today) == "31 Oct → 5 Nov"
    assert Dates.range(~D[2026-12-20], ~D[2027-01-05], today: @today) == "20 Dec → 5 Jan 2027"
  end

  describe "relative/2" do
    defp ago(seconds, opts \\ []),
      do: Dates.relative(DateTime.add(@now, -seconds), Keyword.put_new(opts, :now, @now))

    test "the past" do
      assert ago(0) == "just now"
      assert ago(59) == "just now"
      assert ago(60) == "1 min ago"
      assert ago(5 * 60) == "5 min ago"
      assert ago(3 * 3600) == "3 h ago"
      assert ago(24 * 3600) == "yesterday"
      assert ago(3 * 86_400) == "3 days ago"
      assert ago(6 * 86_400) == "6 days ago"
      assert ago(7 * 86_400) == "11 Nov"
      assert ago(400 * 86_400) == "14 Oct 2025"
    end

    test "the future" do
      assert ago(-30) == "in 1 min"
      assert ago(-10 * 60) == "in 10 min"
      assert ago(-2 * 3600) == "in 2 h"
      assert ago(-86_400) == "tomorrow"
      assert ago(-3 * 86_400) == "in 3 days"
      assert ago(-8 * 86_400) == "26 Nov"
    end

    test "days are counted on the viewer's calendar" do
      now = ~U[2026-11-18 00:10:00Z]
      assert Dates.relative(~U[2026-11-17 23:50:00Z], now: now) == "yesterday"
      # In Auckland both are the afternoon of the 18th.
      assert Dates.relative(~U[2026-11-17 23:50:00Z], now: now, zone: "Pacific/Auckland") ==
               "20 min ago"
    end

    test "a bare date is a day" do
      assert Dates.relative(~D[2026-11-18], today: @today) == "today"
      assert Dates.relative(~D[2026-11-17], today: @today) == "yesterday"
      assert Dates.relative(~D[2026-11-21], today: @today) == "in 3 days"
      assert Dates.relative(~D[2026-10-01], today: @today) == "1 Oct"
    end
  end
end
