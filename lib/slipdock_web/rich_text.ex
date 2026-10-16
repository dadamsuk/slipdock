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

  With a board, `@someone` who can see it is drawn as a mention too (see
  `Slipdock.Mentions`); anybody else stays as typed.

  `markdown/2` is what the card panel shows (#868): the same text read as
  Markdown — paragraphs, lists, headings, emphasis, code, quotes, tables and
  task lists — with each run of plain text still going through `render/2`.
  """

  @pattern ~r{!\[([^\]]*)\]\(([^)\s]+)\)|\[([^\]]+)\]\(([^)\s]+)\)|https?://[^\s<]+}

  @doc """
  The text as safe HTML. Whitespace is kept, so wrap it in
  `whitespace-pre-wrap`.

  Options: `:board` — resolve `[[wiki links]]` against that board's pages;
  `:as` — the reader, so a link to a page they cannot see stays plain text;
  `:members` — the board's members (`Slipdock.Wiki.Links.members/1`), when
  the caller renders many texts for one board and has already looked them up.
  """
  @spec render(String.t() | nil, keyword) :: Phoenix.HTML.safe()
  def render(text, opts \\ [])

  def render(nil, _opts), do: {:safe, ""}

  def render(text, opts) when is_binary(text) do
    escaped = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    linked = Regex.replace(@pattern, escaped, &replace/5)

    {:safe,
     linked |> wiki_links(opts[:board], opts[:as]) |> mentions(opts[:board], opts[:members])}
  end

  @extension [table: true, tasklist: true, strikethrough: true]

  # A single newline is a line break: that is how these texts were always
  # shown, and a list of steps one per line should not run together.
  @render [unsafe: true, hardbreaks: true]

  # Every tag in the output is either comrak's or one this module wrote, since
  # raw HTML in the text is turned back into text first; the sanitiser is the
  # second lock. It forces every link's onclick, so a click on one does not
  # also start editing the description it sits in.
  @sanitize [
    add_tags: ["input"],
    add_tag_attributes: %{
      "a" => ["target"],
      "img" => ["loading"],
      "input" => ["type", "checked", "disabled"]
    },
    add_generic_attributes: ["class", "title"],
    link_rel: "noopener",
    set_tag_attribute_values: %{"a" => %{"onclick" => "event.stopPropagation()"}}
  ]

  @doc """
  The text read as Markdown, as safe HTML in block elements (so no
  `whitespace-pre-wrap`: single newlines become line breaks). Takes the same
  options as `render/2`.

  Raw HTML is shown as written, not obeyed, and a link or image to anything
  but a same-site path or an http(s) URL is left as its text. A text that
  cannot be parsed falls back to `render/2`.
  """
  @spec markdown(String.t() | nil, keyword) :: Phoenix.HTML.safe()
  def markdown(text, opts \\ [])

  def markdown(nil, _opts), do: {:safe, ""}

  def markdown(text, opts) when is_binary(text) do
    # Looked up once for the whole text, not once per run of it.
    opts =
      if opts[:board] && !opts[:members] && String.contains?(text, "@"),
        do: Keyword.put(opts, :members, Slipdock.Wiki.Links.members(opts[:board])),
        else: opts

    with {:ok, doc} <- MDEx.parse_document(text, extension: @extension),
         {:ok, html} <-
           %{doc | nodes: expand(doc.nodes, opts)}
           |> MDEx.to_html(extension: @extension, render: @render, sanitize: @sanitize) do
      {:safe, html}
    else
      _ -> render(text, opts)
    end
  end

  defp expand(nodes, opts) do
    nodes
    |> Enum.map(&literal_html/1)
    |> merge_text()
    |> Enum.flat_map(&expand_node(&1, opts))
  end

  # Somebody's <b> or <script> is something they typed, so it reads as typed.
  defp literal_html(%MDEx.HtmlInline{literal: literal}), do: %MDEx.Text{literal: literal}

  defp literal_html(%MDEx.HtmlBlock{literal: literal}) do
    lines = literal |> String.trim_trailing() |> String.split("\n")

    %MDEx.Paragraph{
      nodes: lines |> Enum.map(&%MDEx.Text{literal: &1}) |> Enum.intersperse(%MDEx.LineBreak{})
    }
  end

  defp literal_html(node), do: node

  defp literal_tree(nodes) do
    nodes
    |> Enum.map(fn node ->
      case literal_html(node) do
        %{nodes: [_ | _] = children} = node -> %{node | nodes: literal_tree(children)}
        node -> node
      end
    end)
    |> merge_text()
  end

  defp merge_text(nodes) do
    nodes
    |> Enum.chunk_while(
      nil,
      fn
        %MDEx.Text{literal: b}, %MDEx.Text{literal: a} -> {:cont, %MDEx.Text{literal: a <> b}}
        node, nil -> {:cont, node}
        node, prev -> {:cont, prev, node}
      end,
      fn
        nil -> {:cont, nil}
        prev -> {:cont, prev, nil}
      end
    )
  end

  defp expand_node(%MDEx.Text{literal: text}, opts),
    do: [%MDEx.HtmlInline{literal: text |> render(opts) |> Phoenix.HTML.safe_to_string()}]

  defp expand_node(%MDEx.Link{url: url, nodes: children}, _opts) do
    url = escape(url)
    # The link's own text is not linked again, mentioned or looked up.
    children = literal_tree(children)

    if safe_url?(url) do
      [%MDEx.HtmlInline{literal: link_open(url)}] ++
        children ++ [%MDEx.HtmlInline{literal: "</a>"}]
    else
      children
    end
  end

  defp expand_node(%MDEx.Image{url: url, nodes: children}, _opts) do
    url = escape(url)
    alt = children |> Enum.map_join(&plain_text/1) |> escape()

    if safe_url?(url),
      do: [%MDEx.HtmlInline{literal: image(url, alt)}],
      else: [%MDEx.Text{literal: plain_text(%{nodes: children})}]
  end

  defp expand_node(%{nodes: children} = node, opts) when is_list(children),
    do: [%{node | nodes: expand(children, opts)}]

  defp expand_node(node, _opts), do: [node]

  defp plain_text(%{literal: literal}) when is_binary(literal), do: literal
  defp plain_text(%{nodes: nodes}) when is_list(nodes), do: Enum.map_join(nodes, &plain_text/1)
  defp plain_text(_), do: ""

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

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

  @mention ~r/(?<![\w@\/])@([a-zA-Z][\w.\-]{0,62})/

  @doc "Whether `text` has an `@mention` in it that `render/2` would look up."
  def mentions?(nil), do: false
  def mentions?(text) when is_binary(text), do: Regex.match?(@mention, text)

  defp mentions(html, nil, _members), do: html

  defp mentions(html, board, members) do
    if Regex.match?(@mention, html) do
      members = members || Slipdock.Wiki.Links.members(board)

      # Only the text between tags, and not a link's own text: an "@" in a
      # URL is part of the address, not a person.
      ~r/<a\s[^>]*>.*?<\/a>|<[^>]+>/s
      |> Regex.split(html, include_captures: true)
      |> Enum.map_join(fn
        "<" <> _ = tag -> tag
        text -> Regex.replace(@mention, text, &mention(&1, &2, members))
      end)
    else
      html
    end
  end

  defp mention(whole, name, members) do
    # "@david." ends a sentence: the dot is not part of the name.
    trimmed = name |> String.trim_trailing(".") |> String.trim_trailing("-")
    rest = binary_part(name, byte_size(trimmed), byte_size(name) - byte_size(trimmed))

    case Slipdock.Mentions.find(members, trimmed) do
      nil ->
        whole

      user ->
        title =
          (user.name || user.email) |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

        ~s|<span class="badge badge-sm badge-primary badge-soft align-baseline" title="#{title}">@#{trimmed}</span>| <>
          rest
    end
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
    if safe_url?(url), do: image(url, alt), else: whole
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

  defp link(url, text), do: link_open(url) <> text <> "</a>"

  defp link_open(url),
    do:
      ~s|<a href="#{url}" target="_blank" rel="noopener" class="link link-primary break-all" onclick="event.stopPropagation()">|

  defp image(url, alt),
    do:
      ~s|<a href="#{url}" target="_blank" rel="noopener" class="inline-block" onclick="event.stopPropagation()"><img src="#{url}" alt="#{alt}" loading="lazy" class="my-1 max-h-96 max-w-full rounded-lg border border-base-content/10" /></a>|

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
