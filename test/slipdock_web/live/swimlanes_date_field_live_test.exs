defmodule SlipdockWeb.SwimlanesDateFieldLiveTest do
  @moduledoc """
  A date custom field on a swimlane axis, in the page (#3615): its lanes by
  the chosen unit, the unit chooser offered, and the undated cards' lane.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Fields

  test "a date field's lanes follow the unit, and the unit is offered", %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Events"}, owner: user)
    [col | _] = board.columns
    {:ok, met} = Fields.create_field(board, %{"name" => "Met", "kind" => "date"})
    march = card_fixture(col, %{"title" => "March meeting"})
    card_fixture(col, %{"title" => "Never met"})
    {:ok, _} = Fields.set_value(march, met, "2027-03-10")

    {:ok, view, _} =
      live(conn, ~p"/boards/#{board}/swimlanes?rows=f:#{met.id}&cols=none&unit=month")

    assert has_element?(view, ~s|#swim-config select[name="unit"]|)
    assert has_element?(view, "#swim-grid", "No met")
    assert has_element?(view, "#swim-grid", "March meeting")
    assert has_element?(view, "#swim-grid", "Never met")
    # The month's lane is labelled as a due date's month lane is.
    assert render(view) =~ ~r/Mar(ch)? 2027/
  end
end
