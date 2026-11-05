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
  """

  alias Slipdock.Findings.Finding

  @header ~r/^([ \t>]*)(?:([-*+])[ \t]+)?(?:\*\*|__)?Findings(?:\*\*|__)?:(?:\*\*|__)?[ \t]*(.*)$/i
  @item ~r/^([ \t>]*)[-*+][ \t]+(.*)$/
  @kind ~r/^(?:\*\*|__|`)?([A-Za-z][A-Za-z _-]*?)(?:\*\*|__|`)?[ \t]*:(?:\*\*|__)?[ \t]*(.*)$/s
  @none ~r/^(?:\*\*|__|_)?none\b/i
  @aliases %{
    "rule-candidate" => "rule",
    "handbookwrong" => "handbook-wrong",
    "tool" => "tooling",
    "gotchas" => "gotcha"
  }

  @doc """
  The block's items as `[%{kind: kind, text: text}]`: `[]` for `Findings: none`
  (or an empty block), nil when the text has no block at all.
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
    if Regex.match?(@none, only), do: [], else: Enum.map(list, &classify/1)
  end

  defp classify_all(list), do: Enum.map(list, &classify/1)

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

  @doc "One item as `%{kind, text}`; one with no known kind is a `gotcha`, kept whole."
  def classify(item) do
    with [_, kind, text] <- Regex.run(@kind, item),
         kind = normalise(kind),
         true <- Enum.member?(Finding.kinds(), kind),
         text = String.trim(text),
         true <- text != "" do
      %{kind: kind, text: text}
    else
      _ -> %{kind: "gotcha", text: item}
    end
  end

  defp normalise(kind) do
    kind = kind |> String.downcase() |> String.trim() |> String.replace(~r/[ _]+/, "-")
    Map.get(@aliases, kind, kind)
  end
end
