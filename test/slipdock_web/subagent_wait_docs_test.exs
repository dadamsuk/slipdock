defmodule SlipdockWeb.SubagentWaitDocsTest do
  @moduledoc """
  A pass's subagents finish their builds (#1812). In print mode the run ends
  when the turn does, and background tasks are stopped 10 minutes after it:
  the loop skill has a pass wait for the subagents it started and never leave
  a subcard it moved in sitting in progress with nothing working on it, and
  the manual's runner section says so, with the variable a Claude runner's
  config exports. The skill is read from `priv/skills/` only: that is its one
  source (#2048).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  defp copies do
    [Path.join(@root, "priv/skills/slipdock-loop/SKILL.md")]
  end

  test "the loop skill waits for its subagents, and leaves no subcard stranded" do
    for path <- copies() do
      loop = path |> File.read!() |> flat()

      for part <- [
            "**Wait for every subagent you started before your turn ends.**",
            "In print mode (`claude -p`, as a runner runs it) the run ends when the turn does",
            "Don't end the turn to be told they have finished: wait for them in it.",
            "each subcard is finished and closed, or handed back (below) with a handoff",
            "**Never end a pass with a subcard you moved in left in progress with nothing " <>
              "working on it.**",
            "then finish each subcard or hand it back with a handoff"
          ],
          do: assert(loop =~ part, "#{path}: #{part}")
    end
  end

  test "the wait comes before the parent closes, in the subcards section" do
    loop = read("priv/skills/slipdock-loop/SKILL.md")
    [_, section] = String.split(loop, "## 5. Subcards before the parent", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    assert section =~ "Wait for every\nsubagent you started"
  end

  test "the manual's runner section says why, and what a Claude runner exports" do
    manual = read("docs/manual.md")
    [_, runners] = String.split(manual, ~r/^## Runners$/m, parts: 2)
    [runners | _] = String.split(runners, ~r/^## /m, parts: 2)
    runners = flat(runners)

    for part <- [
          "**Subagents finish their builds.**",
          "stops a run's background tasks 10 minutes after its last turn",
          "exports `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` (`$env:` on Windows)",
          "Codex and custom agents don't get it",
          "has a pass wait for every subagent it started before its turn ends",
          "never end with a subcard it moved in left in progress with nothing working on it",
          "it finishes the subcard or hands it back with a handoff"
        ],
        do: assert(runners =~ part, part)
  end
end
