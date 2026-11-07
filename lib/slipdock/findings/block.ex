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
  """

  alias Slipdock.Findings.Finding

  @header ~r/^([ \t>]*)(?:([-*+])[ \t]+)?(?:\*\*|__)?Findings(?:\*\*|__)?:(?:\*\*|__)?[ \t]*(.*)$/i
  @item ~r/^([ \t>]*)[-*+][ \t]+(.*)$/
  @kind ~r/^(?:\*\*|__|`)?([A-Za-z][A-Za-z _-]*?)(?:[ \t]*\(([A-Za-z]+)\))?(?:\*\*|__|`)?[ \t]*:(?:\*\*|__)?[ \t]*(.*)$/s
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
    list |> Enum.map(&classify/1) |> Enum.reject(&pointer?(&1.text))
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

  @doc "One item as `%{kind, text, scope}`; one with no known kind is a `gotcha`, kept whole."
  def classify(item) do
    with [_, kind, qualifier, text] <- Regex.run(@kind, item),
         kind = normalise(kind),
         true <- Enum.member?(Finding.kinds(), kind),
         text = String.trim(text),
         true <- text != "" do
      %{kind: kind, text: text, scope: scope(kind, qualifier)}
    else
      _ -> %{kind: "gotcha", text: item, scope: "board"}
    end
  end

  defp scope("tooling", qualifier) do
    if String.downcase(qualifier) == "runner", do: "runner", else: "board"
  end

  defp scope(_kind, _qualifier), do: "board"

  defp normalise(kind) do
    kind = kind |> String.downcase() |> String.trim() |> String.replace(~r/[ _]+/, "-")
    Map.get(@aliases, kind, kind)
  end
end
