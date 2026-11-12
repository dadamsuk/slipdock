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

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)

  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  test "the CLI's help lists `now <board>` and what it shows" do
    help = flat(read("cli/help.txt"))

    assert_states(
      help,
      "now <board> right now on the board's tree: each runner at work and its jobs' steps"
    )

    assert_states(help, "the cards in progress with where they sit and what holds them")
    # The idle runners come last, as on the page (#2113).
    assert help =~ "and the idle runners last"
  end

  test "the slipdock skill names `slipdock now` in its commands and for the question" do
    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ ~r/^slipdock now <board> \[--json\]\s+# right now:/m

    assert_states(
      flat(skill),
      ~s{"What are the runners doing right now?" → `slipdock now <board>` (`--json` for the JSON)}
    )
  end

  test "the manual's Right now section gives the CLI with the API and MCP" do
    [_, section] = String.split(read("docs/manual.md"), "\n## Right now\n", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)

    assert_states(section, "The same snapshot from the CLI, the API and MCP")
    assert section =~ "slipdock now <board>  "
    assert_states(section, "slipdock now <board> --json    the API's JSON, as it is")
  end

  test "docs/agents.md's Right now names the CLI" do
    assert flat(read("docs/agents.md")) =~
             "`slipdock now <board>` (`--json` for the JSON), `GET /api/boards/:board/now`"
  end

  test "the feature digest and the API guide name the CLI beside REST and MCP" do
    assert flat(read("docs/manual/every-feature-in-brief.md")) =~
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
