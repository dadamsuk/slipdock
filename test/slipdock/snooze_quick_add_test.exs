defmodule Slipdock.SnoozeQuickAddTest do
  @moduledoc "Quick add's `snooze:` (W-1803), and the picker's presets."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Accounts, QuickAdd, Repo, Snooze}
  alias Slipdock.Boards.Card
  alias Slipdock.QuickAdd.Capture

  @board %{columns: [], tags: []}
  # Wednesday 13 January 2027.
  @today ~D[2027-01-13]

  describe "QuickAdd.parse/3 snooze:" do
    for {line, title, date} <- [
          {"Renew the domain snooze: mon", "Renew the domain", ~D[2027-01-18]},
          {"snooze: tomorrow Call the bank", "Call the bank", ~D[2027-01-14]},
          {"Plan Q2 snooze: next month", "Plan Q2", ~D[2027-02-01]},
          {"Chase snooze: in 3 days", "Chase", ~D[2027-01-16]},
          {"Taxes snooze:2027-04-01", "Taxes", ~D[2027-04-01]}
        ] do
      test "#{inspect(line)}" do
        parsed = QuickAdd.parse(unquote(line), @board, today: @today)
        assert parsed.title == unquote(title)
        assert parsed.snooze == unquote(Macro.escape(date))
        assert {:snooze, "💤 " <> _} = List.keyfind(parsed.chips, :snooze, 0)
        assert QuickAdd.commands?(parsed)
      end
    end

    test "sits alongside due:, without taking it" do
      parsed = QuickAdd.parse("Report snooze: mon due: fri", @board, today: @today)
      assert parsed.title == "Report"
      assert parsed.snooze == ~D[2027-01-18]
      assert parsed.attrs["due_date"] == "2027-01-15"
    end

    test "today, the past or something unreadable stays in the title" do
      for line <- ["Tidy snooze: today", "Tidy snooze: yesterday", "Tidy snooze: whenever"] do
        parsed = QuickAdd.parse(line, @board, today: @today)
        assert parsed.snooze == nil
        assert parsed.title == line
      end
    end

    test "take_snooze/2 alone" do
      assert QuickAdd.take_snooze("Call snooze: fri", @today) == {"Call  ", ~D[2027-01-15]}
      assert QuickAdd.take_snooze("Call the bank", @today) == {"Call the bank", nil}
    end
  end

  describe "Snooze.presets/1" do
    test "tomorrow, next Monday, a week today and the first of next month" do
      assert Snooze.presets(@today) == [
               {"tomorrow", "Tomorrow", ~D[2027-01-14]},
               {"monday", "Next Monday", ~D[2027-01-18]},
               {"week", "In a week", ~D[2027-01-20]},
               {"month", "Next month", ~D[2027-02-01]}
             ]
    end

    test "on a Monday, next Monday is a week away; at the end of a year, next month is January" do
      assert {"monday", _, ~D[2027-01-18]} = Enum.at(Snooze.presets(~D[2027-01-11]), 1)
      assert {"month", _, ~D[2028-01-01]} = Enum.at(Snooze.presets(~D[2027-12-31]), 3)
    end
  end

  describe "the header's quick add" do
    test "snooze: adds the card asleep, and says so", _ do
      user = user_fixture()
      {:ok, user} = Accounts.update_quick_add(user, %{"quick_add_ai" => false})
      board_fixture(%{"name" => "Plan"}, owner: user)
      user = Repo.reload!(user)

      today = Date.utc_today()

      assert {:ok, capture} =
               Capture.capture(user, "Renew the domain snooze: tomorrow", today: today)

      assert capture.card.title == "Renew the domain"
      card = Repo.get!(Card, capture.card.id)
      assert card.snoozed_until == DateTime.new!(Date.add(today, 1), ~T[00:00:00], "Etc/UTC")
      assert Enum.any?(capture.chips, &match?({:snooze, "💤 " <> _}, &1))
    end
  end
end
