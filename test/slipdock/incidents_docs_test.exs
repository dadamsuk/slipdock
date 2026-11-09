defmodule Slipdock.IncidentsDocsTest do
  @moduledoc """
  Incidents (#1946) as the docs describe them: the manual's section (linked
  from its overview and README), the in-app help, the agents page and the API
  guide name both fields, every layer, each door and the finding.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Boards.Card

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the manual has the section, linked from the overview, with each door and the finding" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## Incidents$/m
    assert manual =~ "[Incidents](incidents.md)"

    [_, section] = String.split(manual, "\n## Incidents\n", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)

    for part <-
          ~w(caused_by missed_by --caused-by --missed-by --no-caused-by --no-missed-by update_card create_card) ++
            ["PATCH /api/cards/:id", "**Incident** line", "--source incident", "caused_by_card"],
        do: assert(section =~ part, inspect(part))

    for layer <- Card.layers(), do: assert(section =~ "`#{layer}`", layer)
  end

  test "README links the manual's section, and the in-app help names it" do
    assert read("README.md") =~ "docs/manual/incidents.md"

    help = read("lib/slipdock_web/live/help_live/guides.ex")
    assert help =~ "<strong>Incidents</strong>"
    assert help =~ "<em>Incident</em>"
  end

  test "the agents page and the API guide describe both fields and the finding" do
    for text <- [read("docs/agents.md"), SlipdockWeb.APIGuide.markdown()] do
      assert text =~ "**Incidents.**" or text =~ "**Incidents** (#1946)"

      for part <-
            ~w(caused_by missed_by --caused-by --missed-by update_card create_card) ++
              ["--source incident", "`process` finding"],
          do: assert(text =~ part, inspect(part))

      for layer <- Card.layers(), do: assert(text =~ "`#{layer}`", layer)
    end
  end
end
