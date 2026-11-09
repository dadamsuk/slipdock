defmodule Slipdock.HandbookPageListsTest do
  @moduledoc """
  Every written-out list of the handbook's section pages names every page
  `Slipdock.Handbook.sections/0` has (#2045, SPEC-10). The lists in code
  (the API guide, `HelpLive.Agents`) are built from it; these are the ones
  written by hand, each for a reader of its own, so each keeps its wording.

  A copy is found by a phrase that starts its list, and read from there to
  the end of its paragraph (a blank line, or the next item of a Markdown
  list, indented or not). A page counts as named by its title ("UX & UI") or by the name
  running prose gives it ("UX"). A section added to the Tool fails here
  once for each copy that doesn't name it yet, with the file and the title.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Slipdock.Handbook

  @root Path.expand("../..", __DIR__)

  # {where, the phrase that starts its list}
  defp copies do
    [
      {"README.md", "- **The handbook.** One Tool is built in"},
      {"docs/manual.md", "skeleton pages for"},
      {"docs/agents.md", "section page (Specification"},
      {"priv/skills/slipdock-docs/SKILL.md", "in the section page that covers it"},
      {"the Slipdock.Handbook moduledoc", "wiki pages that describe the"},
      {"the seed card's procedure", "For each section page ("}
    ]
  end

  test "every copy of the page list names every section page" do
    missing = missing(Handbook.sections())
    assert missing == [], describe(missing)
  end

  test "a section added to the Tool fails once for every copy, naming file and title" do
    glossary = %{title: "Glossary", key: "glossary", name: "glossary"}
    missing = missing(Handbook.sections() ++ [glossary])

    assert missing == for({where, _} <- copies(), do: {where, "Glossary"})
    assert describe(missing) =~ ~s|docs/manual.md doesn't name "Glossary"|
    assert describe(missing) =~ ~s|the Slipdock.Handbook moduledoc doesn't name "Glossary"|
  end

  test "the seed card's procedure fails, naming the page, when one is left out of it" do
    seed = seed_description()
    [list] = Regex.run(~r/For each section page \(.*\):/, seed)
    assert names_in(seed, "For each section page (") =~ list

    for section <- Handbook.sections() do
      without =
        String.replace(list, ~r/(?<!\w)#{Regex.escape(section.title)}(?!\w)/, "", global: false)

      refute named?(names_in(without, "For each section page ("), section), section.title
    end
  end

  test "a list stops at the next item, indented or not" do
    text = "pages for Components:\n   - Data model, below\nmore"
    assert names_in(text, "pages for") == "pages for Components:"
  end

  test "a copy whose list has gone fails on its phrase, not silently" do
    assert names_in("no list here", "skeleton pages for") == :no_list
  end

  test "a page is named by its title or its prose name, as a whole word" do
    list = names_in("pages for the UX, data model and Shared modules.", "pages for")

    assert named?(list, %{title: "UX & UI", name: "UX"})
    assert named?(list, %{title: "Data model", name: "data model"})
    assert named?(list, %{title: "Shared modules", name: "shared modules"})
    refute named?(list, %{title: "Components", name: "components"})

    refute named?(names_in("pages for the playbooks", "pages for"), %{
             title: "Playbook",
             name: "playbook"
           })
  end

  test "the guide's handbook section lists the Tool's pages, by title, in order" do
    titles = Enum.map_join(Handbook.sections(), ", ", & &1.title)
    guide = SlipdockWeb.APIGuide.markdown() |> String.replace(~r/\s+/, " ")

    assert guide =~ "describing the project as it is now (#{titles}), one page per decision"
    assert titles =~ "Specification, Architecture, UX & UI,"
    assert titles =~ "Operations, Principles, Playbook"
  end

  test "the help's handbook part lists the Tool's pages by name, notes kept", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
    text = html |> Floki.parse_document!() |> Floki.text() |> String.replace(~r/\s+/, " ")

    [_, list] = String.split(text, "folder: pages for ", parts: 2)
    [list | _] = String.split(list, ", one page per decision")

    assert list ==
             "the specification, architecture, UX, components, data model, shared modules, " <>
               "testing, operations, principles (the tie-breakers, each a PRIN rule) and " <>
               "the playbook (how an idea becomes cards on the board)"

    for %{name: name} <- Handbook.sections(), do: assert(list =~ name)
    assert html =~ "each a <code>PRIN</code> rule"
  end

  # Every {copy, title} not named, in the order of copies/0 and the sections.
  defp missing(sections) do
    for {where, phrase} <- copies(),
        list <- [names_in(text(where), phrase)],
        section <- sections,
        list == :no_list or not named?(list, section),
        uniq: true do
      {where, if(list == :no_list, do: "(no list after #{inspect(phrase)})", else: section.title)}
    end
  end

  defp describe(missing) do
    Enum.map_join(missing, "\n", fn {where, title} ->
      "#{where} doesn't name #{inspect(title)}"
    end)
  end

  defp text("the Slipdock.Handbook moduledoc") do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Handbook)
    doc
  end

  defp text("the seed card's procedure"), do: seed_description()

  defp text(path), do: Slipdock.DocsText.read!(Path.expand(path, @root))

  # The list's paragraph, from its phrase to a blank line or the next item.
  defp names_in(text, phrase) do
    case String.split(text, phrase, parts: 2) do
      [_, rest] ->
        [first | lines] = String.split(rest, "\n")

        more = Enum.take_while(lines, &(String.trim(&1) != "" and not item?(&1)))

        Enum.join([phrase <> first | more], " ")

      [_] ->
        :no_list
    end
  end

  defp item?(line), do: line |> String.trim_leading() |> String.starts_with?("- ")

  defp seed_description do
    %{"cards" => cards} = Handbook.blueprint()
    seed_title = Handbook.seed_title()
    [description] = for %{"title" => ^seed_title} = card <- cards, do: card["description"]
    description
  end

  defp named?(list, %{title: title, name: name}) do
    Enum.any?([title, name], &(list =~ ~r/(?<!\w)#{Regex.escape(&1)}(?!\w)/))
  end
end
