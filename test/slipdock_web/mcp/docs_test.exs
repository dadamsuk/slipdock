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
end
