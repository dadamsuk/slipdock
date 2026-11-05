defmodule SlipdockWeb.BoardViewsDocsTest do
  @moduledoc """
  The board views' polish (#1730, subcards #1731–#1735) as the manual
  describes it, and the per-view stylesheets app.css imports.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  defp section(manual, heading) do
    [_, rest] = String.split(manual, "\n## #{heading}\n", parts: 2)
    rest |> String.split("\n## ", parts: 2) |> hd()
  end

  setup_all do
    {:ok, manual: read("docs/manual.md")}
  end

  test "the table reads as text, with Assignee among the defaults", %{manual: m} do
    table = section(m, "Table")
    assert table =~ "at rest a\ncell reads as plain text"
    assert table =~ "Tab moves through the editable cells"
    assert table =~ "priority, assignee, tags, due and done to start with"
    assert table =~ "*+N*"
  end

  test "the timeline keeps titles whole and lines off them", %{manual: m} do
    timeline = section(m, "Timeline")
    assert timeline =~ "shows the whole title beside it"
    assert timeline =~ "never cross one"
    assert timeline =~ "the width is remembered in this browser"
    assert timeline =~ "directly under the last row"
  end

  test "calendar chips lead with the title", %{manual: m} do
    calendar = section(m, "Calendar")
    assert calendar =~ "Each chip starts with\nthe card's title"
    assert calendar =~ "Point at a chip for the\nfull title"
  end

  test "narrative and prioritise", %{manual: m} do
    assert section(m, "Narrative") =~ "don't repeat its title"
    assert section(m, "Narrative") =~ "by the same person are one line"
    assert section(m, "Prioritise") =~ "straight after the value"
  end

  test "every activity entry names its actor", %{manual: m} do
    activity = section(m, "Activity")
    assert activity =~ "Every entry says who\ndid it"

    for actor <- ["*Automation: <rule>*", "*Email from <name>*", "*System*", "*Someone*"],
        do: assert(activity =~ actor)

    assert activity =~ "grouped by day in\nyour own timezone"
  end

  test "each view's CSS has its own file, imported from app.css" do
    app = read("assets/css/app.css")

    for view <- ~w(table timeline calendar prioritise) do
      assert app =~ ~s(@import "./views/#{view}.css";)
      assert File.exists?(Path.join(@root, "assets/css/views/#{view}.css"))
    end

    refute app =~ ".tl-bar {"
    assert read("assets/css/views/timeline.css") =~ ".tl-bar {"
  end
end
