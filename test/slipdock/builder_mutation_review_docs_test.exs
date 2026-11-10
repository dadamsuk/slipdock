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

  # #2708: `git checkout -- <file>` restores the file to HEAD, so on work not
  # yet committed it wipes the card's own edits along with the mutation.
  for path <- ["priv/skills/slipdock-loop/SKILL.md", "docs/agents.md"] do
    test "#{path} says to commit before the mutation review's restore (#2708)" do
      text = read(unquote(path))
      [_, review] = String.split(text, ~r/mutation review before submitting/i, parts: 2)
      [before_break | _] = String.split(review, ~r/break 3 to 5/i, parts: 2)

      assert before_break =~ ~r/commit the card's work first/i,
             "#{unquote(path)} doesn't say to commit the card's work before breaking lines"

      assert before_break =~ "git checkout -- <file>"
      assert before_break =~ "discards every edit the card made to that file"
    end
  end

  test "every builder restore by git checkout comes after the commit-first caution (#2708)" do
    for path <- @sources do
      text = read(path)

      case :binary.match(text, "git checkout -- <file>") do
        :nomatch ->
          :ok

        {at, _} ->
          assert binary_part(text, 0, at) =~ ~r/commit the card's work first/i,
                 "#{path} gives `git checkout -- <file>` as the restore before saying to commit first"
      end
    end
  end

  test "docs/agents.md says the same, and that every claim is checked (#2696)" do
    agents = read("docs/agents.md")
    assert agents =~ "lists them as a map, not a verdict"
    assert agents =~ "every guard or branch the diff adds"
    assert agents =~ "The verifier checks every claim in your evidence"
    refute agents =~ "it carries the killed ones"
  end
end
