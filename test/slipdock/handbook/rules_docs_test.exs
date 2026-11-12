defmodule Slipdock.Handbook.RulesDocsTest do
  @moduledoc """
  The rule format is written down where agents and people read it (#1773):
  the guide's handbook section, `docs/agents.md`, the manual and the
  slipdock-docs and slipdock-loop skills (#2048: `priv/skills/` only). The examples they
  give parse as rules, so the docs and the parser can't drift apart.
  """
  # The guide reads the settings, so this needs the database.
  use Slipdock.DataCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2, assert_states: 3]

  alias Slipdock.Handbook.Rules
  alias Slipdock.Wiki.Page

  @root Path.expand("../../..", __DIR__)

  defp copies(skill) do
    [Path.join([@root, "priv/skills", skill, "SKILL.md"])]
  end

  defp parses!(item, key) do
    page = %Page{
      code: "W-1",
      title: "T",
      body: "## Rules\n\n" <> item <> "\n",
      front_matter: "---\nhandbook: #{key}\n---\n"
    }

    assert {[rule], []} = Rules.parse_page(page), "#{inspect(item)} doesn't parse"
    rule
  end

  test "the guide's handbook section gives the format, and its examples parse" do
    {:ok, guide} = SlipdockWeb.APIGuide.section("handbook", [])

    assert_states(guide, "**Rules.** Each section page keeps its rules in a `## Rules` section")
    assert guide =~ "`SPEC ARCH UX COMP DATA MOD TEST OPS PRIN PLAY`"

    # Every built-in page's prefix, Principles and Playbook (1.5.0) included.
    for key <- Slipdock.Handbook.section_keys(),
        do: assert(guide =~ ~r/`[A-Z ]*\b#{Rules.prefix(key)}\b[A-Z ]*`/, key)

    assert guide =~ "`judgement`"
    assert_states(guide, "keep its rules as they are")

    [ux, data] =
      Regex.scan(~r/^- \*\*[A-Z]+-\d+\*\* .*$/m, guide) |> List.flatten()

    assert %{id: "UX-4", severity: "must", check: "test/app_web/design_tokens_test.exs"} =
             parses!(ux, "ux")

    assert %{id: "DATA-2", severity: "should", scope: ["priv/repo/migrations/**"]} =
             parses!(data, "data-model")
  end

  test "the guide, docs/agents.md and the manual name Principles and Playbook (#2040)" do
    {:ok, guide} = SlipdockWeb.APIGuide.section("handbook", [])
    guide = String.replace(guide, ~r/\s+/, " ")
    assert guide =~ "Testing & tooling, Operations, Principles, Playbook)"
    assert guide =~ "**Principles and Playbook** (Handbook Tool 1.5.0)"

    assert_states(
      guide,
      "Installing 1.5.0 over an older handbook adds the two pages and changes no other."
    )

    agents =
      Path.join(@root, "docs/agents.md")
      |> Slipdock.DocsText.read!()
      |> String.replace(~r/\s+/, " ")

    assert_states(agents, "**Principles** are the tie-breakers between two right ways")
    assert_states(agents, "The **Playbook** is how an idea becomes cards")

    manual =
      Path.join(@root, "docs/manual.md")
      |> Slipdock.DocsText.read!()
      |> String.replace(~r/\s+/, " ")

    assert manual =~ "**Principles and Playbook** (1.5.0)"
    assert_states(manual, "tooling, Operations, Principles and Playbook (below)")

    assert_states(
      manual,
      "Installing 1.5.0 over an older handbook adds the two pages and changes no other page"
    )
  end

  test "README and slipdock-docs, name Principles and Playbook (#2040)" do
    readme =
      Path.join(@root, "README.md") |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")

    assert_states(readme, "principles (the tie-breakers, each a `PRIN` rule) and the playbook")

    for path <- copies("slipdock-docs") do
      text = path |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")
      assert text =~ "Testing & tooling, Operations, Principles, Playbook)", path
      assert_states(text, "Principles and the Playbook are a person's call", path)
    end
  end

  test "docs/agents.md and the manual describe rules" do
    agents = Slipdock.DocsText.read!(Path.join(@root, "docs/agents.md"))
    assert agents =~ "## The handbook's rules"
    assert_states(agents, "a reviewer cites them\nby id")

    manual = Slipdock.DocsText.read!(Path.join(@root, "docs/manual.md"))
    assert_states(manual, "**Rules** live in each section page's `## Rules`")
    assert_states(manual, "gets an empty one appended, and nothing else on it changes")
  end

  test "slipdock-docs says where a rule goes" do
    for path <- copies("slipdock-docs") do
      text = Slipdock.DocsText.read!(path)
      assert_states(text, "A **rule** (something a change must or should keep to)", path)
      assert text =~ "leave its rules alone", path
    end
  end

  test "slipdock-loop keeps to the rules that cover the card" do
    for path <- copies("slipdock-loop") do
      text = Slipdock.DocsText.read!(path)
      assert_states(text, "Each section page also lists its **rules** under `## Rules`", path)
      assert text =~ "cite one by its id", path
    end
  end

  test "the skeleton's own example is a rule once it is a list item" do
    for key <- ~w(specification ux data-model operations) do
      [_, example] =
        Regex.run(~r/`(- \*\*[A-Z]+-1\*\* [^`]+)`/, Slipdock.Handbook.rules_skeleton(key))

      rule = parses!(example, key)
      assert rule.id == Rules.prefix(key) <> "-1"
    end
  end
end
