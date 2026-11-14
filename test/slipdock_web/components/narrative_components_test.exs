defmodule SlipdockWeb.NarrativeComponentsTest do
  # The narrative writes its dates through SlipdockWeb.Dates (#2880).
  use Slipdock.DataCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Narrative
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.NarrativeComponents

  defp render_narrative(board, from, to) do
    config = %{Config.defaults("narrative") | from: from, to: to}
    board = Slipdock.Boards.get_board!(board.id)

    render_component(&NarrativeComponents.narrative_view/1,
      board: board,
      config: config,
      narrative: Narrative.build(board, config, ~D[2030-01-15]),
      collapsed: MapSet.new()
    )
  end

  test "the heading's range and a milestone read as day, month and year" do
    board = board_fixture(%{"name" => "Story"})

    {:ok, _} =
      Slipdock.Boards.Milestones.create_milestone(board, %{
        "name" => "Launch",
        "date" => "2030-01-01"
      })

    html = render_narrative(board, "2029-12-20", "2030-01-15")
    assert html =~ "What happened, 20 Dec 2029 – 15 Jan 2030"
    assert html =~ ~r/Launch<\/strong> passed on 1 Jan 2030/
  end

  test "a range of one day reads as that day, with its year, this year's too" do
    board = board_fixture(%{"name" => "Day"})
    assert render_narrative(board, "2030-01-15", "2030-01-15") =~ "What happened, 15 Jan 2030"

    today = Date.utc_today()
    iso = Date.to_iso8601(today)

    assert render_narrative(board, iso, iso) =~
             "What happened, #{Calendar.strftime(today, "%-d %b %Y")}"
  end
end
