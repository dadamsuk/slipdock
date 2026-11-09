defmodule Slipdock.Handbook.SeedDocsTest do
  @moduledoc """
  The Principles and Playbook seed (#2041), read as text: every rule item in
  either seed parses with no problems, and the Playbook's Card shape is the
  agent guide's, bullet for bullet, so a board that hasn't edited it plans
  exactly as the guide says.
  """
  # The guide reads the settings, so this needs the database.
  use Slipdock.DataCase, async: true

  alias Slipdock.Handbook
  alias Slipdock.Handbook.Rules
  alias Slipdock.Wiki.Page

  defp seeded(title) do
    page = Enum.find(Handbook.blueprint()["pages"], &(&1["title"] == title))

    %Page{
      code: "W-2041",
      title: title,
      body: page["body"],
      front_matter: "---\n" <> page["front_matter"] <> "\n---\n"
    }
  end

  defp flat(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # The bullets of a Card shape: each `- **…` item, flattened.
  defp bullets(text) do
    ~r/^\s*- (\*\*.+?)(?=^\s*- \*\*|\z)/ms
    |> Regex.scan(text)
    |> Enum.map(fn [_, item] -> flat(item) end)
  end

  test "every rule item in both seeds parses, with no problems" do
    assert {rules, []} = Rules.parse_page(seeded("Principles"))
    assert Enum.map(rules, & &1.id) == ["PRIN-1", "PRIN-2", "PRIN-3"]
    assert Enum.all?(rules, &(&1.severity == "should" and &1.check == "judgement"))

    # PRIN-3 splits what grows, as well as extending before adding (#2112).
    assert List.last(rules).text =~ "extended before a new one is written beside it; "
    assert List.last(rules).text =~ "is split in the same change, each part about one thing."

    # Every list item under Principles' `## Rules` became a rule.
    {:ok, section} = Slipdock.Wiki.Section.read(seeded("Principles").body, "Principles/Rules")
    assert length(Regex.scan(~r/^- \*\*PRIN-\d+\*\*/m, section)) == length(rules)

    assert Rules.parse_page(seeded("Playbook")) == {[], []}
  end

  test "the Playbook's Card shape is the agent guide's, bullet for bullet" do
    {:ok, epics} = SlipdockWeb.APIGuide.section("epics", [])
    [_, guide] = String.split(epics, "**Card shape.**", parts: 2)
    [guide, _] = String.split(guide, "A board's handbook can override these", parts: 2)

    {:ok, ours} = Slipdock.Wiki.Section.read(seeded("Playbook").body, "Playbook/Card shape")

    assert length(bullets(guide)) == 8
    assert bullets(ours) == bullets(guide)
  end

  test "the Playbook's Grill names a board-enabled registry skill before an installed one (#2601)" do
    {:ok, grill} = Slipdock.Wiki.Section.read(seeded("Playbook").body, "Playbook/Grill")
    [skill] = Regex.run(~r/^- \*\*Skill:\*\*.*$/m, grill)

    assert skill =~ "add `skill: <its name>` here"
    {registry, _} = :binary.match(skill, "enabled on this board from the skills registry")
    {installed, _} = :binary.match(skill, "installed where the agent runs")
    # The plan skill's order: the board's pinned entry first, then a local one.
    assert registry < installed

    # The placeholder names no skill, so the seed asks the registry for none.
    assert Slipdock.SkillRegistry.Pins.stage_lines(seeded("Playbook").body) == []
  end

  test "the manual describes the seed and the upgrade from the skeleton" do
    manual =
      Path.expand("../../../docs/manual.md", __DIR__)
      |> Slipdock.DocsText.read!()
      |> flat()

    assert manual =~ "It starts with how to write one and a baseline of three"
    assert manual =~ "**Sizing**, checked in order: a *system*"
    assert manual =~ "**One section per stage** (Grill, Spike, Decide, Principles, Spec, Cards)"
    assert manual =~ "Editing these two pages is how a board changes how it decides and plans."
    assert manual =~ "gets the seed in its place, reported as `(seed added)`"
    assert manual =~ "`(edited: left alone)`"

    # PRIN-3 as 1.6.0 words it, and the upgrade from 1.5.0's seed (#2112).
    assert manual =~ "extending what is there before adding beside it, and splitting it"
    assert manual =~ "reported as `(seed updated)`"

    # The Spike stage, and the upgrade to it (#2352).
    assert manual =~ "both take a spike after the grill when one is needed"
    assert manual =~ "Installing 1.7.0 (#2352) adds the **Spike** stage"
    assert manual =~ "`(edited: left alone; Spike stage proposed)`, and only once"

    # The upgrade from 1.7.0's seed, whose Grill named no registry skill (#2601).
    assert manual =~ "and so (#2601) does one still holding the 1.7.0 seed"
    assert manual =~ "names the skill enabled on the board from the skills registry first"
    refute manual =~ "gets the 1.7.0 one"
  end
end
