defmodule SlipdockWeb.SubagentWaitDocsTest do
  @moduledoc """
  A pass's subagents finish their builds (#1812). In print mode the run ends
  when the turn does, and background tasks are stopped 10 minutes after it:
  the loop skill has a pass wait for the subagents it started and never leave
  a subcard it moved in sitting in progress with nothing working on it, and
  the manual's runner section says so, with the variable a Claude runner's
  config exports. Each subagent's brief tells it to run everything in the
  foreground too (#2974): a subagent's own background run never wakes it in a
  runner's job. The skill is read from `priv/skills/` only: that is its one
  source (#2048).
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2, assert_states: 3]

  @root Path.expand("../..", __DIR__)

  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  # Step 5 is one of the skill's references (#3004); the invariant stays in
  # `SKILL.md`, which every pass reads.
  @subcards "priv/skills/slipdock-loop/references/subcards.md"

  test "the loop skill waits for its subagents, and leaves no subcard stranded" do
    for {path, parts} <- [
          {@subcards,
           [
             "**Wait for every subagent you started before your turn ends.**",
             "In print mode (`claude -p`, as a runner runs it) the run ends when the turn does",
             "Don't end the turn to be told they have finished: wait for them in it.",
             "each subcard is finished and closed, or handed back (`SKILL.md`, **Handing a " <>
               "card back**) with a handoff"
           ]},
          {"priv/skills/slipdock-loop/SKILL.md",
           [
             "**Never end a pass with a subcard you moved in left in progress with nothing " <>
               "working on it.**",
             "then finish each subcard or hand it back with a handoff",
             "Read `references/subcards.md` before starting one."
           ]}
        ],
        loop = path |> read() |> flat(),
        part <- parts,
        do: assert_states(loop, part, "#{path}: #{part}")
  end

  test "the wait comes before the parent closes, in the subcards section" do
    loop = read(@subcards) <> "\n## "
    [_, section] = String.split(loop, "## 5. Subcards before the parent", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    assert_states(section, "Wait for every\nsubagent you started")
  end

  test "each subagent's brief says to run everything in the foreground (#2974)" do
    loop = read(@subcards) <> "\n## "
    [_, section] = String.split(loop, "## 5. Subcards before the parent", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    section = flat(section)

    for part <- [
          "**every subagent's brief tells it to run everything in the foreground**",
          "its tests, `mix pre_push` or the project's checks, and its CI watch",
          "A subagent that starts a background run and ends its turn to wait for it " <>
            "never wakes in a runner's job"
        ],
        do: assert_states(section, part, part)

    # Each part that carries the meaning is a fact here (a short quotation),
    # so a claim can't pass on the rest of its key words: turning "foreground"
    # into "background", dropping "never" or the CI watch fails (#2974).
    for part <- [
          ~s{the brief says "run everything" "in the foreground"},
          ~s{"in the foreground": its tests, its pre-push checks and "its CI watch"},
          ~s{a subagent's "background run" "never wakes" in a runner's job}
        ],
        do: assert_states(section, part, part)

    refute section =~ "in the background", "§5 must not tell a subagent to run in the background"
  end

  test "the manual's runner section says why, and what a Claude runner exports" do
    manual = read("docs/manual.md")
    [_, runners] = String.split(manual, ~r/^## Runners$/m, parts: 2)
    [runners | _] = String.split(runners, ~r/^## /m, parts: 2)
    runners = flat(runners)

    for part <- [
          "**Subagents finish their builds.**",
          "stops a run's background tasks 10 minutes after its last turn",
          "the daemon runs a Claude job with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`",
          "has a pass wait for every subagent it started before its turn ends",
          "never end with a subcard it moved in left in progress with nothing working on it",
          "it finishes the subcard or hands it back with a handoff"
        ],
        do: assert_states(runners, part, part)
  end
end
