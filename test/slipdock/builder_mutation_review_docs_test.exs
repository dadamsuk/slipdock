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

  test "the slipdock-loop skill says the verifier carries the named mutants" do
    assert read("priv/skills/slipdock-loop/SKILL.md") =~
             ~r/verifier\s+carries those and breaks other lines/
  end
end
