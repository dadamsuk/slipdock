defmodule Slipdock.Inbound.Trim do
  @moduledoc """
  The new part of a reply: quoted history and signatures taken off a mail
  body (#1239), so a reply to a notification reads as the comment the person
  wrote and not the whole thread under it.

  Off the text: the quote header and everything after it (Gmail's `On … wrote:`
  in the languages Gmail writes it in, Apple Mail's `On …, at …, … wrote:`,
  Outlook's `From:/Sent:/To:/Subject:` block and `-----Original Message-----`),
  every `>` line, a signature from its `-- ` line on, and phone footers such as
  "Sent from my iPhone".

  Off the HTML, before it becomes Markdown: `blockquote type=cite` (Apple
  Mail, Thunderbird), Gmail's `gmail_quote` and `gmail_signature`, Yahoo's and
  Thunderbird's quote wrappers, and Outlook's reply header
  (`#divRplyFwdMsg`, `#appendonsend`, `hr#stopSpelling`) with everything
  after it.

  A forward is *not* trimmed: what it forwards is the point of sending it.

  Neither function ever returns an empty body for a message that had content:
  if trimming would leave nothing (a reply that is all quote, say), the
  original comes back untouched.
  """

  alias Slipdock.Inbound.{HtmlToMarkdown, Message}

  @doc """
  A message's body as Markdown, trimmed: the text part when there is one,
  else the HTML converted. `opts` go to `HtmlToMarkdown.convert/2`.
  """
  @spec markdown(Message.t(), keyword()) :: String.t()
  def markdown(%Message{text: text, html: html}, opts \\ []) do
    cond do
      present?(text) -> text(text)
      present?(html) -> html |> html() |> HtmlToMarkdown.convert(opts) |> text()
      true -> ""
    end
  end

  ## Text

  # The line that starts the quoted message, by language. Gmail localises
  # its attribution line; these are the languages it is most often seen in.
  @attribution [
    # English, and Apple Mail's "On 24 Oct 2026, at 13:00, Alice wrote:"
    ~r/^On\b.{0,300}\bwrote:$/i,
    # French, German, Spanish, Italian, Dutch, Portuguese
    ~r/^Le\b.{0,300}\ba écrit\s?:$/i,
    ~r/^Am\b.{0,300}\bschrieb\b.{0,200}:$/i,
    ~r/^El\b.{0,300}\bescribió:$/i,
    ~r/^Il\b.{0,300}\bha scritto:$/i,
    ~r/^Op\b.{0,300}\bschreef\b.{0,200}:$/i,
    ~r/^(Em|No dia)\b.{0,300}\bescreveu:$/i,
    # Swedish, Danish, Norwegian, Finnish
    ~r/^(Den|På)\b.{0,300}\bskrev\b.{0,200}:$/i,
    ~r/^.{0,300}\bkirjoitti:$/i,
    # Polish, Czech, Russian, Turkish
    ~r/^W dniu\b.{0,300}\bnapisał(\(a\))?:$/iu,
    ~r/^.{0,300}\bnapsal(\(a\))?:$/iu,
    ~r/^.{0,300}\s(написал|написала|написал\(а\)):$/iu,
    ~r/^.{0,300}\byazdı:$/iu,
    # Japanese, Chinese, Korean
    ~r/^.{0,300}書き込みました[:：]$/u,
    ~r/^.{0,300}(写道|寫道)[:：]$/u,
    ~r/^.{0,300}작성[:：]$/u
  ]

  @original_message ~r/^-{2,}\s*(Original Message|Ursprüngliche Nachricht|Message d'origine|Mensaje original|Messaggio originale|Oorspronkelijk bericht|Mensagem original)\s*-{2,}$/i

  @rule ~r/^_{10,}$/

  @footer ~r/^(Sent from my \w+|Sent from (Outlook|Mail|Yahoo Mail)\b|Get Outlook for \w+|Sent from my (Samsung|Galaxy|Android|BlackBerry)|Envoyé de mon \w+|Von meinem .* gesendet|Enviado desde mi \w+|Inviato da \w+)/i

  @doc "Trims plain text (or Markdown converted from HTML)."
  @spec text(String.t() | nil) :: String.t()
  def text(nil), do: ""

  def text(text) when is_binary(text) do
    lines = text |> String.replace("\r\n", "\n") |> String.split("\n")
    {own, forwarded} = Enum.split_while(lines, &(not forward?(&1)))

    own =
      own
      |> cut_at_history()
      |> cut_at_signature()
      |> Enum.reject(&quoted?/1)
      |> Enum.reject(&footer?/1)
      |> Enum.reverse()
      |> Enum.drop_while(&(blank?(&1) or rule?(&1)))
      |> Enum.reverse()

    trimmed =
      (own ++ forwarded)
      |> Enum.join("\n")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    if trimmed == "" and present?(text), do: String.trim(text), else: trimmed
  end

  defp cut_at_history(lines) do
    case Enum.find_index(Enum.with_index(lines), fn {_, i} -> history_starts?(lines, i) end) do
      nil -> lines
      at -> Enum.take(lines, at)
    end
  end

  defp history_starts?(lines, i) do
    line = lines |> Enum.at(i) |> clean()
    next = lines |> Enum.at(i + 1, "") |> clean()

    # Gmail wraps a long attribution over two lines.
    attribution?(line) or (line != "" and attribution?(line <> " " <> next)) or
      Regex.match?(@original_message, line) or
      outlook_header?(lines, i) or
      (Regex.match?(@rule, line) and outlook_header?(lines, i + 1))
  end

  defp attribution?(line), do: Enum.any?(@attribution, &Regex.match?(&1, line))

  # "From: …" followed within a few lines by "Sent:"/"Date:" and "To:" or
  # "Subject:", in English or Outlook's other common languages. A bare
  # "From:" line in the middle of someone's prose doesn't count.
  defp outlook_header?(lines, i) do
    line = lines |> Enum.at(i, "") |> clean()

    if Regex.match?(~r/^(From|De|Von|Van|Da|Från|Fra)\s?:\s*\S/i, line) do
      following = lines |> Enum.slice((i + 1)..(i + 5)//1) |> Enum.map(&clean/1)

      Enum.any?(
        following,
        &Regex.match?(
          ~r/^(Sent|Date|Envoyé|Gesendet|Verzonden|Enviado|Inviato|Skickat|Sendt)\s?:/i,
          &1
        )
      ) and
        Enum.any?(
          following,
          &Regex.match?(
            ~r/^(To|Subject|À|Objet|An|Betreff|Aan|Onderwerp|Para|Asunto|A|Oggetto|Till|Ämne|Til|Emne)\s?:/i,
            &1
          )
        )
    else
      false
    end
  end

  # From the signature separator ("-- ", RFC 3676; also a bare "--") on.
  defp cut_at_signature(lines) do
    case Enum.find_index(lines, &(&1 in ["-- ", "--"])) do
      nil -> lines
      at -> Enum.take(lines, at)
    end
  end

  # Where a forwarded message starts (Gmail, Outlook, Apple Mail): what
  # follows is what was forwarded, and is kept as it is.
  defp forward?(line) do
    Regex.match?(
      ~r/^(-{3,}\s*(Forwarded message|Weitergeleitete Nachricht|Message transféré|Mensaje reenviado)\s*-{3,}|Begin forwarded message:)$/i,
      clean(line)
    )
  end

  defp blank?(line), do: String.trim(line) == ""
  # A rule left over above a removed quote ("---", "___", "***").
  defp rule?(line), do: Regex.match?(~r/^\s*([-_*])(\s*\1){2,}\s*$/, line)

  defp quoted?(line), do: String.starts_with?(String.trim_leading(line), ">")
  defp footer?(line), do: Regex.match?(@footer, clean(line))

  # Markdown converted from HTML can carry emphasis round the header labels
  # ("**From:** Alice"), and escapes.
  defp clean(line), do: line |> String.replace(~r/[*\\]/, "") |> String.trim()

  ## HTML

  @remove [
    ~s(blockquote[type="cite"]),
    ".gmail_quote",
    ".gmail_signature",
    ".gmail_extra",
    ".yahoo_quoted",
    ".moz-cite-prefix",
    ".moz-signature",
    ~s(div[data-smartmail="gmail_signature"])
  ]

  # Where Outlook's quoted message begins (`#divRplyFwdMsg`, `#appendonsend`,
  # `hr#stopSpelling`, the new Outlook's reference container): it and
  # everything after it goes.
  @cut_ids ~w(divRplyFwdMsg appendonsend stopSpelling mail-editor-reference-message-container)

  @doc "Trims HTML, before it is converted to Markdown."
  @spec html(String.t() | nil) :: String.t()
  def html(nil), do: ""

  def html(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, tree} ->
        trimmed =
          tree
          |> Floki.filter_out(Enum.join(@remove, ","))
          |> cut_tree()
          |> Floki.raw_html()

        if present?(trimmed |> Floki.parse_document!() |> Floki.text()),
          do: trimmed,
          else: html

      {:error, _} ->
        html
    end
  end

  # Drops the first cut point and every node after it, at whatever depth it
  # sits, along with what follows each of its ancestors.
  defp cut_tree(nodes) do
    {kept, _cut?} = cut_nodes(nodes)
    kept
  end

  defp cut_nodes(nodes) do
    Enum.reduce_while(nodes, {[], false}, fn node, {acc, false} ->
      if cut_point?(node) do
        {:halt, {Enum.reverse(acc), true}}
      else
        case node do
          {tag, attrs, children} ->
            {kids, cut?} = cut_nodes(children)
            acc = [{tag, attrs, kids} | acc]
            if cut?, do: {:halt, {Enum.reverse(acc), true}}, else: {:cont, {acc, false}}

          other ->
            {:cont, {[other | acc], false}}
        end
      end
    end)
    |> case do
      {acc, false} -> {Enum.reverse(acc), false}
      done -> done
    end
  end

  defp cut_point?({_tag, attrs, _}) when is_list(attrs) do
    case List.keyfind(attrs, "id", 0) do
      {_, id} -> id in @cut_ids
      nil -> false
    end
  end

  defp cut_point?(_), do: false

  defp present?(nil), do: false
  defp present?(text), do: String.trim(text) != ""
end
