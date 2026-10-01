defmodule SlipdockWeb.Markdown do
  @moduledoc """
  Renders the model's Markdown answers: a small, safe subset on top of
  `SlipdockWeb.RichText` (which escapes the text and links URLs). Paragraphs,
  bullet and numbered lists, headings (shown as bold lead-ins), `**bold**`,
  `*italic*` and `` `code` `` are supported; everything else stays literal.
  """

  alias SlipdockWeb.RichText

  @doc "The Markdown as safe HTML."
  @spec render(String.t() | nil) :: Phoenix.HTML.safe()
  def render(nil), do: {:safe, ""}

  def render(text) when is_binary(text) do
    html =
      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> blocks()
      |> Enum.map_join("", &block_html/1)

    {:safe, html}
  end

  # Groups lines into {:list, kind, items}, {:heading, text} and {:para, lines}.
  defp blocks(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" ->
          [:blank | acc]

        match = Regex.run(~r/^\s{0,3}(?:[-*+•]|\d+[.)])\s+(.*)$/, line) ->
          kind = if Regex.match?(~r/^\s{0,3}\d/, line), do: :ol, else: :ul
          [_, item] = match

          case acc do
            [{:list, ^kind, items} | rest] -> [{:list, kind, [item | items]} | rest]
            _ -> [{:list, kind, [item]} | acc]
          end

        match = Regex.run(~r/^\s{0,3}\#{1,6}\s+(.*)$/, line) ->
          [_, heading] = match
          [{:heading, heading} | acc]

        true ->
          case acc do
            [{:para, para} | rest] -> [{:para, [trimmed | para]} | rest]
            _ -> [{:para, [trimmed]} | acc]
          end
      end
    end)
    |> Enum.reject(&(&1 == :blank))
    |> Enum.reverse()
    |> Enum.map(fn
      {:list, kind, items} -> {:list, kind, Enum.reverse(items)}
      {:para, lines} -> {:para, Enum.reverse(lines)}
      other -> other
    end)
  end

  defp block_html({:heading, text}), do: "<p><strong>#{inline(text)}</strong></p>"
  defp block_html({:para, lines}), do: "<p>#{Enum.map_join(lines, "<br>", &inline/1)}</p>"

  defp block_html({:list, kind, items}) do
    tag = if kind == :ol, do: "ol", else: "ul"
    "<#{tag}>" <> Enum.map_join(items, "", &"<li>#{inline(&1)}</li>") <> "</#{tag}>"
  end

  # Inline marks are applied to the escaped, linked text.
  defp inline(text) do
    {:safe, escaped} = RichText.render(text)

    escaped
    |> String.replace(~r/`([^`]+)`/, "<code>\\1</code>")
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/(?<![\w*])\*(?!\s)([^*]+?)(?<!\s)\*(?!\w)/, "<em>\\1</em>")
    |> String.replace(~r/(?<![\w])_(?!\s)([^_]+?)(?<!\s)_(?![\w])/, "<em>\\1</em>")
  end
end
