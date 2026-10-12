defmodule SlipdockCLI.SearchRenderTest do
  @moduledoc "`slipdock search --full`: each match says where it is, down to the comment or transcript part."
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  @results %{
    "results" => [
      %{
        "kind" => "card",
        "score" => 0.6,
        "card" => %{"id" => 12, "title" => "Call with Acme", "board" => %{"name" => "Sales"}},
        "matches" => [
          %{
            "kind" => "transcript",
            "section" => "part 2",
            "text" => "Transcript of the recording “call.mp3”, part 2 of 3:\nSteve: Friday it is.",
            "url" => "/boards/3/cards/12?at=transcript-5-part-2"
          }
        ]
      }
    ]
  }

  test "--full prints each match's own link" do
    out = capture_io(fn -> Render.search_results(@results, full: true) end)
    assert out =~ "/boards/3/cards/12?at=transcript-5-part-2"
  end

  test "the short form leaves links out" do
    out = capture_io(fn -> Render.search_results(@results, []) end)
    refute out =~ "?at="
  end
end
