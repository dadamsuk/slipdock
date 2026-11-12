defmodule Slipdock.DocsFacts do
  @moduledoc """
  Holds a doc to the facts a claim states, not to its wording (#2794).

  A docs or skill test used to pin a whole sentence (`assert doc =~ "…"`),
  so every rewording of the doc was a test edit too. `assert_states/2` takes
  the same sentence as the claim, and checks only what must hold:

  - its **facts**, every one of them: a code span (`` `slipdock done` ``),
    a short quotation (four words at most), a flag (`--paths`), a card or page id (`#2794`,
    `W-1950`, `TEST-4`), a file path or URL, a `snake_case` name, a
    `Module.function/1` and a number of two digits or more, each exactly as
    written;
  - its **key words** (four letters or more, not a stop word), enough of
    them that the passage is still about the same thing: three in five when
    the claim has no facts, one in three when it has;
  - all of that **close together**: within a window around the first fact
    (or key word) twice the claim's length, and never less than 240
    characters, so a fact named elsewhere in the doc doesn't count.

  Whitespace is collapsed on both sides first, since the docs wrap their
  prose. Key words are matched whole and without regard to case.

  So the doc can be reworded freely, and a test fails only when a fact goes
  (a command renamed, a flag dropped, a link moved) or the passage itself
  does. A claim with neither facts nor key words is matched as written.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @stop ~w(
    about above after again also always another anything because been before
    being both cannot could does doesn done each either else even every from
    have here into isn just like many more most much must need never none
    once only other over same says should since some such than that their
    them then there these they this those through under until upon very
    want were what when where whether which while will with within without
    would your
  )
  # `must`, `never` and `should` are kept out of the stop list below: they
  # carry a rule's force, so they stay key words.
  @stop @stop -- ~w(must never should)

  @fact ~r"""
    https?://[^\s)>\]]+
    | (?<![\w-])--[a-z][\w-]*
    | (?<![\w&])\#\d+\b
    | \b[A-Z][A-Z0-9]{0,7}-\d+\b
    | (?:[\w.<>*{}-]+/)+[\w.<>*{}-]*\.[a-z]{1,5}\b
    | \b[A-Z]\w*(?:\.\w+[!?]?)+(?:/\d)?
    | \b[a-z]\w*_\w+\b
    | \b\d[\d,.]*\d\b
  """x

  @quote ~r/"((?:[^"\s]+\s?){1,4})"/

  @doc "Whether `doc` states the facts of `claim` (see the moduledoc)."
  def states?(doc, claim), do: missing(doc, claim) == []

  @doc """
  Asserts that `doc` states the facts of `claim`, naming what is missing
  from the passage that came closest when it doesn't.
  """
  def assert_states(doc, claim, message \\ nil) do
    case missing(doc, claim) do
      [] ->
        true

      gone ->
        flunk(
          if(message, do: "#{message}\n", else: "") <>
            "the doc no longer states: #{inspect(claim)}\n" <>
            "missing near each other: #{Enum.map_join(gone, ", ", &inspect/1)}"
        )
    end
  end

  @doc "The facts and the key words of a claim, as `{facts, words}`."
  def terms(claim) do
    claim = squash(claim)
    {code, prose} = split_code(claim)
    # A short quotation (a label, a word to say) is a fact; a longer one is prose.
    quoted = for [_, q] <- Regex.scan(@quote, prose), do: q
    prose = Regex.replace(@quote, prose, " ")
    found = for [f] <- Regex.scan(@fact, prose), do: String.trim_trailing(f, ".")
    prose = Regex.replace(@fact, prose, " ")

    words =
      for [w] <- Regex.scan(~r/\b[a-zA-Z][a-zA-Z']{3,}\b/u, prose),
          w = String.downcase(w),
          w not in @stop,
          uniq: true,
          do: w

    facts = (code ++ quoted ++ found) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    {Enum.uniq(facts), words}
  end

  # The terms of `claim` that `doc` doesn't state together, or [] when it does.
  defp missing(doc, claim) do
    doc = squash(doc)
    {facts, words} = terms(claim)

    if facts == [] and words == [] do
      if String.contains?(doc, squash(claim)), do: [], else: [squash(claim)]
    else
      need = words_needed(facts, words)
      width = max(240, 2 * String.length(squash(claim)))
      lower = String.downcase(doc)
      fact_at = Map.new(facts, &{&1, positions(doc, &1)})
      word_at = Map.new(words, &{&1, word_positions(lower, &1)})
      closest(facts, words, fact_at, word_at, need, width)
    end
  end

  defp words_needed([], words), do: ceil(length(words) * 3 / 5)
  defp words_needed(_facts, words), do: ceil(length(words) / 3)

  # Every window around an anchor is tried: each place the claim's rarest
  # fact appears or, with no facts, each place one of its rarest key words
  # does (as many as can be missing, plus one, so a window that holds
  # enough of them holds one of these). The first that holds every fact and
  # enough key words wins; otherwise the terms missing from the window that
  # came closest.
  defp closest(facts, words, fact_at, word_at, need, width) do
    claim = %{facts: facts, words: words, fact_at: fact_at, word_at: word_at, need: need}

    claim
    |> anchors()
    |> Enum.reduce_while(facts ++ Enum.take(words, need), fn at, best ->
      gone = gone_from(claim, at - width, at + width)

      cond do
        gone == [] -> {:halt, []}
        length(gone) < length(best) -> {:cont, gone}
        true -> {:cont, best}
      end
    end)
  end

  defp anchors(%{facts: [], words: words, word_at: word_at, need: need}) do
    word_at
    |> Map.values()
    |> Enum.sort_by(&tuple_size/1)
    |> Enum.take(length(words) - need + 1)
    |> Enum.flat_map(&Tuple.to_list/1)
  end

  defp anchors(%{fact_at: fact_at}),
    do: fact_at |> Map.values() |> Enum.min_by(&tuple_size/1) |> Tuple.to_list()

  # The claim's terms missing from the window lo..hi: every fact not in it,
  # and as many key words as it is short of the number needed.
  defp gone_from(claim, lo, hi) do
    gone_facts = Enum.reject(claim.facts, &within?(claim.fact_at[&1], lo, hi))
    {here, gone_words} = Enum.split_with(claim.words, &within?(claim.word_at[&1], lo, hi))
    gone_facts ++ Enum.take(gone_words, max(claim.need - length(here), 0))
  end

  # Whether a sorted tuple of positions has one in lo..hi: a binary search.
  defp within?(at, lo, hi), do: first_from(at, lo, 0, tuple_size(at)) <= hi

  defp first_from(at, _lo, from, to) when from >= to,
    do: if(from < tuple_size(at), do: elem(at, from), else: :infinity)

  defp first_from(at, lo, from, to) do
    mid = div(from + to, 2)

    if elem(at, mid) < lo,
      do: first_from(at, lo, mid + 1, to),
      else: first_from(at, lo, from, mid)
  end

  defp positions(doc, fact),
    do: List.to_tuple(for({at, _} <- :binary.matches(doc, fact), do: at))

  defp word_positions(lower, word) do
    ~r/\b#{Regex.escape(word)}\b/
    |> Regex.scan(lower, return: :index)
    |> Enum.map(fn [{at, _}] -> at end)
    |> List.to_tuple()
  end

  # Code spans in backticks are facts whole; what is outside them is prose.
  # An unpaired backtick (a claim cut mid-span) leaves its tail as prose.
  defp split_code(claim) do
    parts = String.split(claim, "`")
    paired = if rem(length(parts), 2) == 1, do: parts, else: Enum.drop(parts, -1)
    tail = if paired == parts, do: [], else: [List.last(parts)]

    {code, prose} =
      paired
      |> Enum.with_index()
      |> Enum.split_with(fn {_, i} -> rem(i, 2) == 1 end)

    {Enum.map(code, &elem(&1, 0)),
     Enum.map_join(Enum.map(prose, &elem(&1, 0)) ++ tail, " ", & &1)}
  end

  defp squash(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
