defmodule SlipdockCLI.ShippedRenderTest do
  @moduledoc "`slipdock card` shows where a card shipped and the deploy it says caused it (#1134)."
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
          %{"text" => "Shipped to production · 1a2b3c4 · 19 Oct"},
          %{"text" => "Shipped to staging · 9f8e7d6 · 18 Oct · rolled back since"}
        ],
        "incident_of" => 41
      })

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ ~r/Shipped:\s+to production · 1a2b3c4 · 19 Oct/
    assert out =~ ~r/Shipped:\s+to staging · 9f8e7d6 · 18 Oct · rolled back since/
    assert out =~ ~r/Incident of:\s+deploy #41/
  end

  test "nothing when there is none" do
    out = capture_io(fn -> Render.card(@card) end)
    refute out =~ "Shipped"
    refute out =~ "Incident of"
  end
end
