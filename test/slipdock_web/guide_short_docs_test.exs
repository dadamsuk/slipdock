defmodule SlipdockWeb.GuideShortDocsTest do
  @moduledoc """
  The skills, the agents doc, the README and the Agents help page send an
  agent to the short guide first (#1961): `slipdock guide`, or
  `/api/guide?section=short` without the CLI, then one section at a time.
  The whole guide is tens of thousands of words, and a loop that read it at
  the start of every pass paid for it every pass.

  A repo check (`test/repo_checks.txt`): it fails when one of those files
  fetches `/api/guide` with no `section` (`curl … /api/guide`, "Read
  …/api/guide"), or quotes a section by a name the guide doesn't have.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  alias SlipdockWeb.APIGuide

  @root Path.expand("../..", __DIR__)

  @files ~w(
    priv/skills/slipdock/SKILL.md
    priv/skills/slipdock-work/SKILL.md
    priv/skills/slipdock-loop/SKILL.md
    priv/skills/slipdock-docs/SKILL.md
    priv/skills/slipdock-wiki/SKILL.md
    docs/agents.md
    README.md
    lib/slipdock_web/live/help_live/agents.ex
  )

  defp read(path), do: File.read!(Path.join(@root, path))

  # Where a text fetches the guide without a section, or with `all`: a `curl`
  # of it, or "Read <url>/api/guide" (the paste-prompt's form, which a
  # wrapped paragraph can break after "Read"), as `{line, line number}`.
  @doc false
  def whole_guide_reads(text) do
    fetch = ~r{(curl\b[^\n]*|\bRead\s+\S*)/api/guide(?!\?section=(?!all\b))}
    lines = String.split(text, "\n")

    for [{at, _}] <- Regex.scan(fetch, text, return: :index, capture: :first) do
      n = text |> binary_part(0, at) |> String.split("\n") |> length()
      {Enum.at(lines, n - 1), n}
    end
  end

  # The section names a text quotes: `slipdock guide <name>`, `?section=<name>`
  # and `section: "<name>"`, placeholders (`<name>`) aside.
  @doc false
  def quoted_sections(text) do
    [
      ~r/slipdock guide ([a-z][a-z0-9-]*)/,
      ~r/section=([a-z][a-z0-9-]*)/,
      ~r/section: "([a-z][a-z0-9-]*)"/
    ]
    |> Enum.flat_map(&Regex.scan(&1, text, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
  end

  defp keys, do: (APIGuide.sections() |> Enum.map(&elem(&1, 0))) ++ ["short", "all"]

  describe "the checks themselves" do
    test "a curl or a Read of the plain URL is caught, a short or named section isn't" do
      bad = """
      curl -s "$B/api/guide"
      curl -s -H "$H" "$B/api/guide?section=all"
      Read https://example.com/api/guide and follow it.
      Work from my board. Read
      https://example.com/api/guide and follow it.
      """

      good = """
      curl -s -H "$H" "$B/api/guide?section=short"
      curl -s "$B/api/guide?section=wiki"
      Read https://example.com/api/guide?section=short and follow it.
      The whole guide (`/api/guide` with no section) is long.
      """

      assert bad |> whole_guide_reads() |> Enum.map(&elem(&1, 1)) == [1, 2, 3, 4]
      assert whole_guide_reads(good) == []
    end

    test "section names are read from each form" do
      text = """
      slipdock guide wiki
      curl "$B/api/guide?section=recipes"
      get_guide with section: "runners"
      slipdock guide <name>
      """

      assert quoted_sections(text) == ["wiki", "recipes", "runners"]
    end
  end

  describe "the files" do
    for path <- @files do
      test "#{path} never starts an agent on the whole guide" do
        reads = unquote(path) |> read() |> whole_guide_reads()

        assert reads == [],
               "#{unquote(path)} fetches the whole guide: " <>
                 Enum.map_join(reads, "; ", fn {line, n} -> "line #{n}: #{String.trim(line)}" end)
      end

      test "#{path} quotes only sections the guide has" do
        unknown = (unquote(path) |> read() |> quoted_sections()) -- keys()

        assert unknown == [],
               "#{unquote(path)} names sections the guide doesn't have: #{Enum.join(unknown, ", ")}"
      end
    end

    test "the skills, the prompt and the docs start from the short guide and fetch sections" do
      for path <- ~w(priv/skills/slipdock/SKILL.md priv/skills/slipdock-work/SKILL.md
                     priv/skills/slipdock-loop/SKILL.md) do
        text = read(path)
        assert text =~ "slipdock guide", path
        assert text =~ "short guide", path
        assert text =~ "when the task needs", path
      end

      assert read("priv/skills/slipdock/SKILL.md") =~ ~s("$B/api/guide?section=short")
      assert read("priv/skills/slipdock-work/SKILL.md") =~ ~s("$B/api/guide?section=short")

      for path <- ~w(docs/agents.md lib/slipdock_web/live/help_live/agents.ex) do
        text = read(path)
        assert text =~ "/api/guide?section=short and follow it, fetching a", path
        assert text =~ "?section=all", path
        assert text =~ ~r/long/, path
      end

      assert_states(
        read("README.md"),
        "`?section=short` to start, then one section at a time; the whole of it is long"
      )
    end

    test "the MCP server instructions still name get_guide as the short form" do
      plug = File.read!(Path.join(@root, "lib/slipdock_web/mcp/plug.ex"))
      assert_states(plug, "the get_guide tool (a short guide; it names the rest)")
      assert SlipdockWeb.MCP.Tools.GetGuide.description() =~ "Gives the short guide"
    end
  end
end
