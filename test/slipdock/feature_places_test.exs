defmodule Slipdock.FeaturePlacesTest do
  @moduledoc """
  The places a feature shows up are listed once, in `CONTRIBUTING.md`
  §Where a feature shows up, and `CLAUDE.md` rule 2 points there (#3346).
  Two copies had drifted: `CONTRIBUTING.md` spoke of "three faces" (UI, API,
  CLI) while `CLAUDE.md` listed about ten places. This holds the list to one
  file.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read(file), do: File.read!(Path.join(@root, file))

  # A path only the list names: a second copy of the list would name it too.
  @list_only [
    "lib/slipdock_web/mcp/tools/",
    "api_guide_golden_test.exs",
    "every-feature-in-brief.md"
  ]

  test "CONTRIBUTING.md holds the list, with every place's path" do
    text = read("CONTRIBUTING.md")
    assert text =~ "## Where a feature shows up"

    for path <- @list_only ++ ["docs/agents.md", "priv/skills/", "HelpLive", "cli/"],
        do: assert(text =~ path, "the list in CONTRIBUTING.md lacks #{path}")

    refute text =~ "three faces"
  end

  test "CLAUDE.md links to the list rather than restating it" do
    text = read("CLAUDE.md")
    assert String.replace(text, ~r/\s+/, " ") =~ "`CONTRIBUTING.md` §Where a feature shows up"

    for path <- @list_only,
        do: refute(text =~ path, "CLAUDE.md restates the list (#{path}): link to it instead")
  end
end
