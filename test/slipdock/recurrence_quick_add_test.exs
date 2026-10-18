defmodule Slipdock.RecurrenceQuickAddTest do
  @moduledoc "Quick add's `every:` (W-1802), and the Repeat… dialog's presets and preview."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Accounts, QuickAdd, Recurrence, Repo}
  alias Slipdock.QuickAdd.Capture

  @board %{columns: [], tags: []}

  describe "QuickAdd.parse/3 every:" do
    for {line, title, rule, chip} <- [
          {"Review invoices every: mon", "Review invoices", "FREQ=WEEKLY;BYDAY=MO",
           "↻ Every week on Mon"},
          {"Standup every: weekday", "Standup", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
           "↻ Every weekday"},
          {"Backups every: 2w", "Backups", "FREQ=WEEKLY;INTERVAL=2", "↻ Every 2 weeks"},
          {"Rent every: month 1", "Rent", "FREQ=MONTHLY;BYMONTHDAY=1",
           "↻ Every month on the 1st"},
          {"Payroll every: month last fri", "Payroll", "FREQ=MONTHLY;BYDAY=-1FR",
           "↻ Every month on the last Friday"},
          {"Water the plants every: 3d after", "Water the plants", "AFTER=3D",
           "↻ 3 days after the last one is done"},
          {"every: mon, thu Gym", "Gym", "FREQ=WEEKLY;BYDAY=MO,TH", "↻ Every week on Mon and Thu"}
        ] do
      test "#{inspect(line)}" do
        parsed = QuickAdd.parse(unquote(line), @board, today: ~D[2027-01-11])
        assert parsed.title == unquote(title)
        assert parsed.recurrence == unquote(rule)
        assert {:repeat, unquote(chip)} in parsed.chips
        assert QuickAdd.commands?(parsed)
      end
    end

    test "sits alongside the other commands" do
      parsed = QuickAdd.parse("Report every: mon due: tomorrow", @board, today: ~D[2027-01-11])
      assert parsed.title == "Report"
      assert parsed.recurrence == "FREQ=WEEKLY;BYDAY=MO"
      assert parsed.attrs["due_date"] == "2027-01-12"
    end

    test "one it can't read stays in the title, and isn't a command" do
      parsed = QuickAdd.parse("Tidy up every: sometimes", @board)
      assert parsed.title == "Tidy up every: sometimes"
      assert parsed.recurrence == nil
      refute QuickAdd.commands?(parsed)
    end

    test "'every' without a colon is just a word" do
      parsed = QuickAdd.parse("Check every mon", @board)
      assert parsed.title == "Check every mon"
      assert parsed.recurrence == nil
    end
  end

  describe "the header's quick add" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Plan"})
      %{user: Repo.reload!(user), board: reload(board)}
    end

    test "without the model, every: makes the card recurring and says so", %{user: user} do
      {:ok, user} = Accounts.update_quick_add(user, %{"quick_add_ai" => false})

      assert {:ok, capture} =
               Capture.capture(user, "Review invoices every: mon #todo", today: ~D[2026-09-28])

      assert capture.card.title == "Review invoices"
      series = Recurrence.for_card(capture.card)
      assert series.rule == "FREQ=WEEKLY;BYDAY=MO"
      assert Enum.any?(capture.chips, &match?({:repeat, "↻ Every week on Mon" <> _}, &1))
    end

    test "with the model, every: is read here and never sent to it", %{user: user} do
      Slipdock.AIStub.reply_with(%{"title" => "Pay the rent"})

      assert {:ok, capture} = Capture.capture(user, "pay the rent every: month 1")
      assert capture.card.title == "Pay the rent"
      assert Recurrence.for_card(capture.card).rule == "FREQ=MONTHLY;BYMONTHDAY=1"

      assert_receive {:ai_request, %{"messages" => messages}}
      refute inspect(messages) =~ "every:"
    end
  end

  describe "presets/1" do
    test "worded for the card's date" do
      # Tuesday 12 January 2027: the second Tuesday.
      presets = Map.new(Recurrence.presets(~D[2027-01-12]), fn {rule, label} -> {label, rule} end)

      assert presets["Daily"] == "FREQ=DAILY"
      assert presets["Every weekday (Monday to Friday)"] == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
      assert presets["Weekly on Tuesday"] == "FREQ=WEEKLY;BYDAY=TU"
      assert presets["Monthly on the 12th"] == "FREQ=MONTHLY;BYMONTHDAY=12"
      assert presets["Monthly on the second Tuesday"] == "FREQ=MONTHLY;BYDAY=2TU"
      assert presets["Yearly on 12 January"] == "FREQ=YEARLY"
      assert presets["A week after the last one is done"] == "AFTER=1W"
    end

    test "the last week of the month is the last, not the fourth or fifth" do
      # Friday 29 January 2027 is the fifth and last Friday.
      labels = Enum.map(Recurrence.presets(~D[2027-01-29]), &elem(&1, 1))
      assert "Monthly on the last Friday" in labels
      # Friday 22 January is the fourth, with another to come.
      labels = Enum.map(Recurrence.presets(~D[2027-01-22]), &elem(&1, 1))
      assert "Monthly on the fourth Friday" in labels
      assert "Monthly on the 22nd" in labels
    end

    test "every preset is a rule the engine reads" do
      for {rule, _} <- Recurrence.presets(~D[2027-01-31]),
          do: assert({:ok, _} = Slipdock.Recurrence.Rule.parse(rule))
    end
  end

  describe "describe/4" do
    test "the summary and the next three dates, from the given day" do
      assert {:ok, %{rule: "FREQ=WEEKLY;BYDAY=MO", summary: summary, dates: dates}} =
               Recurrence.describe("every mon", "08:15", "Europe/London", ~D[2027-01-11])

      assert summary == "Every week on Mon, 08:15 Europe/London"
      assert dates == [~D[2027-01-11], ~D[2027-01-18], ~D[2027-01-25]]
    end

    test "after done has no dates; a blank time is 07:00" do
      assert {:ok, %{kind: :after_done, dates: [], summary: summary}} =
               Recurrence.describe("3d after", "", "Etc/UTC", ~D[2027-01-11])

      assert summary =~ "07:00"
    end

    test "says what's wrong" do
      assert {:error, _} = Recurrence.describe("whenever", "07:00", "Etc/UTC", ~D[2027-01-11])
      assert {:error, "at: " <> _} = Recurrence.describe("mon", "noon", "Etc/UTC", ~D[2027-01-11])

      assert {:error, "timezone: " <> _} =
               Recurrence.describe("mon", "07:00", "No/Where", ~D[2027-01-11])

      assert {:error, _} = Recurrence.describe(nil, nil, "Etc/UTC", ~D[2027-01-11])
    end
  end
end
