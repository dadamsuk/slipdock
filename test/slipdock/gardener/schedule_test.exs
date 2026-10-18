defmodule Slipdock.Gardener.ScheduleTest do
  @moduledoc """
  The Weekly tidy-up preset and the `garden` action (W-1807): the preset
  builds a weekly schedule rule; on its day and after its time the rule looks
  the board over and raises one alert with the count; it applies nothing,
  and says nothing when there is nothing to tidy.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Gardener}
  alias Slipdock.Automations.{Presets, Spec}

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    [_backlog, _todo, doing, _done] = board.columns
    %{owner: owner, board: board, doing: doing}
  end

  # A Monday, and the same week's Tuesday.
  @monday ~D[2030-03-04]

  defp at(date, time), do: DateTime.new!(date, time, "Etc/UTC")

  defp weekly(board, owner, params \\ %{}) do
    {:ok, attrs} = Presets.build("weekly_tidy", params, user: owner)
    {:ok, rule} = Automations.create_rule(Map.put(attrs, "board_id", board.id))
    rule
  end

  describe "the preset" do
    test "is a weekly schedule with the garden action, Monday 09:00 by default", %{owner: owner} do
      assert Date.day_of_week(@monday) == 1

      assert {:ok, %{"name" => name, "spec" => spec}} =
               Presets.build("weekly_tidy", %{}, user: owner)

      assert name == "Weekly tidy-up, Mondays at 09:00"
      assert spec["trigger"] == %{"type" => "schedule", "weekday" => 1, "at" => "09:00"}
      assert spec["actions"] == [%{"type" => "garden"}]
      assert Spec.summary(spec) =~ "look the board over for tidy-ups and raise an alert"

      assert {:ok, %{"spec" => %{"trigger" => %{"weekday" => 5, "at" => "16:30"}}}} =
               Presets.build("weekly_tidy", %{"weekday" => "5", "at" => "16:30"}, user: owner)
    end

    test "refuses a day out of range and a time that isn't one", %{owner: owner} do
      assert {:error, "Day must be 1 (Monday) to 7 (Sunday)"} =
               Presets.build("weekly_tidy", %{"weekday" => "8"}, user: owner)

      assert {:error, "At must be a time like 09:00"} =
               Presets.build("weekly_tidy", %{"at" => "9am"}, user: owner)
    end

    test "is in the gallery under Tidy" do
      assert %{group: "Tidy", title: "Weekly tidy-up"} = Presets.get("weekly_tidy")
    end
  end

  describe "the garden action" do
    test "on its day, after its time, raises one alert with the count and applies nothing", %{
      board: board,
      owner: owner,
      doing: doing
    } do
      card = card_fixture(doing, %{"title" => "Finished", "completed" => true})
      weekly(board, owner)

      assert Automations.run_scheduled(at(@monday, ~T[08:59:00])) == 0
      assert Automations.run_scheduled(at(Date.add(@monday, 1), ~T[10:00:00])) == 0
      assert Automations.run_scheduled(at(@monday, ~T[09:05:00])) == 1

      assert [alert] = Automations.list_alerts(owner)
      assert alert.title == "Slipdock: 1 tidy-up suggestion on #{board.name}"
      assert alert.body =~ "Complete but not in Done: 1"
      assert alert.body =~ "/boards/#{board.id}/tidy"
      assert alert.board_id == board.id

      # Nothing was applied: the card is where it was, the suggestion open.
      assert Boards.get_card!(card.id).column_id == doing.id
      assert [%{state: "open"}] = Gardener.list_open(board)
      assert %{trigger: "schedule"} = Gardener.last_run(board)

      # Once a day: a second tick that Monday does nothing more.
      assert Automations.run_scheduled(at(@monday, ~T[17:00:00])) == 0
    end

    test "nothing to tidy raises nothing", %{board: board, owner: owner} do
      weekly(board, owner)
      assert Automations.run_scheduled(at(@monday, ~T[09:30:00])) == 1
      assert Automations.list_alerts(owner) == []
      assert %{counts: %{"total" => 0}} = Gardener.last_run(board)
    end

    test "severity is passed on, and the count reads in the plural", %{
      board: board,
      owner: owner,
      doing: doing
    } do
      card_fixture(doing, %{"completed" => true})
      card_fixture(doing, %{"completed" => true})

      rule_fixture(board, %{
        "trigger" => %{"type" => "schedule", "at" => "09:00"},
        "actions" => [%{"type" => "garden", "severity" => "warning"}]
      })

      assert Automations.run_scheduled(at(@monday, ~T[09:30:00])) == 1
      assert [%{severity: "warning", title: title}] = Automations.list_alerts(owner)
      assert title == "Slipdock: 2 tidy-up suggestions on #{board.name}"
    end
  end
end
