defmodule Slipdock.Wiki.Markup do
  @moduledoc """
  The wiki's own syntax, lexed out of a run of plain text.

  This module knows nothing about HTML, the database, or what any of these
  references point at. It turns text into tokens, and four different things
  then do four different jobs with the same tokens: the HTML renderer draws
  them, `Slipdock.Wiki.Links` reconciles them into `page_links`, the search
  chunker strips them, and the API's `render` endpoint resolves them back to
  Markdown for an agent. One lexer, four consumers, no drift — the way
  `Slipdock.Automations.Spec` is the one place that knows a rule's shape.

  It is deliberately given *text*, not Markdown: the caller walks the
  document's syntax tree and hands over text nodes only, so nothing here can
  reach inside a code span or a fenced block. `[[not a link]]` in backticks
  stays exactly what it says.

  ## What it recognises

  | Written | Token |
  |---|---|
  | `[[Retry policy]]` | a page on this board, by title then slug |
  | `[[retry-policy\\|how retries work]]` | the same, with link text |
  | `[[QVM/Retry policy]]` | a page on another board, by board code or name |
  | `[[W-31]]` or bare `W-31` | a page by its code |
  | `[[#412]]` or bare `#412` | card 412, drawn as a live chip |
  | `[[board:QVM]]` | a board |
  | `[[view:QVM/Blocked work]]` | a saved view |
  | `[[!toc]]` `[[!children]]` `[[!backlinks]]` | a directive, expanded at render time |
  | `@name` | a mention of a board member |
  | `{{count: flag=blocked}}` | an inline query, answered at render time |

  Bare `#412` is only a card reference when the digits stand alone, so
  `#1 priority` survives as itself; whether the card exists is the resolver's
  business, not the lexer's.
  """

  @type kind :: :page | :card | :board | :view | :directive | :mention | :inline

  @type token ::
          {:text, String.t()}
          | {:ref, ref}

  @type ref :: %{
          kind: kind,
          target: String.t(),
          board: String.t() | nil,
          label: String.t() | nil,
          raw: String.t()
        }

  @directives ~w(toc children backlinks)

  # One pass, four shapes. Order matters only in that `[[…]]` is tried first,
  # so a bracketed reference is never also read as a bare one.
  @pattern ~r/
      \[\[(?<wiki>[^\]\n]*)\]\]
    | \{\{(?<inline>[^}\n]{1,200})\}\}
    | (?<![\w#])\#(?<card>\d+)(?![\w-])
    | (?<![\w-])(?<code>[Ww]-\d+)(?![\w-])
    | (?<![\w@\/])@(?<mention>[a-zA-Z](?:[\w.\-]{0,61}\w)?)
  /x

  @doc "The directives `[[!…]]` understands."
  def directives, do: @directives

  @doc """
  Splits `text` into literal runs and references.

  Adjacent literal text is not merged across a reference, so rebuilding the
  original is `Enum.map_join(tokens, &raw/1)`.
  """
  @spec tokens(String.t()) :: [token]
  def tokens(text) when is_binary(text) do
    @pattern
    |> Regex.scan(text, return: :index, capture: :all)
    |> Enum.reduce({[], 0}, fn [{start, len} | _] = match, {acc, cursor} ->
      before = binary_part(text, cursor, start - cursor)
      raw = binary_part(text, start, len)

      token =
        case reference(raw, match, text) do
          nil -> {:text, raw}
          ref -> {:ref, ref}
        end

      acc = if before == "", do: acc, else: [{:text, before} | acc]
      {[token | acc], start + len}
    end)
    |> then(fn {acc, cursor} ->
      rest = binary_part(text, cursor, byte_size(text) - cursor)
      acc = if rest == "", do: acc, else: [{:text, rest} | acc]
      Enum.reverse(acc)
    end)
  end

  def tokens(_), do: []

  @doc "Every reference in `text`, literal runs dropped."
  @spec refs(String.t()) :: [ref]
  def refs(text) do
    text
    |> tokens()
    |> Enum.flat_map(fn
      {:ref, ref} -> [ref]
      _ -> []
    end)
  end

  @doc "What a token was written as — `tokens/1` is lossless through this."
  def raw({:text, text}), do: text
  def raw({:ref, %{raw: raw}}), do: raw

  # Which alternative of @pattern matched, by looking at which group has a
  # non-negative offset. The groups are positional — wiki, card, code,
  # mention — and `:re` drops unmatched *trailing* groups, so the list is
  # padded back out to four before it is read.
  defp reference(raw, [_whole | groups], text) do
    case Enum.map(0..4, &(groups |> Enum.at(&1) |> capture(text))) do
      [inner, nil, nil, nil, nil] when is_binary(inner) -> bracketed(inner, raw)
      [nil, expr, nil, nil, nil] when is_binary(expr) -> inline_ref(expr, raw)
      [nil, nil, number, nil, nil] when is_binary(number) -> card_ref(number, raw)
      [nil, nil, nil, code, nil] when is_binary(code) -> page_code_ref(code, raw)
      [nil, nil, nil, nil, name] when is_binary(name) -> mention_ref(name, raw)
      _ -> nil
    end
  end

  defp capture(nil, _text), do: nil
  defp capture({-1, _}, _text), do: nil
  defp capture({start, len}, text), do: binary_part(text, start, len)

  # `[[ … ]]`, which carries every form but the bare ones.
  defp bracketed(inner, raw) do
    {target, label} = split_label(inner)

    cond do
      target == "" ->
        nil

      String.starts_with?(target, "!") ->
        directive_ref(target, label, raw)

      String.starts_with?(target, "board:") ->
        %{kind: :board, target: rest_of(target, "board:"), board: nil, label: label, raw: raw}

      String.starts_with?(target, "view:") ->
        view_ref(rest_of(target, "view:"), label, raw)

      String.starts_with?(target, "#") ->
        case Integer.parse(String.trim_leading(target, "#")) do
          {_, ""} -> card_ref(String.trim_leading(target, "#"), raw, label)
          _ -> nil
        end

      page_code?(target) ->
        page_code_ref(target, raw, label)

      String.contains?(target, "/") ->
        [board, page] = String.split(target, "/", parts: 2)

        %{
          kind: :page,
          target: String.trim(page),
          board: String.trim(board),
          label: label,
          raw: raw
        }

      true ->
        %{kind: :page, target: target, board: nil, label: label, raw: raw}
    end
  end

  defp directive_ref(target, label, raw) do
    name = target |> String.trim_leading("!") |> String.downcase() |> String.trim()

    if name in @directives,
      do: %{kind: :directive, target: name, board: nil, label: label, raw: raw},
      else: nil
  end

  # `view:Blocked work` on this board, `view:QVM/Blocked work` on another.
  defp view_ref(rest, label, raw) do
    case String.split(rest, "/", parts: 2) do
      [board, name] ->
        %{
          kind: :view,
          target: String.trim(name),
          board: String.trim(board),
          label: label,
          raw: raw
        }

      [name] ->
        %{kind: :view, target: String.trim(name), board: nil, label: label, raw: raw}
    end
  end

  defp card_ref(number, raw, label \\ nil),
    do: %{kind: :card, target: number, board: nil, label: label, raw: raw}

  defp page_code_ref(code, raw, label \\ nil),
    do: %{kind: :page, target: String.upcase(code), board: nil, label: label, raw: raw}

  defp mention_ref(name, raw),
    do: %{kind: :mention, target: name, board: nil, label: nil, raw: raw}

  # `{{count: flag=blocked}}` and friends. Whether the expression means
  # anything is `Slipdock.Wiki.Query`'s business; one that does not is left
  # exactly as written, which is also what keeps a template page — whose
  # `{{card.title}}` is filled at *creation* — readable before it is used.
  defp inline_ref(expr, raw),
    do: %{kind: :inline, target: String.trim(expr), board: nil, label: nil, raw: raw}

  defp page_code?(target), do: Regex.match?(~r/^[Ww]-\d+$/, target)

  defp rest_of(target, prefix),
    do:
      target
      |> binary_part(byte_size(prefix), byte_size(target) - byte_size(prefix))
      |> String.trim()

  # "slug|label" — the label is whatever follows the first pipe.
  defp split_label(inner) do
    case String.split(inner, "|", parts: 2) do
      [target, label] -> {String.trim(target), nonblank(String.trim(label))}
      [target] -> {String.trim(target), nil}
    end
  end

  defp nonblank(""), do: nil
  defp nonblank(text), do: text

  @doc """
  The text with every reference replaced by what it reads as — the label, or
  the thing it names. What the search index is given, so a vector is built
  from words rather than from syntax.
  """
  def to_plain(text) do
    text
    |> tokens()
    |> Enum.map_join(fn
      {:text, literal} -> literal
      {:ref, %{kind: :directive}} -> ""
      {:ref, %{kind: :inline}} -> ""
      {:ref, %{label: label}} when is_binary(label) -> label
      {:ref, %{kind: :card, target: number}} -> "##{number}"
      {:ref, %{kind: :mention, target: name}} -> "@#{name}"
      {:ref, %{target: target}} -> target
    end)
  end
end
