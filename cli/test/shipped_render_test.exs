defmodule SlipdockCLI.ShippedRenderTest do
  @moduledoc "`slipdock card` shows where a card shipped (with the time, #2022), the deploy it says caused it (#1134), and a finished card's outcome."
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  @card %{
    "id" => 9,
    "title" => "Feature",
    "board_id" => 3,
    "blocked_by" => [],
    "blocks" => [],
    "flags" => [],
    "tags" => [],
    "assignees" => [],
    "checklist" => %{"done" => 0, "total" => 0, "items" => []},
    "comments" => [],
    "urls" => [],
    "links" => [],
    "attachments" => []
  }

  test "a line per environment, and incident_of" do
    card =
      Map.merge(@card, %{
        "shipped" => [
          %{"text" => "Shipped to production · 1a2b3c4 · 19 Oct 14:32"},
          %{"text" => "Shipped to staging · 9f8e7d6 · 18 Oct 09:05 · rolled back since"}
        ],
        "incident_of" => 41
      })

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ ~r/Shipped:\s+to production · 1a2b3c4 · 19 Oct 14:32/
    assert out =~ ~r/Shipped:\s+to staging · 9f8e7d6 · 18 Oct 09:05 · rolled back since/
    assert out =~ ~r/Incident of:\s+deploy #41/
  end

  # #2022: a finished card's outcome comes first, not "Left off"; the note
  # written before it finished is folded to one line, and one left after
  # it is what is still to do.
  test "a finished card shows its outcome, not Left off" do
    card =
      Map.merge(@card, %{
        "completed" => true,
        "outcome" => %{
          "text" => "Done 6 Nov 14:32 · accepted by runner verifier · merged PR #215 (def5678)"
        },
        "handoff" => nil,
        "last_handoff" => %{
          "next_step" => "Accepting the card will merge it",
          "via" => "runner",
          "at" => "2026-11-06T12:00:00Z",
          "before_finish" => true
        }
      })

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ ~r/Outcome:\s+Done 6 Nov 14:32 · accepted by runner verifier · merged PR #215/
    refute out =~ "Left off"
    assert out =~ ~r/Last note:\s+before it finished: Accepting the card will merge it · a runner/
  end

  test "a note left after it finished is still to do" do
    card =
      Map.merge(@card, %{
        "completed" => true,
        "outcome" => %{"text" => "Done 6 Nov 14:32"},
        "handoff" => %{
          "next_step" => "Reinstall the CLI",
          "via" => "cli",
          "at" => "2026-11-06T15:00:00Z"
        }
      })

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ ~r/Still to do:\s+Reinstall the CLI/
    refute out =~ "Left off"
    refute out =~ "Last note"
  end

  test "an open card still shows Left off" do
    card =
      Map.put(@card, "handoff", %{
        "next_step" => "Write the tests",
        "via" => "runner",
        "at" => "2026-11-06T12:00:00Z"
      })

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ ~r/Left off:\s+Write the tests/
    refute out =~ "Outcome"
  end

  test "a deploy attempt that failed (#2820)" do
    card =
      Map.put(@card, "deploy_failed", [
        %{
          "text" =>
            "Deploy failed at build · production · https://ci.example.com/runs/42 · 11 Nov 20:41"
        }
      ])

    out = capture_io(fn -> Render.card(card) end)

    assert out =~
             ~r{Deploy:\s+failed at build · production · https://ci.example.com/runs/42 · 11 Nov 20:41}
  end

  test "nothing when there is none" do
    out = capture_io(fn -> Render.card(@card) end)
    refute out =~ "Shipped"
    refute out =~ "Deploy:"
    refute out =~ "Incident of"
  end
end
