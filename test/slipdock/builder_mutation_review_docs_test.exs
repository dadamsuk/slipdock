defmodule Slipdock.BuilderMutationReviewDocsTest do
  @moduledoc """
  The builder runs the mutation review before submitting (#2635): the
  packaged builder skills, `docs/agents.md` and `HelpLive.Flow` each tell a
  builder to break its own changed lines before `slipdock done` and to name
  the mutants in the evidence, with an example line that parses as a
  verifier's part, so the verifier can carry them. A repo check: it reads
  `priv/skills/` and `docs/`.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Verified.Checks

  @root Path.expand("../..", __DIR__)

  @sources [
    "priv/skills/slipdock-loop/SKILL.md",
    "priv/skills/slipdock/SKILL.md",
    "docs/agents.md",
    "lib/slipdock_web/live/help_live/flow.ex"
  ]

  defp read(path), do: @root |> Path.join(path) |> File.read!() |> unwrap()

  # Hard-wrapped prose and comment-column text read as one line, and the
  # help page's entities as the characters they stand for.
  defp unwrap(text) do
    text
    |> String.replace(~r/\n\s*#?\s*/, " ")
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
  end

  for path <- @sources do
    test "#{path} tells a builder to run the mutation review before submitting" do
      text = read(unquote(path))

      assert text =~ ~r/mutation review before submitting/i,
             "#{unquote(path)} doesn't say the builder runs the mutation review before submitting"

      assert text =~ ~r/name[sd]? (the|each|its) mutants?.{0,40}evidence/i,
             "#{unquote(path)} doesn't tell the builder to name its mutants in the evidence"

      assert [example | _] =
               Regex.scan(~r/mutant:killed=[^`"<\s]+:[^`"<(]+?(?=[`"<(]| \(|$)/, text)
               |> List.flatten(),
             "#{unquote(path)} gives no `mutant:killed=<file>:<line>:<mutation>` example"

      assert {:ok, %{"mutants" => [%{"result" => "killed"}]}} =
               Checks.parse([String.trim(example)]),
             "#{unquote(path)}'s example #{inspect(example)} doesn't parse as a verifier's part"
    end
  end

  test "the slipdock-loop skill says the named mutants are a map (#2696)" do
    skill = read("priv/skills/slipdock-loop/SKILL.md")
    assert skill =~ "reads them as a map, not a verdict"

    assert skill =~
             "carries a killed one only when it broke it again or a test you name plainly covers that line"

    assert skill =~ "breaks every guard or branch your diff adds"
    refute skill =~ ~r/verifier\s+carries those and breaks other lines/
  end

  test "the slipdock skill says the named mutants are a map (#2696)" do
    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ "(a map, not a verdict: the verifier carries a killed one only when re-run"
    assert skill =~ "breaks every guard you add)"
    refute skill =~ "breaks other lines rather than repeat them"
  end

  test "docs/agents.md says the same, and that every claim is checked (#2696)" do
    agents = read("docs/agents.md")
    assert agents =~ "lists them as a map, not a verdict"
    assert agents =~ "every guard or branch the diff adds"
    assert agents =~ "The verifier checks every claim in your evidence"
    refute agents =~ "it carries the killed ones"
  end
end
