defmodule SlipdockWeb.MCP.DocsTest do
  @moduledoc """
  The MCP server as the docs describe it: README.md, docs/manual.md and
  docs/agents.md name every tool `/mcp` offers and none it does not, and the
  counts they quote are the real one. A tool added or removed without the
  docs following fails here.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.MCP.Tools

  @root Path.expand("../../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))
  defp names, do: Enum.map(Tools.all(), & &1.name())

  # The `## MCP server` section of the manual, up to the next `## ` heading.
  defp manual_section do
    [_, rest] = String.split(read("docs/manual.md"), "\n## MCP server\n", parts: 2)
    rest |> String.split(~r/\n## /, parts: 2) |> hd()
  end

  # The tool names in the first column of the section's table.
  defp table_tools(section) do
    Regex.scan(~r/^\| `([a-z_]+)` \|/m, section, capture: :all_but_first)
    |> List.flatten()
  end

  test "the manual's tool table has one row per tool, in the order tools/list gives them" do
    assert table_tools(manual_section()) == names()
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
      Regex.scan(~r/`([a-z]+_[a-z_]+|whoami|search|comment|activity)`/, section,
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
end
