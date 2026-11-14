defmodule SlipdockWeb.MCPBriefDocsTest do
  @moduledoc """
  The brief `get_board` and `list_cards` answer (#3176) as the docs describe
  it: the API guide, docs/agents.md, the manual's MCP page, /help and the
  slipdock skill each say there is no description (`get_card` has it), that
  the done lists are trimmed unless `include_done`, and that an answer goes
  once.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the API guide, docs/agents.md and the manual describe the brief and the payload once" do
    for {where, text} <- [
          {"API guide", SlipdockWeb.APIGuide.markdown()},
          {"docs/agents.md", read("docs/agents.md")},
          {"manual", read("docs/manual/mcp-server.md")}
        ] do
      assert text =~ "include_done", where
      assert text =~ "descriptions: true", where
      assert text =~ "`get_card`", where
      assert text =~ "structuredContent", where
      refute text =~ "a summary of each card and its description", where
    end
  end

  test "the help page and the skill send a description to get_card" do
    assert read("lib/slipdock_web/live/help_live/agents/topics/mcp.html.heex") =~ "include_done"

    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ "read a card's description with `get_card`"
    assert skill =~ "include_done: true"
  end
end
