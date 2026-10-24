defmodule SlipdockWeb.HandbookSkillsTest do
  @moduledoc """
  The loop's handbook steps (#1266): `slipdock-loop` reads the suggested
  sections before building, runs the docs gate before closing and writes a
  `Handbook:` line in the format the gardener parses; `slipdock-docs` sends
  durable answers to the handbook first. The installed copies, where this
  machine has them, carry the same steps.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Handbook

  @root Path.expand("../..", __DIR__)
  @installed Path.expand("~/.claude/skills")

  defp copies(skill) do
    priv = Path.join([@root, "priv/skills", skill, "SKILL.md"])
    installed = Path.join([@installed, skill, "SKILL.md"])
    [priv | if(File.exists?(installed), do: [installed], else: [])]
  end

  @loop_steps [
    "**The handbook.** On a board that keeps one, `slipdock card`",
    "Read\nthose before building",
    "**Then the docs gate, on a handbook board**",
    "| added user-visible behaviour | Specification |",
    "| chose between alternatives (asked for, or an implementation choice) | a new page in `Handbook/Decisions` |",
    "--message \"#<card> <what changed>\"",
    "A card that names a page (\"Document\n   in: Architecture\") must update that page.",
    "On a board with no handbook, leave the line out.",
    "- Handbook: updated W-3 §Contexts, new W-41"
  ]

  test "slipdock-loop has the read step, the gate and the line, in every copy" do
    for path <- copies("slipdock-loop"), step <- @loop_steps do
      assert File.read!(path) =~ step, "#{path} lacks #{inspect(step)}"
    end
  end

  test "the handbook paragraphs are the same in every copy" do
    blocks =
      for path <- copies("slipdock-loop") do
        text = File.read!(path)
        [read] = Regex.run(~r/\*\*The handbook\.\*\*.*?carry on as below\.\n/s, text)
        [gate] = Regex.run(~r/\*\*Then the docs gate.*?leave the line out\.\n/s, text)
        {read, gate}
      end

    assert length(Enum.uniq(blocks)) == 1
  end

  test "slipdock-docs sends durable answers to the handbook first" do
    for path <- copies("slipdock-docs") do
      assert File.read!(path) =~ "**A board with a handbook**", path
      assert File.read!(path) =~ "each decision as its own page in\n`Handbook/Decisions`", path
    end
  end

  test "every Handbook: line the skill shows is one the gardener can read" do
    text = File.read!(hd(copies("slipdock-loop")))

    examples =
      ~r/^[ \t]*(?:- )?Handbook: [^\n]+$/m
      |> Regex.scan(text)
      |> List.flatten()

    assert length(examples) >= 3

    for line <- examples, do: assert(Handbook.gate_line(line), "unreadable: #{line}")

    assert Handbook.gate_line("   Handbook: no change (a test-only fix)") ==
             "no change (a test-only fix)"
  end

  test "gate_line/1 reads the line however it is dressed, and nothing else" do
    assert Handbook.gate_line("**Done.**\n\n- **Handbook:** updated W-3 §Contexts") ==
             "updated W-3 §Contexts"

    assert Handbook.gate_line("> Handbook: new W-41") == "new W-41"
    assert Handbook.gate_line("* Handbook: no change (docs only)") == "no change (docs only)"
    assert Handbook.gate_line("Handbook:") == nil
    assert Handbook.gate_line("Handbook:\nnext line") == nil
    assert Handbook.gate_line("the handbook: later") == nil
    assert Handbook.gate_line("See Handbook: W-3") == nil
    assert Handbook.gate_line(nil) == nil
  end
end
