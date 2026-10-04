defmodule Slipdock.TimeTrackingTest do
  use ExUnit.Case, async: true

  alias Slipdock.TimeTracking, as: T

  describe "parse/2" do
    test "a bare number is in the unit given" do
      assert T.parse("90", "minutes") == {:ok, 90}
      assert T.parse("1.5", "hours") == {:ok, 90}
      assert T.parse(".5", "hours") == {:ok, 30}
      assert T.parse(2, "days") == {:ok, 960}
      assert T.parse(0.25, "hours") == {:ok, 15}
    end

    test "a suffix overrides the unit, and several add up" do
      assert T.parse("45m", "days") == {:ok, 45}
      assert T.parse("1.5h", "minutes") == {:ok, 90}
      assert T.parse("1h 30m", "days") == {:ok, 90}
      assert T.parse("1h30m", "days") == {:ok, 90}
      assert T.parse("2 hours", "minutes") == {:ok, 120}
      assert T.parse("1 day", "hours") == {:ok, 480}
      assert T.parse("1w", "hours") == {:ok, 5 * 480}
      assert T.parse("1mo", "hours") == {:ok, 20 * 480}
      assert T.parse("3 mins", "hours") == {:ok, 3}
    end

    test "blank clears, nonsense is an error" do
      assert T.parse("", "hours") == {:ok, nil}
      assert T.parse("  ", "hours") == {:ok, nil}
      assert T.parse(nil, "hours") == {:ok, nil}
      assert T.parse("soon", "hours") == :error
      assert T.parse("1x", "hours") == :error
      assert T.parse("-1", "hours") == :error
      assert T.parse(-1, "hours") == :error
      assert T.parse("1.", "hours") == :error
    end
  end

  test "in_unit/2 and format/2 show minutes in the card's unit" do
    assert T.in_unit(90, "hours") == 1.5
    assert T.in_unit(120, "hours") == 2
    assert T.in_unit(nil, "hours") == nil
    assert T.format(960, "days") == "2d"
    assert T.format(100, "hours") == "1.67h"
    assert T.format(30, "months") == "0mo"
  end

  test "percent/1 can pass 100 and status/1 colours it" do
    assert T.percent(%{time_spent: 30, time_estimate: 60}) == 50
    assert T.percent(%{time_spent: 90, time_estimate: 60}) == 150
    assert T.percent(%{time_spent: 90, time_estimate: nil}) == nil
    assert T.percent(%{time_spent: 90, time_estimate: 0}) == nil

    assert T.status(50) == :under
    assert T.status(80) == :near
    assert T.status(100) == :near
    assert T.status(101) == :over
    assert T.status(nil) == nil
  end

  test "a running timer counts towards time spent" do
    now = ~U[2026-10-04 12:00:00Z]
    card = %{time_spent: 60, time_estimate: 120, timer_started_at: ~U[2026-10-04 11:30:00Z]}

    assert T.running(card, now) == 30
    assert T.spent(card, now) == 90
    assert T.percent(card, now) == 75
    assert T.running?(card)
    assert T.tracked?(%{time_spent: nil, time_estimate: nil, timer_started_at: nil}) == false
  end

  describe "normalize_attrs/2" do
    test "reads spent and estimate in the unit the write leaves the card in" do
      card = %{time_unit: "hours", time_spent: nil}

      assert T.normalize_attrs(card, %{"time_spent" => "2", "time_estimate" => "1d"}) ==
               %{"time_spent" => 120, "time_estimate" => 480}

      assert T.normalize_attrs(card, %{"time_unit" => "days", "time_estimate" => "2"}) ==
               %{"time_unit" => "days", "time_estimate" => 960}
    end

    test "log_time adds to, or takes off, what is spent — never below zero" do
      card = %{time_unit: "hours", time_spent: 60}
      assert T.normalize_attrs(card, %{"log_time" => "30m"}) == %{"time_spent" => 90}
      assert T.normalize_attrs(card, %{"log_time" => "-30m"}) == %{"time_spent" => 30}
      assert T.normalize_attrs(card, %{"log_time" => "-5h"}) == %{"time_spent" => 0}

      assert T.normalize_attrs(%{time_unit: "hours", time_spent: nil}, %{"log_time" => 1}) ==
               %{"time_spent" => 60}
    end

    test "something unreadable is left for the changeset to reject" do
      assert T.normalize_attrs(%{time_unit: "hours"}, %{"time_spent" => "lots"}) ==
               %{"time_spent" => "invalid"}

      assert T.normalize_attrs(%{time_unit: "hours", time_spent: 0}, %{"log_time" => "lots"}) ==
               %{"time_spent" => "invalid"}
    end
  end
end
