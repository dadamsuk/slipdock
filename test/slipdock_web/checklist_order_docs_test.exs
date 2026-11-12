defmodule SlipdockWeb.ChecklistOrderDocsTest do
  @moduledoc """
  Reordering a checklist (#1752) as the docs describe it: the guide's
  recipe, the page section and the endpoint list, the manual, README,
  docs/agents.md and the CLI's help.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the guide has the recipe, the page's shared routes and the endpoint" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "B/api/checklist/13/move"
    assert guide =~ "slipdock move-check 13 --before 11"
    assert guide =~ "`POST /api/checklist/:id/move`"
    assert guide =~ ~r{POST\s+/api/checklist/:item_id/move}
  end

  test "the short guide is left as it was" do
    refute SlipdockWeb.APIGuide.short() =~ "checklist/13/move"
  end

  test "the manual, the feature digest, agents page and CLI help name it" do
    manual = read("docs/manual.md")
    assert_states(manual, "drag an item by its handle to put it in a new order")
    assert manual =~ "POST   /api/checklist/:item_id/move {before}"
    assert manual =~ "slipdock move-check 13 --before 11"
    assert read("docs/manual/every-feature-in-brief.md") =~ "`slipdock move-check`"

    assert read("docs/agents.md") =~
             ~s(`POST /api/checklist/<item_id>/move {"before": <item_id>}`)

    assert read("cli/help.txt") =~ "move-check <item-id> [--before <item-id>]"
  end
end
