defmodule Slipdock.MergedElsewhereDocsTest do
  @moduledoc """
  A merge job that finds the pull request already merged records a merge, not
  a failure, and isn't a rejection (#2637). Every doc and skill that says a
  failed merge sends a card back rejected, or counts as a rejection, says the
  exception beside it (#2647): the audit found the Quality manual page and the
  slipdock-loop skill still saying every failed merge did.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # A sentence that makes a failed merge a rejection, and the text after it
  # where the exception belongs.
  @rule ~r/(?:failed merge|merge that fails|merge fails).{0,120}?(?:reject|counting as one|counts as one)/is
  @window 300

  defp files do
    ["README.md", "lib/slipdock/quality.ex", "lib/slipdock_web/api_guide.ex"] ++
      Path.wildcard(Path.join(@root, "lib/slipdock_web/live/help_live/*.ex")) ++
      Path.wildcard(Path.join(@root, "docs/**/*.md")) ++
      Path.wildcard(Path.join(@root, "priv/skills/**/*.md"))
  end

  defp relative(path), do: Path.relative_to(Path.expand(path, @root), @root)

  defp hits do
    for file <- Enum.map(files(), &relative/1),
        text = File.read!(Path.join(@root, file)),
        [{start, length}] <- Regex.scan(@rule, text, return: :index) do
      passage = binary_part(text, start, min(length + @window, byte_size(text) - start))
      {file, String.replace(passage, ~r/\s+/, " ")}
    end
  end

  test "each failed-merge-is-a-rejection sentence names the already-merged exception" do
    missing =
      for {file, passage} <- hits(), not (passage =~ ~r/already merged/i), do: {file, passage}

    assert missing == [],
           "a failed merge said to be a rejection, with no already-merged exception: " <>
             inspect(missing)
  end

  test "the sweep reads the two places the audit found, and the others" do
    files = hits() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    for file <- [
          "docs/manual/visualise-flow-velocity-runners-and-delivery.md",
          "priv/skills/slipdock-loop/SKILL.md",
          "priv/skills/slipdock-work/SKILL.md",
          "lib/slipdock/quality.ex",
          "docs/agents.md",
          "docs/manual/verified-work.md"
        ],
        do: assert(file in files, file)
  end

  test "the rule catches a sentence without the exception" do
    text = "A merge that fails sends the card back rejected, the merge's reason as the rejection."
    assert text =~ @rule
    refute text =~ ~r/already merged/i
  end
end
