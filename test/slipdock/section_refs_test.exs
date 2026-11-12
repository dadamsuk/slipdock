defmodule Slipdock.SectionRefsTest do
  @moduledoc """
  The contributor docs point at each other's sections as `` `FILE.md` §Section ``
  (#2793). When a section is renamed or removed, a reference to it is left
  pointing nowhere: `AGENTS.md` kept sending readers to `CLAUDE.md` §Before you
  push after that section moved to `CONTRIBUTING.md`. This holds every such
  reference in the repo's top-level docs to a heading that exists in the file
  it names.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @docs ["AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "README.md"]

  # `` `docs/agents.md` §Install the skills `` — the section runs to the first
  # `)`, `.`, `,`, `;` or `:` (a name may hold backticks, as in
  # §More about `mix pre_push`).
  @ref ~r/`([\w.\/-]+\.md)` §([^).,;:]+)/

  @doc false
  def refs(text) do
    text = String.replace(text, ~r/\s+/, " ")

    for [_, file, section] <- Regex.scan(@ref, text),
        do: {file, String.trim(section)}
  end

  # A heading's text, without its `#`s, a leading number (`3 · `) or a
  # trailing aside in brackets (`(optional)`).
  @doc false
  def headings(text) do
    for [_, heading] <- Regex.scan(~r/^#+\s+(.+?)\s*$/m, text) do
      heading
      |> String.replace(~r/^\d+\s*·\s*/u, "")
      |> String.replace(~r/\s*\([^)]*\)$/, "")
    end
  end

  # A reference may leave off a heading's subtitle after a colon:
  # §Card text is data names `## Card text is data: the threat model`.
  @doc false
  def found?(section, headings),
    do: Enum.any?(headings, &(&1 == section or String.starts_with?(&1, section <> ":")))

  describe "reading references and headings" do
    test "finds a reference wrapped over lines, and one holding backticks" do
      text =
        "see (`CONTRIBUTING.md` §More about\n`mix pre_push`). And `docs/agents.md` §Install the skills."

      assert refs(text) == [
               {"CONTRIBUTING.md", "More about `mix pre_push`"},
               {"docs/agents.md", "Install the skills"}
             ]
    end

    test "a heading matches without its number, aside or subtitle, and a missing one doesn't" do
      hs =
        headings(
          "# Title\n\n## 3 · Install the skills (optional)\n### More about `mix pre_push`\n" <>
            "## Card text is data: the threat model\n"
        )

      assert found?("Install the skills", hs)
      assert found?("Card text is data", hs)
      refute found?("Card text", hs)
      assert found?("More about `mix pre_push`", hs)
      refute found?("Before you push", hs)
      refute found?("Install the", hs)
    end
  end

  test "every `FILE.md` §Section reference in the top-level docs names a heading that exists" do
    broken =
      for doc <- @docs,
          {file, section} <- refs(File.read!(Path.join(@root, doc))),
          path = Path.join(@root, file),
          not (File.exists?(path) and found?(section, headings(File.read!(path)))),
          do: "#{doc}: `#{file}` §#{section}"

    assert broken == [],
           "these point at a section that isn't there (renamed or moved?):\n" <>
             Enum.join(broken, "\n")
  end
end
