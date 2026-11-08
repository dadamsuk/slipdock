defmodule SlipdockWeb.MCP.DocsTest do
  @moduledoc """
  The MCP server as the docs describe it: README.md, docs/manual.md and
  docs/agents.md name every tool and prompt `/mcp` offers and no tool it
  does not, and the counts they quote are the real one. A tool or prompt
  added or removed without the docs following fails here.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.MCP.{Prompts, Resources, Tools}

  @root Path.expand("../../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))
  defp names, do: Enum.map(Tools.every(), & &1.name())

  # The `## MCP server` section of the manual, up to the next `## ` heading.
  defp manual_section do
    [_, rest] = String.split(read("docs/manual.md"), "\n## MCP server\n", parts: 2)
    rest |> String.split(~r/\n## /, parts: 2) |> hd()
  end

  # The section's tools part, before its prompts.
  defp manual_tools, do: manual_section() |> String.split("\n### The prompts\n") |> hd()

  defp manual_prompts, do: manual_part("The prompts")
  defp manual_resources, do: manual_part("The resources")

  defp manual_part(heading) do
    [_, rest] = String.split(manual_section(), "\n### #{heading}\n", parts: 2)
    rest |> String.split(~r/\n### /, parts: 2) |> hd()
  end

  defp template_uris, do: Enum.map(Resources.templates(), & &1.uriTemplate)

  defp prompt_names, do: Enum.map(Prompts.every(), & &1.name())

  # The tool names in the first column of the section's table.
  defp table_tools(section) do
    Regex.scan(~r/^\| `([a-z_]+)` \|/m, section, capture: :all_but_first)
    |> List.flatten()
  end

  test "the manual's tool table has one row per tool, in the order tools/list gives them" do
    assert table_tools(manual_tools()) == names()
  end

  test "the table parser would catch a row for a tool that does not exist" do
    fake = "| Tool | What |\n|---|---|\n| `whoami` | x |\n| `teleport_card` | y |\n"
    assert table_tools(fake) == ["whoami", "teleport_card"]
    refute table_tools(fake) == names()
  end

  test "README and docs/agents.md name every tool" do
    for doc <- ["README.md", "docs/agents.md"], name <- names() do
      assert read(doc) =~ "`#{name}`", "#{doc} does not mention the MCP tool `#{name}`"
    end
  end

  test "README's MCP section names no tool that is not offered" do
    [_, section] = String.split(read("README.md"), "\n## Connecting an MCP client\n", parts: 2)
    section = section |> String.split(~r/\n## /, parts: 2) |> hd()

    mentioned =
      Regex.scan(~r/`([a-z]+_[a-z_]+|whoami|search|ask|comment|activity|share|garden)`/, section,
        capture: :all_but_first
      )
      |> List.flatten()
      |> Enum.uniq()

    assert Enum.sort(mentioned) == Enum.sort(names())
  end

  test "the tool count the README and the manual quote is the real one" do
    count = "#{length(names())} tools"
    assert read("README.md") =~ count
    assert read("docs/manual.md") =~ count
  end

  test "links to the manual's MCP section land on a heading that exists" do
    assert read("docs/manual.md") =~ ~r/^## MCP server$/m
    assert read("README.md") =~ "docs/manual.md#mcp-server"
    assert read("docs/agents.md") =~ ~r/^## Over MCP$/m
  end

  test "the manual's prompt table has one row per prompt, in the order prompts/list gives them" do
    rows =
      Regex.scan(~r/^\| `([a-z-]+)` \|/m, manual_prompts(), capture: :all_but_first)
      |> List.flatten()

    assert rows == prompt_names()
  end

  test "README, docs/agents.md, the guide and /help/agents name every prompt" do
    help = File.read!(Path.join(@root, "lib/slipdock_web/live/help_live/agents.ex"))
    guide = File.read!(Path.join(@root, "lib/slipdock_web/api_guide.ex"))

    for {doc, text} <- [
          {"README.md", read("README.md")},
          {"docs/agents.md", read("docs/agents.md")},
          {"the guide", guide},
          {"/help/agents", help}
        ],
        name <- prompt_names() do
      assert text =~ "`#{name}`" or text =~ "<code>#{name}</code>",
             "#{doc} does not mention the MCP prompt `#{name}`"
    end
  end

  test "the prompt count the README quotes is the real one" do
    assert read("README.md") =~ "#{length(prompt_names())} prompts"
  end

  test "links to the manual's prompts land on a heading that exists" do
    assert read("docs/manual.md") =~ ~r/^### The prompts$/m
    assert read("docs/agents.md") =~ "manual.md#the-prompts"
  end

  test "the manual's resource table has one row per template, in the order templates/list gives them" do
    rows =
      Regex.scan(~r/^\| `(slipdock:\/\/[^`]+)` \|/m, manual_resources(), capture: :all_but_first)
      |> List.flatten()

    assert rows == template_uris()
  end

  test "README and docs/agents.md name every resource template" do
    for {doc, text} <- [
          {"README.md", read("README.md")},
          {"docs/agents.md", read("docs/agents.md")}
        ],
        uri <- template_uris() do
      assert text =~ "`#{uri}`", "#{doc} does not mention the MCP resource `#{uri}`"
    end
  end

  test "the guide names the resources" do
    guide = File.read!(Path.join(@root, "lib/slipdock_web/api_guide.ex"))
    assert guide =~ "slipdock://card/42"
    for kind <- ~w(board/ page/ view/ work), do: assert(guide =~ "`#{kind}`")
  end

  test "links to the manual's resources land on a heading that exists" do
    assert read("docs/manual.md") =~ ~r/^### The resources$/m
    assert read("docs/agents.md") =~ "manual.md#the-resources"
    assert read("README.md") =~ "docs/manual.md#the-resources"
  end

  describe "findings in the skills (#1784)" do
    test "the loop skill's wrap-up has a Findings block after Handbook, with its bar" do
      loop = read("priv/skills/slipdock-loop/SKILL.md")
      [_, gate] = String.split(loop, "**Then the findings**", parts: 2)

      for kind <- ~w(gotcha rule handbook-wrong tooling process),
          do: assert(gate =~ "- #{kind}:")

      assert gate =~ "*would a\n   card on a different subject want to know this?*"
      assert gate =~ "`Findings: none` is the usual answer"
      assert loop =~ ~r/- Handbook: updated W-3.*\n   - Findings:/
      assert loop =~ "and the `Findings:` block with it: the evidence is the closing comment"
      assert loop =~ "each as a finding in a `Findings:` block there"
    end

    # #1941: every comment's block is recorded, so the skills say it is
    # written once, and how a tooling item about the machine is marked.
    test "both skills say the Findings block goes in the closing comment, once" do
      for skill <- ~w(slipdock-loop slipdock-work) do
        text = read("priv/skills/#{skill}/SKILL.md") |> String.replace(~r/\s+/, " ")
        assert text =~ "in the closing comment, once", skill
        assert text =~ "on the epic", skill
        assert text =~ "tooling (runner)", skill
      end
    end

    # #1969: triage dismissed most findings as pointers, events, fixes and
    # notes on the card's own code, so the skills name those four and show
    # two of each side.
    test "the loop skill names the four things that are not findings, with examples" do
      loop = read("priv/skills/slipdock-loop/SKILL.md")
      [_, gate] = String.split(loop, "**Then the findings**", parts: 2)
      [gate, _] = String.split(gate, "2. **Commit**", parts: 2)

      for never <- [
            "- **a pointer**: `in the evidence`, `recorded on #1819`",
            "- **an event the board records itself**",
            "- **something this card fixed**",
            "- **a fact about this card's code**: `Boards.move_card/4 returns :ok`"
          ],
          do: assert(gate =~ never)

      assert gate =~ "| A finding | Not a finding |"
      rows = Regex.scan(~r/^   \| `(gotcha|tooling|process):[^|]*\| `[^|]*\|$/m, gate)
      assert length(rows) == 2
      refute gate =~ "is a normal answer"
    end

    test "the work and docs skills, the guide, docs/agents.md and the manual say the same test" do
      for path <- ~w(priv/skills/slipdock-work/SKILL.md priv/skills/slipdock-docs/SKILL.md
                     docs/agents.md lib/slipdock_web/api_guide.ex docs/manual.md) do
        text = read(path) |> String.replace(~r/\s+/, " ")
        assert text =~ "a card on a different subject want to know this?", path
        assert text =~ "Never a pointer", path
        assert text =~ "something th", path
        assert text =~ "`Findings: none` is the usual answer", path
        refute text =~ "next pass, on a different card", path
        refute text =~ "is a normal answer", path
      end

      work = read("priv/skills/slipdock-work/SKILL.md") |> String.replace(~r/\s+/, " ")
      assert work =~ "`Boards.move_card/4 returns :ok`"
      assert work =~ "`gotcha: mix format can need two passes`"
    end

    test "everywhere the block is taught, a fix is a card, not a finding (#2121)" do
      for path <- ~w(priv/skills/slipdock-loop/SKILL.md priv/skills/slipdock-work/SKILL.md
                     priv/skills/slipdock-docs/SKILL.md docs/agents.md docs/manual.md
                     lib/slipdock_web/api_guide.ex lib/slipdock_web/live/help_live/flow.ex) do
        text = read(path) |> String.replace(~r/\s+/, " ")

        assert text =~ "a fix is a card, not a finding" or
                 text =~ "A fix is a card, not a finding",
               path

        assert text =~ "→ #", path
        assert text =~ "cuts across cards", path
      end

      # With examples of each, where a pass reads it at length.
      for path <- ~w(priv/skills/slipdock-loop/SKILL.md priv/skills/slipdock-work/SKILL.md
                     docs/agents.md docs/manual.md lib/slipdock_web/api_guide.ex) do
        text = read(path) |> String.replace(~r/\s+/, " ")
        assert text =~ "no test pins `slipdock done`'s exit codes", path
        assert text =~ "`mix format` can need two passes", path
        assert text =~ "--column Backlog" or text =~ "in the backlog", path
      end
    end

    test "the docs skill says where each kind of knowledge goes" do
      docs = read("priv/skills/slipdock-docs/SKILL.md")
      assert docs =~ "### What you learned: the handbook, a finding, or your memory"
      assert docs =~ "your own **agent memory**"
      assert docs =~ "Project facts never live only in agent memory"
      assert docs =~ "would a card on a different subject want to know this?"
    end

    test "the slipdock skill names the findings commands (#1781)" do
      skill = read("priv/skills/slipdock/SKILL.md")
      assert skill =~ "slipdock findings <board> [--status S] [--kind K] [--days N] [--card ID]"
      assert skill =~ "slipdock finding <id> promote|dismiss|reopen"
      assert skill =~ "slipdock finding <id> merge --into ID"
    end

    test "the guide and docs/agents.md describe the block and its bar" do
      guide = read("lib/slipdock_web/api_guide.ex")
      assert guide =~ "## Findings"
      assert guide =~ "would a card on a different subject want to know"
      assert read("docs/agents.md") =~ "would a card on a different subject want to know this?"
    end
  end
end
