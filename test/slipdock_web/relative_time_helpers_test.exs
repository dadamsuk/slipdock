defmodule SlipdockWeb.RelativeTimeHelpersTest do
  @moduledoc """
  The expected label for a moment taken off the real clock (#1888): what
  `SlipdockWeb.Dates.relative/2` says for it either side of midnight UTC.
  """
  use ExUnit.Case, async: true

  import SlipdockWeb.RelativeTimeHelpers

  alias SlipdockWeb.Dates

  describe "expected_labels/4" do
    test "the label alone while the moment is still today" do
      at = ~U[2026-11-06 11:55:00Z]
      now = ~U[2026-11-06 12:00:00Z]

      assert expected_labels(at, "5 min ago", now, now) == ["5 min ago"]
      assert Dates.relative(at, now: now) == "5 min ago"
    end

    test "'yesterday' once midnight has passed, as Dates says" do
      at = ~U[2026-11-05 23:57:00Z]
      now = ~U[2026-11-06 00:02:00Z]

      assert expected_labels(at, "5 min ago", now, now) == ["yesterday"]
      assert Dates.relative(at, now: now) == "yesterday"
    end

    test "'3 h ago' reads 'yesterday' until 03:00 UTC" do
      at = ~U[2026-11-05 22:30:00Z]
      now = ~U[2026-11-06 01:30:00Z]

      assert expected_labels(at, "3 h ago", now, now) == ["yesterday"]
      assert Dates.relative(at, now: now) == "yesterday"
    end

    test "both when midnight fell during the render" do
      at = ~U[2026-11-05 23:54:59Z]
      before = ~U[2026-11-05 23:59:59Z]
      later = ~U[2026-11-06 00:00:01Z]

      assert expected_labels(at, "5 min ago", before, later) == ["5 min ago", "yesterday"]
      assert Dates.relative(at, now: before) == "5 min ago"
      assert Dates.relative(at, now: later) == "yesterday"
    end
  end

  describe "rendered_around/1" do
    test "returns the result between two readings of the clock" do
      {result, before, later} = rendered_around(fn -> :rendered end)

      assert result == :rendered
      assert DateTime.compare(before, later) in [:lt, :eq]
      assert DateTime.diff(DateTime.utc_now(), later, :second) < 5
    end
  end
end
