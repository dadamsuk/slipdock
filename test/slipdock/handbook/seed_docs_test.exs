defmodule Slipdock.Handbook.SeedDocsTest do
  @moduledoc """
  The Principles and Playbook seed (#2041), read as text: every rule item in
  either seed parses with no problems, and the Playbook's Card shape is the
  agent guide's, bullet for bullet, so a board that hasn't edited it plans
  exactly as the guide says.
  """
  # The guide reads the settings, so this needs the database.
  use Slipdock.DataCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

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
    assert_states(List.last(rules).text, "extended before a new one is written beside it; ")

    assert_states(
      List.last(rules).text,
      "is split in the same change, each part about one thing."
    )

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

  test "the Playbook's Grill asks in numbered rounds and keeps the stop rule (#2065)" do
    {:ok, grill} = Slipdock.Wiki.Section.read(seeded("Playbook").body, "Playbook/Grill")
    [asks] = Regex.run(~r/^- \*\*Asks:\*\*.*$/m, grill)

    assert asks =~ "in numbered rounds."
    refute asks =~ "one question at a time"
    # A round is the frontier, and each question comes with an answer to accept.
    assert_states(asks, "A round is every question whose prerequisites are settled")
    assert_states(asks, "each with a recommended answer that a yes accepts")
    # Unattended, a round is one wait, not one per question.
    assert_states(asks, "With nobody there, a round goes into one wait, a question each.")
    # The stop rule, which keeps a feature's grill in proportion.
    assert_states(asks, "It stops when the next answer wouldn't change the plan")
    assert_states(asks, "what is built, for whom, what done looks like and what is out of scope")
    assert_states(asks, "It doesn't ask what the board already answers")

    # The four parts every stage has are all still there, once each.
    for part <- ["Asks", "Skill", "Produces", "Writes to"] do
      assert [_] = Regex.scan(~r/^- \*\*#{part}:\*\*/m, grill), part
    end

    # The Skill line's example is a front-matter name, with no collection prefix,
    # and still names no skill for the registry to look up.
    [skill] = Regex.run(~r/^- \*\*Skill:\*\*.*$/m, grill)
    assert_states(skill, "the name in its front matter (`grilling`, with no collection's prefix)")
    refute skill =~ ~r/[\w-]+:grilling/
    refute skill =~ "mattpocock"
  end

  test "the Playbook's Grill, unattended, assumes what the board answers and waits for the person's (#3050)" do
    {:ok, grill} = Slipdock.Wiki.Section.read(seeded("Playbook").body, "Playbook/Grill")
    [asks] = Regex.run(~r/^- \*\*Asks:\*\*.*$/m, grill)
    [_, nobody] = String.split(asks, "With nobody there, ", parts: 2)
    [nobody, _] = String.split(nobody, " It stops when", parts: 2)

    assert nobody ==
             "it answers what the board answers (the card, the handbook, a Decision) " <>
               "and marks each such answer *(assumed)* where it writes it; " <>
               "only the person's decisions go into the one wait, as a numbered round, " <>
               "a question each with its recommended answer, and it never answers those itself."

    # The old line, every question of a round into the wait, is gone.
    refute asks =~ "a round goes into one wait, a question each."
    # The rest of the stage stands: the rounds and the stop rule.
    assert asks =~ "- **Asks:** in numbered rounds."
    assert_states(asks, "It stops when the next answer wouldn't change the plan")
  end

  test "the manual describes the seed and the upgrade from the skeleton" do
    manual =
      Path.expand("../../../docs/manual.md", __DIR__)
      |> Slipdock.DocsText.read!()
      |> flat()

    assert_states(manual, "It starts with how to write one and a baseline of three")
    assert_states(manual, "**Sizing**, checked in order: a *system*")

    assert_states(
      manual,
      "**One section per stage** (Grill, Spike, Decide, Principles, Spec, Cards)"
    )

    assert_states(
      manual,
      "Editing these two pages is how a board changes how it decides and plans."
    )

    assert_states(manual, "gets the seed in its place, reported as `(seed added)`")
    assert manual =~ "`(edited: left alone)`"

    # PRIN-3 as 1.6.0 words it, and the upgrade from 1.5.0's seed (#2112).
    assert_states(manual, "extending what is there before adding beside it, and splitting it")
    assert manual =~ "reported as `(seed updated)`"

    # The Spike stage, and the upgrade to it (#2352).
    assert_states(manual, "both take a spike after the grill when one is needed")
    assert manual =~ "Installing 1.7.0 (#2352) adds the **Spike** stage"
    assert manual =~ "`(edited: left alone; Spike stage proposed)`, and only once"

    # The upgrade from 1.7.0's seed, whose Grill named no registry skill (#2601).
    assert_states(manual, "and so (#2601) does one still holding the 1.7.0 seed")
    assert_states(manual, "names the skill enabled on the board from the skills registry first")
    refute manual =~ "gets the 1.7.0 one"

    # The upgrade to a Grill that assumes what the board answers (#3050).
    assert_states(
      manual,
      "And so (#3050, 1.9.4) does one still holding the seed as 1.9.3 left it"
    )

    assert_states(
      manual,
      "whose Grill said only that with nobody there a round goes into one wait"
    )

    assert manual =~ "like the `slipdock-plan` skill's"
    assert_states(manual, "answer what the board answers (the card, the handbook, a Decision)")
    assert manual =~ "mark each such answer *(assumed)*"
    assert_states(manual, "only the person's decisions go into the one wait, as a numbered round")
    assert manual =~ "it never answers those itself"

    # The upgrade to a Grill that asks in numbered rounds (#2065).
    assert_states(manual, "So (#2065) does one still holding the seed as it stood until then")
    assert_states(manual, "the current seed's Grill asks in numbered rounds")
    assert_states(manual, "each with a recommended answer that a yes accepts")
    assert_states(manual, "stops when the next answer wouldn't change the plan")

    assert_states(
      manual,
      "a round goes into one wait (`slipdock wait --question Q --question Q`)"
    )

    assert_states(manual, "as an entry's front matter has it (`grilling`)")
  end
end
