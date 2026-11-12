defmodule Slipdock.MergedElsewhereDocsTest do
  @moduledoc """
  A merge job that finds the pull request already merged records a merge, not
  a failure, and isn't a rejection (#2637). Every doc and skill that says a
  failed merge sends a card back rejected, or counts as a rejection, says the
  exception beside it (#2647): the audit found the Quality manual page and the
  slipdock-loop skill still saying every failed merge did. The health
  monitor's `merge_failing` row and the MergeFailing moduledoc, which said a
  card whose merge fails is back as rejected each time, say it too (#2662):
  the sweep reads the health detectors' moduledocs and their phrasings. An
  already-merged merge job still ends failed, but it isn't counted as a
  failing merge, and `merge_missing` flags the card once rather than queuing
  the merge again (#2759): the rows and moduledocs say so (the detectors'
  behaviour is tested in `health/finishing_detectors_test.exs` and
  `health/already_merged_test.exs`).
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)

  # A sentence that makes a failed merge a rejection, and the text after it
  # where the exception belongs.
  @rule ~r/(?:(?:failed merge|merge that fails|merge fails).{0,120}?(?:reject|counting as one|counts as one)|back\s+as\s+rejected\s+each\s+time|looping\s+between\s+accepted\s+and\s+rejected)/is
  @window 300

  defp files do
    ["README.md", "lib/slipdock/quality.ex", "lib/slipdock_web/api_guide.ex"] ++
      Path.wildcard(Path.join(@root, "lib/slipdock_web/live/help_live/*.ex")) ++
      Path.wildcard(Path.join(@root, "docs/**/*.md")) ++
      Path.wildcard(Path.join(@root, "priv/skills/**/*.md"))
  end

  defp relative(path), do: Path.relative_to(Path.expand(path, @root), @root)

  # The health detectors' moduledocs: their summaries are runtime text, tested
  # with the detectors, so only the moduledoc is swept.
  defp detector_docs do
    for path <- Path.wildcard(Path.join(@root, "lib/slipdock/health/detectors/*.ex")),
        [doc] <-
          Regex.scan(~r/@moduledoc """(.*?)"""/s, File.read!(path), capture: :all_but_first) do
      {relative(path), doc}
    end
  end

  defp texts do
    Enum.map(files(), &{relative(&1), File.read!(Path.join(@root, relative(&1)))}) ++
      detector_docs()
  end

  defp hits do
    for {file, text} <- texts(),
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
          "docs/manual/verified-work.md",
          "docs/manual/the-health-monitor.md",
          "lib/slipdock/health/detectors/merge_failing.ex"
        ],
        do: assert(file in files, file)
  end

  test "the rule catches a sentence without the exception" do
    text = "A merge that fails sends the card back rejected, the merge's reason as the rejection."
    assert text =~ @rule
    refute text =~ ~r/already merged/i
  end

  test "the rule catches the health monitor's phrasings" do
    for text <- [
          "It is back as rejected each time; the flag says it is looping.",
          "it is looping between accepted and rejected"
        ],
        do: assert(text =~ @rule, text)
  end

  test "the merge_failing row and the MergeFailing moduledoc say an already-merged merge isn't a rejection" do
    row =
      File.read!(Path.join(@root, "docs/manual/the-health-monitor.md"))
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "| `merge_failing` |"))

    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
      Code.fetch_docs(Slipdock.Health.Detectors.MergeFailing)

    for text <- [row, String.replace(moduledoc, ~r/\s+/, " ")] do
      assert_states(text, "finds the pull request already merged isn't a rejection")
      assert_states(text, "at another head the card stays merging")

      assert_states(
        text,
        "That job ends failed but isn't counted here as a failing merge: " <>
          "`merge_missing` flags the card once, for a person, rather than queuing the " <>
          "merge again"
      )

      # What it said before #2759, when the merge was queued again and counted.
      refute text =~ "queues the merge again and a repeat is flagged here too"
      refute text =~ "count towards"
    end
  end

  test "the merge_missing row and moduledoc say an already-merged card is flagged, not requeued" do
    row =
      File.read!(Path.join(@root, "docs/manual/the-health-monitor.md"))
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "| `merge_missing` |"))

    assert_states(
      row,
      "Not when its last merge job found the pull request already merged at a head it " <>
        "couldn't match to the accepted commit"
    )

    assert_states(row, "the card is flagged at once, after that one failure")

    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
      Code.fetch_docs(Slipdock.Health.Detectors.MergeMissing)

    moduledoc = String.replace(moduledoc, ~r/\s+/, " ")
    assert_states(moduledoc, "queuing it again would fail the same way, so it is flagged at once")
  end
end
