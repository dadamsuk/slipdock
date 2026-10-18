defmodule Slipdock.Recurrence.RuleTest do
  use ExUnit.Case, async: true

  alias Slipdock.Recurrence.Rule

  defp rule!(text, start \\ ~D[2027-01-11]) do
    {:ok, rule} = Rule.parse(text, start)
    rule
  end

  defp phrase!(text, start \\ ~D[2027-01-11]) do
    {:ok, rule} = Rule.parse_phrase(text, start)
    rule
  end

  # 11 Jan 2027 is a Monday.
  describe "upcoming dates" do
    for {text, start, after_date, expected} <- [
          {"FREQ=DAILY", ~D[2027-01-11], ~D[2027-01-11], ~w(2027-01-12 2027-01-13 2027-01-14)},
          {"FREQ=DAILY;INTERVAL=3", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-14 2027-01-17 2027-01-20)},
          {"FREQ=DAILY;BYDAY=SA,SU", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-16 2027-01-17 2027-01-23)},
          {"FREQ=WEEKLY", ~D[2027-01-11], ~D[2027-01-11], ~w(2027-01-18 2027-01-25 2027-02-01)},
          {"FREQ=WEEKLY;BYDAY=MO,TH", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-14 2027-01-18 2027-01-21)},
          {"FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-14 2027-01-25 2027-01-28)},
          {"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", ~D[2027-01-11], ~D[2027-01-15],
           ~w(2027-01-18 2027-01-19 2027-01-20)},
          # Before the start nothing counts: the first is the start itself.
          {"FREQ=WEEKLY;BYDAY=MO", ~D[2027-01-11], ~D[2027-01-01],
           ~w(2027-01-11 2027-01-18 2027-01-25)},
          {"FREQ=MONTHLY", ~D[2027-01-11], ~D[2027-01-11], ~w(2027-02-11 2027-03-11 2027-04-11)},
          {"FREQ=MONTHLY;BYMONTHDAY=1", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-02-01 2027-03-01 2027-04-01)},
          {"FREQ=MONTHLY;BYMONTHDAY=-1", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-31 2027-02-28 2027-03-31)},
          {"FREQ=MONTHLY;BYMONTHDAY=-2", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-30 2027-02-27 2027-03-30)},
          # The 31st in a 30-day month (and February) is that month's last day.
          {"FREQ=MONTHLY;BYMONTHDAY=31", ~D[2027-01-11], ~D[2027-01-31],
           ~w(2027-02-28 2027-03-31 2027-04-30)},
          {"FREQ=MONTHLY", ~D[2027-01-31], ~D[2027-01-31], ~w(2027-02-28 2027-03-31 2027-04-30)},
          {"FREQ=MONTHLY;BYMONTHDAY=1,15", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-15 2027-02-01 2027-02-15)},
          {"FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1", ~D[2027-01-01], ~D[2027-01-01],
           ~w(2027-04-01 2027-07-01 2027-10-01)},
          {"FREQ=MONTHLY;BYDAY=1MO", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-02-01 2027-03-01 2027-04-05)},
          {"FREQ=MONTHLY;BYDAY=-1FR", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-29 2027-02-26 2027-03-26)},
          {"FREQ=MONTHLY;BYDAY=2TU,4TU", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-12 2027-01-26 2027-02-09)},
          {"FREQ=MONTHLY;BYDAY=-2MO", ~D[2027-01-11], ~D[2027-01-11],
           ~w(2027-01-18 2027-02-15 2027-03-22)},
          {"FREQ=YEARLY", ~D[2027-03-12], ~D[2027-03-12], ~w(2028-03-12 2029-03-12 2030-03-12)},
          {"FREQ=YEARLY;INTERVAL=2", ~D[2027-03-12], ~D[2027-03-12],
           ~w(2029-03-12 2031-03-12 2033-03-12)},
          # A leap day: the last day of February in other years, the 29th in leap years.
          {"FREQ=YEARLY", ~D[2028-02-29], ~D[2028-02-29], ~w(2029-02-28 2030-02-28 2031-02-28)},
          {"FREQ=YEARLY", ~D[2027-02-28], ~D[2027-02-28], ~w(2028-02-28 2029-02-28 2030-02-28)},
          {"FREQ=YEARLY;BYMONTHDAY=-1", ~D[2027-02-01], ~D[2027-02-01],
           ~w(2027-02-28 2028-02-29 2029-02-28)},
          {"FREQ=YEARLY;BYDAY=-1MO", ~D[2027-05-01], ~D[2027-05-01],
           ~w(2027-05-31 2028-05-29 2029-05-28)}
        ] do
      test "#{text} from #{start}, after #{after_date}" do
        rule = rule!(unquote(text), unquote(Macro.escape(start)))
        dates = Rule.upcoming(rule, unquote(Macro.escape(after_date)), 3)
        assert Enum.map(dates, &Date.to_iso8601/1) == unquote(expected)
      end
    end

    test "an after-done rule has no dates of its own" do
      assert Rule.upcoming(rule!("AFTER=3D"), ~D[2027-01-11], 3) == []
      assert Rule.next_date(rule!("AFTER=3D"), ~D[2027-01-11]) == nil
    end

    test "a rule without a start counts from the day after" do
      {:ok, rule} = Rule.parse("FREQ=DAILY;INTERVAL=2")
      assert Rule.next_date(rule, ~D[2027-01-11]) == ~D[2027-01-12]
    end
  end

  describe "next/4 in a timezone" do
    test "today's occurrence counts while its time is still to come" do
      rule = rule!("FREQ=WEEKLY;BYDAY=MO")
      # 06:00 UTC on Monday 11 Jan is 06:00 in London, before 07:00.
      assert Rule.next(rule, ~U[2027-01-11 06:00:00Z], "Europe/London") ==
               ~U[2027-01-11 07:00:00Z]

      # At or after 07:00 it is next week's.
      assert Rule.next(rule, ~U[2027-01-11 07:00:00Z], "Europe/London") ==
               ~U[2027-01-18 07:00:00Z]
    end

    test "the local date decides the day, not the UTC one" do
      rule = rule!("FREQ=DAILY")
      # 23:30 UTC on the 11th is already the 12th in Tokyo, past 07:00.
      assert Rule.next(rule, ~U[2027-01-11 23:30:00Z], "Asia/Tokyo", ~T[07:00:00]) ==
               ~U[2027-01-12 22:00:00Z]
    end

    test "07:00 stays 07:00 across the spring change in London" do
      rule = rule!("FREQ=DAILY", ~D[2027-03-26])
      # 27 March is GMT, 28 March (the change) and after are BST.
      assert Rule.next(rule, ~U[2027-03-26 08:00:00Z], "Europe/London") ==
               ~U[2027-03-27 07:00:00Z]

      assert Rule.next(rule, ~U[2027-03-27 08:00:00Z], "Europe/London") ==
               ~U[2027-03-28 06:00:00Z]
    end

    test "and across the autumn change in New York" do
      rule = rule!("FREQ=WEEKLY;BYDAY=SU", ~D[2027-10-31])
      # 31 Oct is EDT (-4), 7 Nov (the change) EST (-5).
      assert Rule.next(rule, ~U[2027-10-30 00:00:00Z], "America/New_York") ==
               ~U[2027-10-31 11:00:00Z]

      assert Rule.next(rule, ~U[2027-10-31 12:00:00Z], "America/New_York") ==
               ~U[2027-11-07 12:00:00Z]
    end

    test "a time in the skipped hour happens just after it, and a repeated one once" do
      rule = rule!("FREQ=DAILY", ~D[2027-03-27])

      assert Rule.next(rule, ~U[2027-03-27 12:00:00Z], "Europe/London", ~T[01:30:00]) ==
               ~U[2027-03-28 01:00:00Z]

      ny = rule!("FREQ=DAILY", ~D[2027-11-06])
      first = Rule.next(ny, ~U[2027-11-06 12:00:00Z], "America/New_York", ~T[01:30:00])
      assert first == ~U[2027-11-07 05:30:00Z]
      # The next is the 8th, not the repeat of 01:30 on the 7th.
      assert Rule.next(ny, first, "America/New_York", ~T[01:30:00]) == ~U[2027-11-08 06:30:00Z]
    end

    test "after done counts from the local day it was done" do
      # Done at 23:30 UTC on the 11th: the 12th in Tokyo, so three days on is the 15th.
      assert Rule.next(rule!("AFTER=3D"), ~U[2027-01-11 23:30:00Z], "Asia/Tokyo") ==
               ~U[2027-01-14 22:00:00Z]

      assert Rule.next(rule!("AFTER=2W"), ~U[2027-01-11 12:00:00Z], "Etc/UTC") ==
               ~U[2027-01-25 07:00:00Z]

      # A month after the 31st of January is the last day of February.
      assert Rule.next(rule!("AFTER=1M"), ~U[2027-01-31 12:00:00Z], "Etc/UTC") ==
               ~U[2027-02-28 07:00:00Z]
    end
  end

  describe "within_end?/3" do
    test "never, on a date, after a count" do
      assert Rule.within_end?("never", ~D[2099-01-01], 1000)
      assert Rule.within_end?({"on", ~D[2027-02-01]}, ~D[2027-02-01], 0)
      refute Rule.within_end?({"on", ~D[2027-02-01]}, ~D[2027-02-02], 0)
      assert Rule.within_end?({"after", 3}, ~D[2027-02-01], 2)
      refute Rule.within_end?({"after", 3}, ~D[2027-02-01], 3)
    end
  end

  describe "parse/2 and to_string/1" do
    for text <- [
          "FREQ=DAILY",
          "FREQ=DAILY;INTERVAL=3",
          "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH",
          "FREQ=MONTHLY;BYMONTHDAY=-1",
          "FREQ=MONTHLY;BYDAY=1MO",
          "FREQ=MONTHLY;BYDAY=-1FR",
          "FREQ=YEARLY",
          "AFTER=3D",
          "AFTER=2W",
          "AFTER=1M"
        ] do
      test "round trips #{text}" do
        assert Rule.to_string(rule!(unquote(text))) == unquote(text)
      end
    end

    test "is forgiving about case, a prefix and a +ordinal" do
      assert Rule.to_string(rule!("rrule:freq=monthly;byday=+2tu")) == "FREQ=MONTHLY;BYDAY=2TU"
    end

    for {text, message} <- [
          {"", "empty"},
          {"FREQ=HOURLY", "FREQ must be"},
          {"FREQ=DAILY;INTERVAL=0", "INTERVAL"},
          {"FREQ=DAILY;INTERVAL=100", "INTERVAL"},
          {"FREQ=DAILY;INTERVAL=x", "INTERVAL"},
          {"FREQ=WEEKLY;BYDAY=XX", "isn't a day"},
          {"FREQ=WEEKLY;BYDAY=1MO", "only goes with FREQ=MONTHLY"},
          {"FREQ=MONTHLY;BYDAY=6MO", "1 to 5"},
          {"FREQ=MONTHLY;BYDAY=0MO", "1 to 5"},
          {"FREQ=MONTHLY;BYMONTHDAY=32", "BYMONTHDAY must be"},
          {"FREQ=MONTHLY;BYMONTHDAY=0", "BYMONTHDAY must be"},
          {"FREQ=WEEKLY;BYMONTHDAY=1", "only goes with FREQ=MONTHLY or YEARLY"},
          {"FREQ=MONTHLY;BYDAY=MO;BYMONTHDAY=1", "not both"},
          {"FREQ=DAILY;COUNT=3", "COUNT isn't supported"},
          {"FREQ=DAILY;FREQ=WEEKLY", "twice"},
          {"INTERVAL=2", "needs FREQ"},
          {"FREQ", "isn't KEY=VALUE"},
          {"AFTER=3X", "AFTER is a number"},
          {"AFTER=0D", "AFTER must be"},
          {"AFTER=3D;FREQ=DAILY", "FREQ isn't supported"}
        ] do
      test "refuses #{inspect(text)}" do
        assert {:error, message} = Rule.parse(unquote(text))
        assert message =~ unquote(message)
      end
    end

    test "refuses what isn't text" do
      assert {:error, _} = Rule.parse(nil)
      assert {:error, _} = Rule.parse_phrase(nil)
    end
  end

  describe "parse_phrase/2" do
    for {phrase, rrule} <- [
          {"every day", "FREQ=DAILY"},
          {"daily", "FREQ=DAILY"},
          {"3d", "FREQ=DAILY;INTERVAL=3"},
          {"every 3 days", "FREQ=DAILY;INTERVAL=3"},
          {"weekday", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"},
          {"every weekdays", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"},
          {"week", "FREQ=WEEKLY"},
          {"2w", "FREQ=WEEKLY;INTERVAL=2"},
          {"fortnight", "FREQ=WEEKLY;INTERVAL=2"},
          {"mon", "FREQ=WEEKLY;BYDAY=MO"},
          {"every Monday", "FREQ=WEEKLY;BYDAY=MO"},
          {"mon,thu", "FREQ=WEEKLY;BYDAY=MO,TH"},
          {"tue thu", "FREQ=WEEKLY;BYDAY=TU,TH"},
          {"2w mon thu", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH"},
          {"week fri", "FREQ=WEEKLY;BYDAY=FR"},
          {"month", "FREQ=MONTHLY"},
          {"month 1", "FREQ=MONTHLY;BYMONTHDAY=1"},
          {"month 15th", "FREQ=MONTHLY;BYMONTHDAY=15"},
          {"month last", "FREQ=MONTHLY;BYMONTHDAY=-1"},
          {"month last fri", "FREQ=MONTHLY;BYDAY=-1FR"},
          {"month first mon", "FREQ=MONTHLY;BYDAY=1MO"},
          {"month 2nd tuesday", "FREQ=MONTHLY;BYDAY=2TU"},
          {"3m 1", "FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1"},
          {"2 months", "FREQ=MONTHLY;INTERVAL=2"},
          {"year", "FREQ=YEARLY"},
          {"annually", "FREQ=YEARLY"},
          {"3d after", "AFTER=3D"},
          {"every 2w after done", "AFTER=2W"},
          {"month after", "AFTER=1M"},
          {"FREQ=WEEKLY;BYDAY=FR", "FREQ=WEEKLY;BYDAY=FR"}
        ] do
      test "#{inspect(phrase)} is #{rrule}" do
        assert Rule.to_string(phrase!(unquote(phrase))) == unquote(rrule)
      end
    end

    test "keeps the start it is given" do
      assert phrase!("mon", ~D[2027-03-01]).start == ~D[2027-03-01]
    end

    for phrase <- [
          "",
          "every",
          "sometimes",
          "mon blursday",
          "month 32",
          "month last blursday",
          "month 1 2 3",
          "year after",
          "0d",
          "100w",
          "weekday mon"
        ] do
      test "refuses #{inspect(phrase)}" do
        assert {:error, message} = Rule.parse_phrase(unquote(phrase))
        assert is_binary(message)
      end
    end
  end

  describe "summary" do
    for {text, start, words} <- [
          {"FREQ=DAILY", nil, "Every day"},
          {"FREQ=DAILY;INTERVAL=3", nil, "Every 3 days"},
          {"FREQ=DAILY;BYDAY=SA,SU", nil, "Every day on Sat and Sun"},
          {"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", nil, "Every weekday"},
          {"FREQ=WEEKLY", ~D[2027-01-13], "Every week on Wed"},
          {"FREQ=WEEKLY", nil, "Every week"},
          {"FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH", nil, "Every 2 weeks on Mon and Thu"},
          {"FREQ=WEEKLY;BYDAY=MO,WE,FR", nil, "Every week on Mon, Wed and Fri"},
          {"FREQ=MONTHLY", ~D[2027-01-12], "Every month on the 12th"},
          {"FREQ=MONTHLY;BYMONTHDAY=1", nil, "Every month on the 1st"},
          {"FREQ=MONTHLY;BYMONTHDAY=22", nil, "Every month on the 22nd"},
          {"FREQ=MONTHLY;BYMONTHDAY=13", nil, "Every month on the 13th"},
          {"FREQ=MONTHLY;BYMONTHDAY=-1", nil, "Every month on the last day"},
          {"FREQ=MONTHLY;BYMONTHDAY=-3", nil, "Every month on the 3rd last day"},
          {"FREQ=MONTHLY;BYDAY=-1FR", nil, "Every month on the last Friday"},
          {"FREQ=MONTHLY;INTERVAL=3;BYDAY=1MO", nil, "Every 3 months on the 1st Monday"},
          {"FREQ=MONTHLY;BYDAY=-2TU", nil, "Every month on the 2nd last Tuesday"},
          {"FREQ=YEARLY", ~D[2027-03-12], "Every year on 12 Mar"},
          {"FREQ=YEARLY;BYDAY=-1MO", ~D[2027-05-01], "Every year on the last Monday of May"},
          {"AFTER=1D", nil, "1 day after the last one is done"},
          {"AFTER=3W", nil, "3 weeks after the last one is done"}
        ] do
      test "#{text} reads #{inspect(words)}" do
        assert Rule.summary(rule!(unquote(text), unquote(Macro.escape(start)))) ==
                 unquote(words)
      end
    end

    test "with the time and zone" do
      assert Rule.summary(
               rule!("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH"),
               ~T[07:00:00],
               "Europe/London"
             ) ==
               "Every 2 weeks on Mon and Thu, 07:00 Europe/London"
    end
  end
end
