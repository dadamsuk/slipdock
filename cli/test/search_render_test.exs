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
            "text" =>
              "Transcript of the recording “call.mp3”, part 2 of 3:\nSteve: Friday it is.",
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

  # The search command passes `full: o[:full]`, nil when --full isn't given (#667).
  test "full: nil renders the short form instead of crashing" do
    out = capture_io(fn -> Render.search_results(@results, full: nil) end)
    assert out =~ "Call with Acme"
    assert out =~ "Steve: Friday it is."
    refute out =~ "?at="
    assert out =~ "1 card"
  end

  @pages %{
    "results" =>
      for code <- ["W-1", "W-2"] do
        %{
          "kind" => "page",
          "score" => 0.7,
          "page" => %{
            "code" => code,
            "title" => "Deploy runbook #{code}",
            "summary" => nil,
            "board" => %{"name" => "Ops"}
          },
          "matches" => [
            %{"kind" => "page", "section" => "Deploy", "text" => "cd ~/server", "url" => nil},
            %{"kind" => "page", "section" => "", "text" => "docker compose up -d"}
          ]
        }
      end
  }

  # `search --kind pages` without --full printed the first page, then crashed on
  # its second match with a BadBooleanError (#799, an escript built before #667).
  test "page results with several matches render every page without --full" do
    out = capture_io(fn -> Render.search_results(@pages, full: nil) end)
    assert out =~ "W-1 Deploy runbook W-1"
    assert out =~ "W-2 Deploy runbook W-2"
    assert out =~ "Ops › wiki"
    refute out =~ "Ops › wiki ·"
    assert out =~ "[Deploy] cd ~/server"
    assert out =~ "docker compose up -d"
    assert out =~ "2 pages"
    refute out =~ "card"
  end

  test "--full on a page match with no url prints the text and no link line" do
    out = capture_io(fn -> Render.search_results(@pages, full: true) end)
    assert out =~ "docker compose up -d"
    refute out =~ "/boards/"
    assert out =~ "2 pages"
  end

  test "full: false renders the short form" do
    out = capture_io(fn -> Render.search_results(@results, full: false) end)
    refute out =~ "?at="
  end
end
