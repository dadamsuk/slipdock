defmodule Slipdock.SwimlanesDateFieldTest do
  @moduledoc """
  A date custom field as a swimlane axis (#3615): its cards grouped by week
  or by month, as due dates are, the ones with no date in a lane of their
  own, and the view offering its unit.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields, Swimlanes}
  alias Slipdock.Swimlanes.Config

  setup do
    board = board_fixture(%{"name" => "Events"})
    [col | _] = board.columns
    {:ok, met} = Fields.create_field(board, %{"name" => "Met", "kind" => "date"})
    {:ok, notes} = Fields.create_field(board, %{"name" => "Notes", "kind" => "text"})

    for {title, date} <- [
          {"Monday", "2027-03-01"},
          {"Wednesday", "2027-03-03"},
          {"Next week", "2027-03-10"},
          {"Next month", "2027-04-02"},
          {"Undated", nil}
        ] do
      card = card_fixture(col, %{"title" => title})
      if date, do: {:ok, _} = Fields.set_value(card, met, date)
    end

    %{board: Boards.get_board!(board.id), met: met, notes: notes}
  end

  defp lanes(board, met, unit, empty \\ "hide") do
    config = %Config{
      Config.defaults("swimlanes")
      | rows: "f:#{met.id}",
        cols: "none",
        unit: unit,
        empty: empty
    }

    grid = Swimlanes.grid(board, config, ~D[2027-03-02])

    for row <- grid.rows,
        do:
          {row.key, row.label, row.tone,
           row.cells |> List.flatten() |> Enum.map(& &1.title) |> Enum.sort()}
  end

  test "a date field is offered as an axis, and offers the view's unit", %{board: board} = ctx do
    key = "f:#{ctx.met.id}"
    assert {key, "Met"} in Config.axes(board)
    refute {"f:#{ctx.notes.id}", "Notes"} in Config.axes(board)

    assert Config.uses_dates?(%Config{rows: key, cols: "column"}, board)
    refute Config.uses_dates?(%Config{rows: "f:#{ctx.notes.id}", cols: "column"}, board)
  end

  test "by week: one lane per week, the undated in their own", %{board: board, met: met} do
    assert [
             {"2027-03-01", _, :current, ["Monday", "Wednesday"]},
             {"2027-03-08", _, nil, ["Next week"]},
             {"2027-03-29", _, nil, ["Next month"]},
             {"none", "No met", nil, ["Undated"]}
           ] = lanes(board, met, "week")
  end

  test "with empty lanes shown, the weeks between are lanes too", %{board: board, met: met} do
    assert ["2027-03-01", "2027-03-08", "2027-03-15", "2027-03-22", "2027-03-29", "none"] =
             board |> lanes(met, "week", "show") |> Enum.map(&elem(&1, 0))
  end

  test "by month: one lane per month", %{board: board, met: met} do
    assert [
             {"2027-03-01", _, :current, ["Monday", "Next week", "Wednesday"]},
             {"2027-04-01", _, nil, ["Next month"]},
             {"none", "No met", nil, ["Undated"]}
           ] = lanes(board, met, "month")
  end

  test "dragging a card into a week's lane sets its date to that week's start, and out clears it",
       %{board: board, met: met} do
    card = board.columns |> Enum.flat_map(& &1.cards) |> Enum.find(&(&1.title == "Undated"))
    key = "f:#{met.id}"

    config = %Config{Config.defaults("swimlanes") | rows: key, unit: "week"}

    assert [{:field, id, "2027-03-08"}] =
             Swimlanes.move_ops(key, card, "none", "2027-03-08", config)

    assert id == met.id
    {:ok, card} = Fields.set_value(card, met, "2027-03-08")
    assert Fields.value(card, met) == ~D[2027-03-08]

    assert [{:field, _, nil}] = Swimlanes.move_ops(key, card, "2027-03-08", "none", config)
  end
end
