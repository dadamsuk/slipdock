defmodule SlipdockWeb.RichText do
  @moduledoc """
  Renders card descriptions and comments: plain text with a little Markdown.

  Text is HTML-escaped first, then `![alt](url)` becomes an image,
  `[text](url)` a link, and bare `http(s)://` URLs are linked. Only
  same-site paths and http(s) URLs are honoured, so nothing pasted into a
  card can run script or reach a `javascript:` URL.

  A `[[wiki link]]` is honoured too, because a comment saying "see
  [[Retry policy]]" is the natural way to point a card at a document and it
  already shows up in that page's backlinks (see `Slipdock.Wiki.Links`). Pass
  `:board` to `render/2` for those to resolve; without one they are left as
  written, which is right for the places a board is not in hand.
  """

  @pattern ~r{!\[([^\]]*)\]\(([^)\s]+)\)|\[([^\]]+)\]\(([^)\s]+)\)|https?://[^\s<]+}

  @doc """
  The text as safe HTML. Whitespace is kept, so wrap it in
  `whitespace-pre-wrap`.

  Options: `:board` — resolve `[[wiki links]]` against that board's pages;
  `:as` — the reader, so a link to a page they cannot see stays plain text.
  """
  @spec render(String.t() | nil, keyword) :: Phoenix.HTML.safe()
  def render(text, opts \\ [])

  def render(nil, _opts), do: {:safe, ""}

  def render(text, opts) when is_binary(text) do
    escaped = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    linked = Regex.replace(@pattern, escaped, &replace/5)
    {:safe, wiki_links(linked, opts[:board], opts[:as])}
  end

  # Only page references, and only when a board is in hand. A comment is not
  # a document: a table of contents or a live card chip would be noise in a
  # sentence, and `#412` on a card is a card talking about a card.
  defp wiki_links(html, nil, _reader), do: html

  defp wiki_links(html, board, reader) do
    Regex.replace(~r/\[\[([^\]\n]+)\]\]/, html, fn whole, inner ->
      {target, label} =
        case String.split(inner, "|", parts: 2) do
          [t, l] -> {String.trim(t), String.trim(l)}
          [t] -> {String.trim(t), nil}
        end

      case Slipdock.Wiki.find_page(board, unescape(target)) do
        {:ok, page} ->
          if visible?(page, reader) do
            ~s|<a href="/boards/#{page.board_id}/wiki/#{page.slug}" class="link link-primary" onclick="event.stopPropagation()">| <>
              (label || target) <> "</a>"
          else
            whole
          end

        _ ->
          whole
      end
    end)
  end

  defp visible?(page, nil), do: not Slipdock.Wiki.Page.draft?(page)

  defp visible?(page, reader),
    do: Slipdock.Wiki.visible?(page, Slipdock.Access.page_permission(reader, page))

  # The text was escaped before the pattern ran, so a title with an ampersand
  # or a quote in it has to be put back before it is looked up.
  defp unescape(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  @doc "Whether the text embeds at least one image."
  def has_image?(nil), do: false
  def has_image?(text), do: Regex.match?(~r{!\[[^\]]*\]\([^)\s]+\)}, text)

  # Image: ![alt](url)
  defp replace(whole, alt, url, "", "") when url != "" do
    if safe_url?(url) do
      ~s|<a href="#{url}" target="_blank" rel="noopener" class="inline-block" onclick="event.stopPropagation()"><img src="#{url}" alt="#{alt}" loading="lazy" class="my-1 max-h-96 max-w-full rounded-lg border border-base-content/10" /></a>|
    else
      whole
    end
  end

  # Link: [text](url)
  defp replace(whole, "", "", text, url) when text != "" do
    if safe_url?(url), do: link(url, text), else: whole
  end

  # Bare URL, leaving trailing punctuation outside the link.
  defp replace(whole, "", "", "", "") do
    {url, rest} = split_trailing(whole)
    link(url, url) <> rest
  end

  defp replace(whole, _, _, _, _), do: whole

  defp link(url, text),
    do:
      ~s|<a href="#{url}" target="_blank" rel="noopener" class="link link-primary break-all" onclick="event.stopPropagation()">#{text}</a>|

  defp split_trailing(url) do
    trimmed = Regex.replace(~r/(?:[.,;:!?)]|&quot;|&#39;)+$/, url, "")
    # Keep the trailing ")" of a URL that also opens a "(".
    trimmed =
      if String.ends_with?(url, ")") and String.contains?(trimmed, "(") and
           not String.ends_with?(trimmed, ")"),
         do: trimmed <> ")",
         else: trimmed

    {trimmed, binary_part(url, byte_size(trimmed), byte_size(url) - byte_size(trimmed))}
  end

  # The text is already escaped, so a URL can't contain quotes or angle brackets.
  defp safe_url?(url) do
    String.starts_with?(url, ["http://", "https://"]) or
      (String.starts_with?(url, "/") and not String.starts_with?(url, "//"))
  end
end
