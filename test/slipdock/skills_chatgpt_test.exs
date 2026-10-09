defmodule Slipdock.Skills.ChatGPTTest do
  @moduledoc """
  The skills rewritten for ChatGPT: built from the originals, with the CLI
  mapped onto the MCP connector, and zipped the way ChatGPT's upload takes.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Skills
  alias Slipdock.Skills.ChatGPT

  @base "https://boards.example.test"

  test "offers every skill but the unattended loop" do
    names = Enum.map(ChatGPT.list(), & &1.name)
    assert names == Enum.map(Skills.list(), & &1.name) -- ["slipdock-loop"]
    assert "slipdock-wiki" in names
    refute ChatGPT.offered?("slipdock-loop")
    assert {:error, :not_found} = ChatGPT.skill_md("slipdock-loop", @base)
    assert {:error, :not_found} = ChatGPT.zip("slipdock-loop", @base)
    assert {:error, :not_found} = ChatGPT.zip("nope", @base)
    assert {:error, :not_found} = ChatGPT.zip("../priv", @base)
  end

  test "every tool the mapping names is one the MCP server has" do
    served = Enum.map(SlipdockWeb.MCP.Tools.all(), & &1.name())

    for tool <- ChatGPT.tool_names() do
      assert tool in served, "#{tool} is not an MCP tool"
    end
  end

  test "keeps the front matter first, describing the connector rather than the CLI" do
    for %{name: name} <- ChatGPT.list() do
      {:ok, md} = ChatGPT.skill_md(name, @base)
      assert md =~ ~r/\A---\nname: #{name}\ndescription: /

      [_, front, _] = String.split(md, "---\n", parts: 3)
      refute front =~ "CLI"
      refute front =~ "commands"
    end

    {:ok, md} = ChatGPT.skill_md("slipdock", @base)

    assert md =~
             "description: Read and write cards on the user's self-hosted Slipdock boards through the Slipdock connector."
  end

  test "puts the connector mapping after the front matter, then the skill unchanged" do
    {:ok, original} = Skills.read("slipdock-work")
    {:ok, md} = ChatGPT.skill_md("slipdock-work", @base)

    assert md =~ "\n---\n\n## Using this in ChatGPT\n"
    assert md =~ "#{@base}/mcp"
    assert md =~ "| `card <id>` | `get_card` |"
    assert md =~ "| `move <id> <list>` | `move_card` |"
    assert md =~ "Don't pretend a write landed"

    [_, body] = String.split(original, "\n---\n", parts: 2)
    assert String.ends_with?(md, body)
  end

  test "zips the skill as a folder with its references" do
    {:ok, bytes} = ChatGPT.zip("slipdock-wiki", @base)
    {:ok, files} = :zip.unzip(bytes, [:memory])
    files = Map.new(files, fn {path, text} -> {to_string(path), text} end)

    assert Map.keys(files) |> Enum.sort() ==
             Enum.sort(Enum.map(Skills.get("slipdock-wiki").files, &"slipdock-wiki/#{&1}"))

    assert files["slipdock-wiki/SKILL.md"] =~ "## Using this in ChatGPT"

    assert {:ok, files["slipdock-wiki/references/markup.md"]} ==
             Skills.read("slipdock-wiki", "references/markup.md")
  end
end
