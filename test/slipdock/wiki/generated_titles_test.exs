defmodule Slipdock.Wiki.GeneratedTitlesTest do
  use ExUnit.Case, async: true

  import Slipdock.Wiki.GeneratedTitles

  doctest Slipdock.Wiki.GeneratedTitles, import: true

  describe "pass_log/1" do
    test "the titles the runner wrote" do
      assert pass_log(
               "Pass log #1004: ALlow the creation of an archived card from MCP and API and CLI (2026-10-16 16:33)"
             ) == "Pass 1004 (2026-10-16 16.33)"

      assert pass_log(
               "Pass log #1005: list_cards doesn't work with column and full true (2026-10-16 16:44)"
             ) ==
               "Pass 1005 (2026-10-16 16.44)"
    end

    test "as they are on disk" do
      assert pass_log("Pass log #775- Fix the thing (2026-10-18 01-09)") ==
               "Pass 775 (2026-10-18 01.09)"

      assert pass_log("Pass log 775- Fix the thing (2026-10-18 01-09)") ==
               "Pass 775 (2026-10-18 01.09)"
    end

    test "with no time, and with no date" do
      assert pass_log("Pass log #775: Fix the thing (2026-10-18)") == "Pass 775 (2026-10-18)"
      assert pass_log("Pass log #775: Fix the thing") == "Pass 775"
      assert pass_log("Pass log #775") == "Pass 775"
    end

    test "other # numbers and brackets in the card's title change nothing" do
      assert pass_log("Pass log #12: Fix #99 (urgent) again (2026-10-18 01:09)") ==
               "Pass 12 (2026-10-18 01.09)"

      assert pass_log("Pass log #12: Fix (urgent)") == "Pass 12"
    end

    test "seconds are dropped" do
      assert pass_log("Pass log #12: x (2026-10-18 01:09:33)") == "Pass 12 (2026-10-18 01.09)"
    end

    test "the same pass twice gives the same title: the folder tells them apart" do
      old = "Pass log #775: Fix it (2026-10-18 01:09)"
      assert pass_log(old) == pass_log(old <> " ")
    end

    test "nil for anything else, a new title among them" do
      for title <- [
            "Pass 775 (2026-10-18 01.09)",
            "Pass log",
            "Pass logs #775: x",
            "Pass log: what a pass log is",
            "Pass log #abc: x",
            "Pass log #775x: y",
            "A Pass log #775: x",
            "",
            nil
          ] do
        assert pass_log(title) == nil, inspect(title)
      end
    end
  end

  describe "fired/3" do
    @day ~D[2026-11-01]

    test "the rule, the card and the date" do
      assert fired("Chase", "Parked jobs", @day) == "Chase: Parked jobs 2026-11-01"
    end

    test "no card" do
      assert fired("Weekly", nil, @day) == "Weekly 2026-11-01"
      assert fired("Weekly", "  ", @day) == "Weekly 2026-11-01"
    end

    test "no rule name" do
      assert fired(nil, nil, @day) == "Automation 2026-11-01"
    end

    test "fits a title, however long the parts" do
      long = String.duplicate("word ", 60)
      assert String.length(fired(long, long, @day)) <= 200
    end
  end
end
