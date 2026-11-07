defmodule SlipdockCLI.ProfilesSourceTest do
  @moduledoc """
  Where a card's profile came from (#2018) on the CLI: `card` shows it
  beside the profile, and nothing extra when the card's JSON doesn't say.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  @card %{
    "id" => 12,
    "title" => "Work",
    "column" => "To Do",
    "board_id" => 3,
    "priority" => "none",
    "flags" => [],
    "tags" => [],
    "comments" => [],
    "checklist" => %{"done" => 0, "total" => 0, "items" => []}
  }

  defp card(fields), do: capture_io(fn -> Render.card(Map.merge(@card, fields)) end)

  test "an inferred profile says so" do
    out = card(%{"profile" => "feature", "profile_source" => "inferred"})
    assert out =~ ~r/Profile:\s+feature · inferred/
  end

  test "a profile somebody set says who" do
    assert card(%{"profile" => "schema", "profile_source" => "person"}) =~
             ~r/Profile:\s+schema · set by person/

    assert card(%{"profile" => "fix", "profile_source" => "agent"}) =~
             ~r/Profile:\s+fix · set by agent/
  end

  test "an unrecorded source shows the profile alone, and no profile shows nothing" do
    out = card(%{"profile" => "docs", "profile_source" => nil})
    assert out =~ ~r/Profile:\s+docs\n/
    refute card(%{"profile" => nil, "profile_source" => nil}) =~ "Profile"
  end
end
