defmodule SlipdockWeb.NowCliDocsTest do
  @moduledoc """
  Right now's CLI door (#2110), named everywhere a person or an agent looks
  for it: the CLI's help, the slipdock skill (`priv/skills`, the one
  source), the manual's Right now section, docs/agents.md, the README, the API
  guide and the CLI
  column of HelpLive.Agents' Right now row, which says the CLI does it all
  now rather than in part (`slipdock runners`, `slipdock jobs`).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  test "the CLI's help lists `now <board>` and what it shows" do
    help = flat(read("cli/help.txt"))
    assert help =~ "now <board> right now on the board's tree: each runner and its jobs' steps"
    assert help =~ "the cards in progress with where they sit and what holds them"
  end

  test "the slipdock skill names `slipdock now` in its commands and for the question" do
    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ ~r/^slipdock now <board> \[--json\]\s+# right now:/m

    assert flat(skill) =~
             ~s{"What are the runners doing right now?" → `slipdock now <board>` (`--json` for the JSON)}
  end

  test "the manual's Right now section gives the CLI with the API and MCP" do
    [_, section] = String.split(read("docs/manual.md"), "\n## Right now\n", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)

    assert section =~ "The same snapshot from the CLI, the API and MCP"
    assert section =~ "slipdock now <board>  "
    assert section =~ "slipdock now <board> --json    the API's JSON, as it is"
  end

  test "docs/agents.md's Right now names the CLI" do
    assert flat(read("docs/agents.md")) =~
             "`slipdock now <board>` (`--json` for the JSON), `GET /api/boards/:board/now`"
  end

  test "the README and the API guide name the CLI beside REST and MCP" do
    assert flat(read("README.md")) =~
             "`slipdock now <board>`, `GET /api/boards/:board/now` or MCP `get_board now: true`"

    assert flat(read("lib/slipdock_web/api_guide.ex")) =~
             "`slipdock now <board>` (`--json` for this JSON)"
  end

  test "HelpLive.Agents' Right now row has the CLI door, whole" do
    {_, doors} =
      Enum.find(SlipdockWeb.HelpLive.Agents.features(), fn {label, _} ->
        label =~ "See what is happening right now"
      end)

    assert {:yes, "slipdock now"} in doors
    refute Enum.any?(doors, &match?({:some, _}, &1))
  end
end
