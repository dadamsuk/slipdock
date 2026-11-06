defmodule Slipdock.Findings.Lesson do
  @moduledoc """
  When two findings are the same lesson (#1941, W-2310 §Findings), with no
  model call.

  `normalise/1` is the key: lower case, backticks gone, whitespace collapsed,
  trailing punctuation dropped, and every `#id` and commit sha read as one
  token, so "fixed in #12" and "Fixed in `#34`." are the same lesson. Across
  cards only that key matches (`same?/2`). On one card a restatement in other
  words counts too (`near?/2`): the same key, or at least
  #{trunc(0.6 * 100)}% of the normalised words in common.
  """

  @overlap 0.6

  @doc "The lesson's key: the text normalised."
  def normalise(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace("`", "")
    |> String.replace(~r/#\d+\b/u, "#n")
    # A sha is 7 to 40 hex digits with at least one digit in it, so "defaced"
    # stays a word.
    |> String.replace(~r/\b(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b/u, "<sha>")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.replace(~r/[\s.,;:!?…]+$/u, "")
  end

  def normalise(_), do: ""

  @doc "The same lesson in the same words, give or take the noise `normalise/1` drops."
  def same?(a, b), do: normalise(a) == normalise(b)

  @doc "The same lesson, restated: `same?/2`, or most of the words in common."
  def near?(a, b), do: same?(a, b) or overlap(a, b) >= @overlap

  @doc "How many of the two texts' normalised words they share, from 0 to 1 (Jaccard)."
  def overlap(a, b) do
    {x, y} = {words(a), words(b)}

    case MapSet.size(MapSet.union(x, y)) do
      0 -> 0.0
      all -> MapSet.size(MapSet.intersection(x, y)) / all
    end
  end

  defp words(text) do
    text
    |> normalise()
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&String.replace(&1, ~r/^[[:punct:]…]+|[[:punct:]…]+$/u, ""))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end
end
