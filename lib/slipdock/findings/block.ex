defmodule Slipdock.Findings.Block do
  @moduledoc """
  The `Findings:` block of a comment, beside its `Handbook:` line (W-2310
  §Findings):

      - Findings:
        - gotcha: `mix format` can need two passes
        - rule: every new MCP tool gets a docs_test regex
        - handbook-wrong: W-1950 §Tests says …, but …
        - tooling: …
        - process: …

  `Findings: none` says there was nothing. An item whose kind isn't one of
  `Slipdock.Findings.Finding.kinds/0` is kept whole as a `gotcha`, so nothing
  written is lost to a typo.

  `- tooling (runner): …` marks a tooling item as about the machine the pass
  ran on (its installed CLI or skills), not the project: its `scope` is
  `runner` (#1941). Every other item, and `(runner)` on any other kind, is
  `board`.

  An item whose only text points elsewhere (`in the evidence`, `in the
  subcards' evidence (#1958, #1960)`, `resolves #75 and #77`, `recorded on
  #1819`) is not a finding and is dropped (#1975): the evidence is a comment
  of its own and its block is read there, and a pointer kept would be counted
  on every card that writes it, until it looked like a rule. A block of only
  pointers is `Findings: none`.

  An item can say it is already dealt with (#2120): `[done: <where>]` after
  its kind (`- gotcha [done: W-1950 §Local setup]: …`) when it is settled in
  the handbook, or `→ #<card>` (or `-> #<card>`) at its end when it was filed
  as a card. Such an item carries `done:` (the place, or the card ids), its
  text has the arrow taken off, and `Slipdock.Findings` keeps it `promoted`
  rather than open. Wording alone ("(corrected)", "fixed") is not read as
  done: lessons say "fixed" too.
  """

  alias Slipdock.Findings.Finding

  @header ~r/^([ \t>]*)(?:([-*+])[ \t]+)?(?:\*\*|__)?Findings(?:\*\*|__)?:(?:\*\*|__)?[ \t]*(.*)$/i
  @item ~r/^([ \t>]*)[-*+][ \t]+(.*)$/
  @kind ~r/^(?:\*\*|__|`)?([A-Za-z][A-Za-z _-]*?)(?:[ \t]*\(([A-Za-z]+)\))?(?:\*\*|__|`)?(?:[ \t]*\[[ \t]*done[ \t]*:[ \t]*([^\]]*?)[ \t]*\])?(?:\*\*|__|`)?[ \t]*:(?:\*\*|__)?[ \t]*(.*)$/s
  # `→ #2087` (or `-> card #2087, #2088`) at the end: filed as a card.
  @filed ~r/[ \t]*(?:→|->)[ \t]*((?:cards?[ \t]+)?#\d+(?:[ \t]*(?:,|&|\band\b)[ \t]*#\d+)*)[ \t]*[.;]?[ \t]*$/u
  @none ~r/^(?:\*\*|__|_)?none\b/i
  # What an item points at instead of saying: a place (the evidence, a
  # subcard's evidence, the closing comment) or ids (#75, card #12, W-1950).
  @place ~S"(?:(?:the|its|their|each|this|that|these)[ \t]+)?(?:(?:card|epic|subcard|child|children)(?:'s|s'|s)?[ \t]+)?(?:evidence|closing[ \t]+comments?|completion(?:[ \t]+comment)?|wrap-?up|subcards?|comments?[ \t]+above|block[ \t]+above)"
  @ref ~S"(?:(?:cards?|findings?|comments?|subcards?|epics?|jobs?|prs?)[ \t]+)?(?:#\d+|W-\d+(?:[ \t]*§[^,;()]*?)?)"
  @refs @ref <> ~S"(?:[ \t]*(?:,|&|\+|\band\b)[ \t]*" <> @ref <> ")*"
  @aside ~S"(?:[ \t]*\(.*\))?"
  @pointers [
    ~r/^(?:(?:are|were|all|kept|written|listed|given|recorded)[ \t]+)?(?:see[ \t]+)?(?:in|on|under)[ \t]+#{@place}(?:[ \t]+(?:of[ \t]+|on[ \t]+)?#{@refs})?#{@aside}$/iu,
    ~r/^(?:see|resolves|resolved[ \t]+by|recorded[ \t]+(?:on|in)|same[ \t]+as|as[ \t]+(?:on|in)|covered[ \t]+(?:by|in|on)|merged[ \t]+into|duplicates?|already[ \t]+(?:recorded[ \t]+)?(?:on|in)|on|in)[ \t]+#{@refs}#{@aside}$/iu
  ]

  @aliases %{
    "rule-candidate" => "rule",
    "handbookwrong" => "handbook-wrong",
    "tool" => "tooling",
    "gotchas" => "gotcha"
  }

  @doc """
  The block's items as `[%{kind: kind, text: text, scope: scope}]`: `[]` for `Findings: none`
  (or an empty block, or one whose items only point elsewhere), nil when the
  text has no block at all.
  """
  def parse(text) when is_binary(text) do
    lines = String.split(text, ~r/\r?\n/)

    case Enum.split_while(lines, &(not Regex.match?(@header, &1))) do
      {_, []} -> nil
      {_, [header | rest]} -> items(Regex.run(@header, header), rest)
    end
  end

  def parse(_), do: nil

  defp items([_, prefix, bullet, said], rest) do
    said = String.trim(said)

    if Regex.match?(@none, said) do
      []
    else
      # Under a bulleted `- Findings:` its items are nested deeper; under a bare
      # `Findings:` line any list straight after it is the block.
      depth = if bullet == "", do: -1, else: width(prefix)
      first = if said == "", do: [], else: [said]

      rest
      |> drop_leading_blanks(first)
      |> collect(depth, Enum.reverse(first))
      |> Enum.reject(&(&1 == ""))
      |> classify_all()
    end
  end

  # `Findings:` with a single `- none` under it is none too.
  defp classify_all([only] = list) do
    if Regex.match?(@none, only), do: [], else: keep_said(list)
  end

  defp classify_all(list), do: keep_said(list)

  defp keep_said(list) do
    list |> Enum.map(&classify/1) |> Enum.reject(&(&1.text == "" or pointer?(&1.text)))
  end

  @doc """
  Whether an item's text only points elsewhere (the evidence, a subcard, other
  cards or findings by id) rather than saying anything itself.
  """
  def pointer?(text) when is_binary(text) do
    said =
      text
      |> String.replace(~r/\*\*|__|`/, "")
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.trim_trailing(";")
      |> String.trim()

    Enum.any?(@pointers, &Regex.match?(&1, said))
  end

  # One blank line between `Findings:` and its list is allowed, not after it.
  defp drop_leading_blanks([line | rest], []) do
    if String.trim(line) == "", do: rest, else: [line | rest]
  end

  defp drop_leading_blanks(lines, _), do: lines

  defp collect([], _depth, acc), do: Enum.reverse(acc)

  defp collect([line | rest], depth, acc) do
    case Regex.run(@item, line) do
      [_, prefix, body] ->
        if width(prefix) > depth,
          do: collect(rest, depth, [String.trim(body) | acc]),
          else: Enum.reverse(acc)

      nil ->
        continuation(line, rest, depth, acc)
    end
  end

  # An indented line under an item carries on that item.
  defp continuation(line, rest, depth, [last | acc]) do
    if String.trim(line) != "" and width(leading(line)) > max(depth, 0) + 1,
      do: collect(rest, depth, [last <> " " <> String.trim(line) | acc]),
      else: Enum.reverse([last | acc])
  end

  defp continuation(_line, _rest, _depth, []), do: []

  defp leading(line), do: hd(Regex.run(~r/^[ \t>]*/, line))
  defp width(prefix), do: prefix |> String.replace("\t", "  ") |> String.length()

  @doc """
  One item as `%{kind, text, scope}`, with `done:` when it says where it was
  dealt with (`[done: …]` or `→ #id`); one with no known kind is a `gotcha`,
  kept whole.
  """
  def classify(item) do
    {said, filed} = filed(item)

    with [_, kind, qualifier, done, text] <- Regex.run(@kind, said),
         kind = normalise(kind),
         true <- Enum.member?(Finding.kinds(), kind),
         text = String.trim(text),
         true <- text != "" do
      %{kind: kind, text: text, scope: scope(kind, qualifier)}
      |> put_done(String.trim(done), filed)
    else
      # Only a kind and an arrow (`- gotcha: → #12`) says nothing: dropped.
      _ -> put_done(%{kind: "gotcha", text: bare(said, filed), scope: "board"}, "", filed)
    end
  end

  defp bare(said, nil), do: said
  defp bare(said, _filed), do: if(Regex.match?(~r/^[^:\s]*:?$/u, said), do: "", else: said)

  # The item without a trailing `→ #id`, and the ids it names.
  defp filed(item) do
    case Regex.run(@filed, item, return: :index) do
      [{at, _}, {from, len}] ->
        {item |> binary_part(0, at) |> String.trim(), binary_part(item, from, len)}

      nil ->
        {item, nil}
    end
  end

  defp put_done(item, "", nil), do: item
  defp put_done(item, "", filed), do: Map.put(item, :done, filed)
  defp put_done(item, done, nil), do: Map.put(item, :done, done)
  defp put_done(item, done, filed), do: Map.put(item, :done, done <> "; " <> filed)

  defp scope("tooling", qualifier) do
    if String.downcase(qualifier) == "runner", do: "runner", else: "board"
  end

  defp scope(_kind, _qualifier), do: "board"

  defp normalise(kind) do
    kind = kind |> String.downcase() |> String.trim() |> String.replace(~r/[ _]+/, "-")
    Map.get(@aliases, kind, kind)
  end
end
