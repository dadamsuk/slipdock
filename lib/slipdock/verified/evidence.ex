defmodule Slipdock.Verified.Evidence do
  @moduledoc """
  A card's evidence: the fields it is made of, whether a card carries any,
  whether it says the card changes no code, and the evidence as Markdown.
  """

  alias Slipdock.Boards.Card
  alias Slipdock.Verified.Util

  @doc """
  Whether `card`'s evidence says it changes no code (#1938): it gives a
  reason in `evidence_no_code` and names no pull request. A sweep, a
  handbook reconcile or any read-and-file card has no branch and no pull
  request, so on a board that ships by pull request it completes without
  one, and accepting it merges nothing.
  """
  def no_code?(%Card{} = card),
    do: not Util.blank?(card.evidence_no_code) and Util.blank?(card.evidence_pr)

  @doc "Whether `evidence` is a bare `-` once trimmed (#2091)."
  def dash?(evidence) when is_binary(evidence), do: String.trim(evidence) == "-"
  def dash?(_evidence), do: false

  # The fields evidence is made of (#1632, #1623): any one of them is some.
  @evidence_fields ~w(evidence evidence_commit evidence_branch evidence_tests evidence_suite evidence_pr evidence_no_code)a

  @doc "Whether `card` carries any evidence (or would, with `attrs`)."
  def evidence?(card, attrs \\ %{}) do
    Enum.any?(@evidence_fields, fn key ->
      Util.present?(Util.given(attrs, key, Map.get(card, key)))
    end)
  end

  @doc false
  def no_evidence, do: Map.new(@evidence_fields, &{to_string(&1), nil})

  @doc """
  A card's evidence as Markdown (#1632, #1623): what was checked, then the
  commit and branch, the suite's result and the test files.
  """
  def evidence_text(%Card{} = card) do
    suite = card.evidence_suite

    [
      "**Evidence.**",
      card.evidence,
      card.evidence_commit &&
        "Commit: `#{card.evidence_commit}`" <>
          if(card.evidence_branch, do: " on `#{card.evidence_branch}`", else: ""),
      is_nil(card.evidence_commit) && card.evidence_branch && "Branch: `#{card.evidence_branch}`",
      labelled("Pull request", card.evidence_pr),
      labelled("No code", card.evidence_no_code),
      suite && "Suite: #{suite_text(suite)}",
      not Enum.member?([nil, []], card.evidence_tests) &&
        "Tests:\n" <> Enum.map_join(card.evidence_tests, "\n", &"- `#{&1}`")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("\n\n")
  end

  defp labelled(_label, nil), do: nil
  defp labelled(label, text), do: "#{label}: #{text}"

  @doc "A suite's result in words: `passed (38 passed, 0 failed)`."
  def suite_text(%{} = suite) do
    counts =
      [{suite["passed"], "passed"}, {suite["failed"], "failed"}]
      |> Enum.reject(fn {n, _} -> is_nil(n) end)
      |> Enum.map_join(", ", fn {n, what} -> "#{n} #{what}" end)

    if counts == "", do: suite["result"], else: "#{suite["result"]} (#{counts})"
  end
end
