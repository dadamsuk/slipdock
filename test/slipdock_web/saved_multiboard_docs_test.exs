defmodule SlipdockWeb.SavedMultiboardDocsTest do
  @moduledoc """
  Saved multiboards as the docs describe them (#1482): the API guide's
  recipe, the manual, README, /help/agents and the slipdock skill.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the API guide has the recipe" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "curl -s -H \"$H\" B/api/multiboards"
    assert guide =~ "B/api/multiboards/4 -d '{\"color\":\"teal\"}'"
  end

  test "the manual, README and the skill name the page and the commands" do
    manual = read("docs/manual.md")
    assert manual =~ "**Saved multiboards**: press **Save** on the Multiboard page"
    assert manual =~ "`slipdock save-multiboard <name> [--list L]..."
    assert manual =~ "`GET/PATCH/DELETE /api/multiboards/:id`"

    assert read("README.md") =~ "A view can be **saved** with a name and a colour"
    assert read("priv/skills/slipdock/SKILL.md") =~ "slipdock save-multiboard \"Ops queue\""
  end

  test "the agents page lists it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents")
    assert html =~ "Save a multiboard view by name, for the home page"
    assert html =~ "slipdock save-multiboard, multiboards"
  end
end
