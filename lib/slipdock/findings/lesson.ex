defmodule Slipdock.Findings.Lesson do
  @moduledoc """
  When two findings are the same lesson (#1941, W-2310 §Findings), with no
  model call.

  `normalise/1` is the key: lower case, backticks gone, whitespace collapsed,
  trailing punctuation dropped, and every `#id` and commit sha read as one
  token, so "fixed in #12" and "Fixed in `#34`." are the same lesson. On one
  card a restatement in other words counts too (`near?/2`): the same key, or
  at least #{trunc(0.6 * 100)}% of the normalised words in common.

  Across cards the texts are longer and the wording drifts further, so
  `alike?/2` weighs the words that tell a lesson apart (#2117): the common
  ones (`the`, `run`, `when`) count for nothing, a name, a path or a flag (in
  backticks, or with `_`, `.` or a digit in it) counts three times an ordinary
  word, and the score is the shared weight over the two texts' mean
  (`similarity/2`, Dice). At 0.55 or more they are the same lesson.
  Measured on the slipdock board's findings of 2026-11-08: six of the eight
  ways the shared `_pre_push` database was written up clear it, and no pair of
  different lessons above it was found.
  """

  @overlap 0.6
  @alike 0.55
  @code_weight 3

  # Words that say nothing about which lesson it is.
  @common ~w(a an the and or but if of to in on at by for with from as is are was
    were be been being it its this that these those there here which who what
    when where why how not no nor so than then too very can could would should
    will shall may might must do does did done has have had having into onto
    out over under about after before again once all any both each few more
    most other some such only own same just also every one two your you we our
    they them their his her he she me my via per etc isn't doesn't don't can't
    won't it's that's use used uses using run runs ran running get gets make
    makes need needs) |> MapSet.new()

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

  @doc """
  The same lesson, in other words, as said on another card: `same?/2`, or a
  `similarity/2` of at least 0.55.
  """
  def alike?(a, b), do: same?(a, b) or similarity(a, b) >= @alike

  @doc "The `similarity/2` at which two texts are the same lesson."
  def alike_at, do: @alike

  @doc """
  How alike two texts are, from 0 to 1: the weight of the telling words they
  share over the mean weight of each (Dice), a code word weighing
  three and an ordinary one 1, the common words none.
  """
  def similarity(a, b) do
    {x, y} = {weighed(a), weighed(b)}
    total = sum(x) + sum(y)

    if total == 0 do
      0.0
    else
      shared = for {w, n} <- x, m = y[w], m != nil, reduce: 0, do: (acc -> acc + min(n, m))
      2 * shared / total
    end
  end

  defp sum(weights), do: weights |> Map.values() |> Enum.sum()

  # Each telling word of the text, with its weight. A backticked span is code
  # throughout; outside one, a word is code when it has `_`, `.` or a digit.
  defp weighed(text) when is_binary(text) do
    ~r/(`[^`]*`)/u
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.flat_map(&weigh_part/1)
    |> Enum.reduce(%{}, fn {w, n}, acc -> Map.update(acc, w, n, &max(&1, n)) end)
  end

  defp weighed(_), do: %{}

  defp weigh_part(part) do
    code? = String.starts_with?(part, "`")

    part
    |> String.downcase()
    |> String.replace("`", "")
    |> String.replace(~r/#\d+\b/u, " ")
    |> String.replace(~r/\b(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b/u, " ")
    |> String.split(~r/[\s=\/(),;:"\[\]{}<>|+*!?…]+/u, trim: true)
    |> Enum.map(&String.replace(&1, ~r/^[^\w]+|[^\w']+$/u, ""))
    |> Enum.reject(&(String.length(&1) < 3 or MapSet.member?(@common, &1)))
    |> Enum.map(fn w ->
      w = stem(w)
      {w, if(code? or w =~ ~r/[_.\d]/u, do: @code_weight, else: 1)}
    end)
  end

  # "branch's" is "branch", and "worktrees" "worktree": enough to meet the
  # same word again, without a stemmer.
  defp stem(word) do
    word = String.replace(word, ~r/'s$/u, "")

    if String.length(word) > 4 and String.ends_with?(word, "s") and
         not String.ends_with?(word, "ss"),
       do: String.slice(word, 0..-2//1),
       else: word
  end
end
