defmodule SlipdockWeb.Wiki.Renderer do
  @moduledoc """
  Turns a page's Markdown into HTML fit to put on a screen.

  CommonMark plus the GitHub extensions people actually write — tables,
  task lists, strikethrough, autolinks, footnotes — parsed by comrak
  (`:mdex`), then the wiki's own syntax (`Slipdock.Wiki.Markup`) is applied to
  the **text nodes of the parsed tree**, and only then is the whole thing
  rendered and sanitised.

  Working on the tree rather than on the source is what makes
  `` `[[not a link]]` `` stay what it says: a code span is a different node,
  so the substitution never reaches it. Working on the tree rather than on
  the output HTML is what stops a `[[link]]` inside a rendered `<code>` block
  being rewritten after the fact.

  Raw HTML is *rendered* and then sanitised rather than dropped outright, so
  the chips and callouts this module injects survive while anything dangerous
  does not. The sanitiser is therefore load-bearing: `<script>`, event
  handlers and `javascript:` URLs never reach the page, whoever wrote them.

  `SlipdockWeb.Markdown` still renders assistant replies. It is eighty lines of
  regex for paragraphs, lists and bold, which is the right size for that job
  and the wrong size for this one.
  """

  require Logger

  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Drawings, Embeds, Excalidraw, Links, Markup, Meld, Page, Query, Section}

  @extension [
    table: true,
    tasklist: true,
    strikethrough: true,
    autolink: true,
    footnotes: true,
    header_id_prefix: ""
  ]

  # Raw HTML is rendered so the chips below survive; the sanitiser decides
  # what any of it is allowed to be. A single newline is a line break, as it
  # is in Obsidian, where most of these pages are written: a list of dates
  # one per line should not run together into one paragraph.
  @render [unsafe: true, hardbreaks: true]

  @sanitize [
    add_tags: ["input"],
    add_tag_attributes: %{
      "input" => ["type", "checked", "disabled"],
      "a" => ["title", "data-seek-ms"],
      "span" => ["title", "role", "tabindex", "data-meld-block", "data-tag", "data-seek-ms"],
      # A transcript's turns carry their times for the player (W-1690).
      "article" => ["data-transcript"],
      "li" => ["data-speaker", "data-start-ms", "data-end-ms"]
    },
    add_generic_attributes: ["id", "class"]
  ]

  @doc """
  The page's body as HTML, ready for `Phoenix.HTML.raw/1`.

  Options:

    * `:page` — the page being rendered, needed for `[[!toc]]`,
      `[[!children]]` and `[[!backlinks]]`
    * `:board` — the board unqualified references are read against; taken
      from the page when one is given
    * `:as` — the reader. A card chip, page link or view link they cannot
      open degrades to plain text rather than telling them it exists.
    * `:static` — true to render links as plain text (published pages, where
      there is nobody to have permissions)
    * `:shared` — true for a page read through a share (#817): pages link to
      the share's own view, and a link to anything the reader can't open
      reads "a page you can't see" rather than naming it or its board

  A body that cannot be parsed comes back as escaped plain text rather than
  an error page: a document is worth more half-rendered than not at all.
  """
  def to_html(body, opts \\ [])

  def to_html(body, opts) when is_binary(body) do
    context =
      context(opts)
      |> Map.put(:transcript_tags, Slipdock.Wiki.TranscriptTags.parse(body))
      |> Map.put(:transcript?, Regex.match?(~r/^[ \t]*(`{3,}|~{3,})[ \t]*vtt[ \t]*$/m, body))

    # Extensions belong on the *parse*, not just the render: a pipe table is
    # only a table if the parser was told tables exist. Each link resolves on
    # its own, so a vault's index is built once for the page, not per link.
    Slipdock.Vaults.Index.cached(fn ->
      with {:ok, doc} <- MDEx.parse_document(body, extension: @extension),
           {:ok, html} <-
             doc
             |> expand(context)
             |> MDEx.to_html(extension: @extension, render: @render, sanitize: @sanitize) do
        html
      else
        _ -> "<pre>" <> escape(body) <> "</pre>"
      end
    end)
  rescue
    # Resolving references reads cards, pages and links as they stand now,
    # and a reference the code did not foresee should cost the reader the
    # live parts of one page, not the page. Logged, because it is a bug.
    exception ->
      Logger.error(
        "Wiki page failed to render: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      ~s|<div class="wiki-query-error"><p class="wiki-query-error-message">| <>
        "Part of this page could not be drawn, so here it is as written. The error has been logged." <>
        "</p><pre>" <> escape(body) <> "</pre></div>"
  end

  def to_html(_, _), do: ""

  @doc """
  The body with every reference resolved to Markdown rather than HTML — what
  `GET /api/pages/:id/render` returns, so an agent reading a document full of
  references gets the answers and not the syntax.
  """
  def to_markdown(body, opts \\ [])

  def to_markdown(body, opts) when is_binary(body) do
    context = context(opts)

    # A drawing reads as the words in it, not as its compressed scene.
    body =
      if Excalidraw.page?(context.page), do: Excalidraw.readable(body), else: body

    body
    |> String.split("\n")
    |> resolve_lines(context, [], nil)
    |> Enum.join("\n")
  end

  def to_markdown(_, _), do: ""

  # Line by line, except that a fenced ```slipdock block (or one of its
  # pre-rename spellings) is gathered whole and
  # answered as a Markdown table — which is the point of `render`: an agent
  # reading a document wants the answers, not the query.
  defp resolve_lines([], _context, done, nil), do: Enum.reverse(done)

  defp resolve_lines([], context, done, {_fence, collected}),
    do: Enum.reverse([query_markdown(Enum.join(Enum.reverse(collected), "\n"), context) | done])

  defp resolve_lines([line | rest], context, done, nil) do
    case Regex.run(~r/^\s*(`{3,}|~{3,})\s*(slipdock|kanban)(-query)?\s*$/, line) do
      [_, fence | _] -> resolve_lines(rest, context, done, {fence, []})
      _ -> resolve_lines(rest, context, [resolve_line(line, context) | done], nil)
    end
  end

  defp resolve_lines([line | rest], context, done, {fence, collected}) do
    if String.starts_with?(String.trim(line), fence) do
      answered = query_markdown(Enum.join(Enum.reverse(collected), "\n"), context)
      resolve_lines(rest, context, [answered | done], nil)
    else
      resolve_lines(rest, context, done, {fence, [line | collected]})
    end
  end

  defp query_markdown(source, context) do
    case answer(source, context) do
      {:ok, result} ->
        result_markdown(result)

      {:error, message} ->
        "> **This query could not be answered:** #{message}\n>\n> ```\n> #{String.trim(source)}\n> ```"
    end
  end

  defp result_markdown(%{kind: :count, count: count}), do: to_string(count)

  defp result_markdown(%{kind: :progress} = result),
    do:
      "#{result.done} of #{result.total} done (#{result.percent}%)#{if result[:label], do: " — #{result.label}"}"

  defp result_markdown(%{kind: :list, cards: []} = result), do: empty_markdown(result)

  defp result_markdown(%{kind: :list, cards: cards}),
    do: Enum.map_join(cards, "\n", &"- #{&1.title} (##{&1.id})")

  defp result_markdown(%{kind: :groups, groups: []} = result), do: empty_markdown(result)

  defp result_markdown(%{kind: :groups, groups: groups}) do
    Enum.map_join(groups, "\n\n", fn group ->
      heading = if group.label, do: "**#{group.label}**\n", else: ""
      heading <> Enum.map_join(group.cards, "\n", &"- #{&1.title} (##{&1.id})")
    end)
  end

  defp result_markdown(%{kind: :table, rows: []} = result), do: empty_markdown(result)

  defp result_markdown(%{kind: :table} = result) do
    header = "| " <> Enum.join(result.headers, " | ") <> " |"
    rule = "|" <> String.duplicate("---|", length(result.headers))

    rows =
      Enum.map_join(result.rows, "\n", fn row ->
        "| " <> Enum.map_join(row.cells, " | ", &escape_cell/1) <> " |"
      end)

    Enum.join([header, rule, rows], "\n")
  end

  defp result_markdown(_result), do: ""

  defp empty_markdown(%{empty: message}) when is_binary(message) and message != "", do: message
  defp empty_markdown(_result), do: "_No cards match._"

  defp escape_cell(text), do: text |> to_string() |> String.replace("|", "\\|")

  defp resolve_line(line, context) do
    line
    |> Markup.tokens()
    |> Enum.map_join(fn
      {:text, text} -> text
      {:ref, ref} -> markdown_for(ref, context)
    end)
  end

  defp markdown_for(%{kind: :inline} = ref, context) do
    case inline_answer(ref, context) do
      {:ok, text} -> text
      :error -> ref.raw
    end
  end

  defp markdown_for(%{kind: :page, target: "", anchor: anchor} = ref, _context),
    do: "[#{ref.label || anchor}](##{anchor_id(anchor)})"

  # An agent reading a page wants what an embed shows, not where it points:
  # the embedded text, quoted, under the name of where it came from.
  defp markdown_for(%{embed: true} = ref, context) do
    with false <- file_embed?(ref),
         {:page, page} <- resolve_one(ref, context),
         {:ok, source} <- embed_source(page, Map.get(ref, :anchor)) do
      quoted =
        source |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("> " <> &1))

      "\n> **[#{ref.label || link_text(page, ref)}](#{page_path(page)}#{fragment(ref)})**\n>\n" <>
        quoted <> "\n"
    else
      _ -> ref.raw
    end
  end

  defp markdown_for(ref, context) do
    case resolve_one(ref, context) do
      {:page, page} ->
        "[#{ref.label || link_text(page, ref)}](#{page_path(page)}#{fragment(ref)})"

      {:card, card} ->
        "#{ref.label || card.title} (##{card.id}#{card_meta(card)})"

      {:board, board} ->
        "[#{ref.label || board.name}](/boards/#{board.id})"

      {:view, view} ->
        "[#{ref.label || view.name}](/boards/#{view.board_id}?view=#{view.id})"

      {:mention, user} ->
        "@#{Wiki.author_name(user)}"

      {:directive, name} ->
        directive_markdown(name, context)

      _ ->
        ref.label || strip_brackets(ref.raw)
    end
  end

  ## Context ------------------------------------------------------------------

  defp context(opts) do
    page = Keyword.get(opts, :page)

    board =
      Keyword.get(opts, :board) ||
        case page do
          %Page{} = p -> Wiki.board_of(p)
          _ -> nil
        end

    %{
      page: page,
      board: board,
      reader: Keyword.get(opts, :as),
      today: Keyword.get(opts, :today, Date.utc_today()),
      static: Keyword.get(opts, :static, false),
      shared: Keyword.get(opts, :shared, false),
      # The pages being embedded on the way here, so an embed cannot embed
      # its way round in a circle (see `embed_html/3`).
      embedding: Keyword.get(opts, :embedding, []),
      # A published page answers its queries as of the moment it was
      # published: there is nobody on the other side to have permissions, so
      # a live query would be a way to read private cards from the open web.
      frozen: Keyword.get(opts, :frozen)
    }
  end

  defp resolve_one(_ref, %{board: nil}), do: nil

  defp resolve_one(ref, context) do
    [resolution] =
      Links.resolve(context.board, [Map.put(ref, :count, 1)],
        as: context.reader,
        from: context.page
      )

    resolution.to
  end

  ## Tree rewriting -----------------------------------------------------------

  defp expand(%MDEx.Document{nodes: nodes} = doc, context),
    do: %{doc | nodes: expand_list(nodes, context)}

  defp expand_list(nodes, context), do: Enum.flat_map(nodes, &expand_node(&1, context))

  defp expand_node(%MDEx.Paragraph{nodes: [%MDEx.Text{literal: text}]} = node, context) do
    # A meeting summary's `Tags:` line: each tag a link to its moment in the
    # transcript (#787), when there is one to go to.
    with true <- context.transcript_tags != [] and context.transcript?,
         {:ok, html} <- Slipdock.Wiki.TranscriptTags.line_html(text) do
      [html_block(html)]
    else
      _ -> paragraph(node, text, context)
    end
  end

  # A fenced ```slipdock block is a live query. It is a block, not a phrase, so
  # it replaces the code block rather than living inside one. `kanban` and
  # `kanban-query` are the pre-rename spellings and keep working forever —
  # they are written into people's pages, and a rename of ours is no reason
  # to break a document somebody wrote.
  defp expand_node(%MDEx.CodeBlock{info: info, literal: source}, context)
       when info in ["slipdock", "slipdock-query", "kanban", "kanban-query"] do
    [html_block(query_html(source, context))]
  end

  # A fenced ```vtt block is a transcript (W-1690): a meeting page carries its
  # WebVTT whole, and it reads as the conversation a .vtt file does.
  # The page's timed tags (#785) are drawn in it where they were pressed.
  defp expand_node(%MDEx.CodeBlock{info: "vtt", literal: source}, context),
    do: [html_block(SlipdockWeb.TranscriptView.block_html(source, context.transcript_tags))]

  defp expand_node(%MDEx.Text{literal: text}, context), do: text_nodes(text, context)

  defp expand_node(%{nodes: children} = node, context) when is_list(children),
    do: [%{node | nodes: expand_list(children, context)}]

  defp expand_node(node, _context), do: [node]

  # A paragraph that is nothing but a directive becomes a block of its own:
  # a table of contents does not belong inside a <p>.
  defp paragraph(node, text, context) do
    case Markup.tokens(String.trim(text)) do
      [{:ref, %{kind: :directive} = ref}] -> [html_block(directive_html(ref.target, context))]
      # A paragraph that is only `![[Note]]` becomes the note, as a block.
      [{:ref, %{embed: true} = ref}] -> [html_block(embed_html(ref, context))]
      _ -> [%{node | nodes: expand_list(node.nodes, context)}]
    end
  end

  defp text_nodes(text, context) do
    {text, block} = block_id(text)

    Meld.inline()
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.flat_map(fn piece ->
      case Meld.blocks(piece) do
        [%{text: ^piece} = meld] ->
          [meld_node(meld)]

        _ ->
          piece
          |> Markup.tokens()
          |> Enum.map(fn
            {:text, literal} -> %MDEx.Text{literal: literal}
            {:ref, ref} -> ref_node(ref, context)
          end)
      end
    end)
    |> Kernel.++(block_anchor(block))
  end

  # A Meld Encrypt block is drawn locked, carrying its ciphertext for the
  # browser to decrypt (assets/js/meld_view.js). The server only ever has the
  # ciphertext, so that is all there is to put here.
  defp meld_node(meld) do
    hint =
      if meld.hint == "", do: "", else: ~s| <span class="meld-hint">#{escape(meld.hint)}</span>|

    %MDEx.HtmlInline{
      literal:
        ~s|<span class="meld-locked" role="button" tabindex="0" title="Encrypted. Select to decrypt in this browser" | <>
          ~s|data-meld-block="#{escape(meld.text)}">🔒 Encrypted#{hint}</span>|
    }
  end

  # Obsidian's block id: ` ^a1b2` at the end of a paragraph or list item. It
  # is an address, not prose, so it is not shown; `[[Note#^a1b2]]` lands on it.
  defp block_id(text) do
    case Regex.run(~r/\A(.*?)\s+\^([A-Za-z0-9-]+)\s*\z/s, text, capture: :all_but_first) do
      [before, id] -> {before, id}
      _ -> {text, nil}
    end
  end

  defp block_anchor(nil), do: []

  defp block_anchor(id),
    do: [
      %MDEx.HtmlInline{literal: ~s|<span id="^#{escape(id)}" class="wiki-block-anchor"></span>|}
    ]

  defp ref_node(%{kind: :inline} = ref, context) do
    case inline_answer(ref, context) do
      {:ok, text} ->
        %MDEx.HtmlInline{literal: ~s|<span class="wiki-inline">#{escape(text)}</span>|}

      :error ->
        %MDEx.Text{literal: ref.raw}
    end
  end

  # `[[#Heading]]`: a place on this page, which needs no looking up.
  defp ref_node(%{kind: :page, target: "", anchor: anchor} = ref, context) do
    if context.static do
      %MDEx.Text{literal: ref.label || anchor}
    else
      %MDEx.HtmlInline{
        literal:
          ~s|<a href="##{escape(anchor_id(anchor))}" class="wiki-link">| <>
            escape(ref.label || anchor) <> "</a>"
      }
    end
  end

  # `![[photo.png]]` in the middle of a sentence: the file, inline.
  defp ref_node(%{embed: true} = ref, context) do
    cond do
      context.static ->
        published_inline(ref, context) || ref_node(Map.delete(ref, :embed), context)

      drawing = drawing_html(ref, context) ->
        %MDEx.HtmlInline{literal: drawing}

      file_embed?(ref) ->
        %MDEx.HtmlInline{literal: file_inline(ref, context)}

      true ->
        ref_node(Map.delete(ref, :embed), context)
    end
  end

  defp ref_node(ref, context) do
    case resolve_one(ref, context) do
      nil -> unresolved_node(ref, context)
      target -> %MDEx.HtmlInline{literal: resolved_html(ref, target, context)}
    end
  end

  # A published page's inline answers were worked out when it was published.
  defp inline_answer(%{target: expression}, %{frozen: %{} = frozen}),
    do: Map.fetch(frozen, expression)

  defp inline_answer(%{target: expression}, context), do: Query.inline(expression, context)

  ## What each kind of reference draws ----------------------------------------

  defp resolved_html(_ref, {:directive, name}, context),
    do: directive_html(name, context)

  # Published pages have nobody behind them to have permissions, so nothing
  # is followable: a reference is named, not linked.
  defp resolved_html(ref, _target, %{static: true}),
    do: ~s|<span class="wiki-static">#{escape(ref.label || strip_brackets(ref.raw))}</span>|

  defp resolved_html(ref, {:page, page}, context) do
    ~s|<a href="#{page_href(page, context)}#{fragment(ref)}" class="wiki-link" title="#{escape(page.code)}">| <>
      escape(ref.label || link_text(page, ref)) <> "</a>"
  end

  # `[[Report.pdf]]`: a file in the wiki, linked.
  defp resolved_html(ref, {:file, file}, _context) do
    ~s|<a class="wiki-file-link" href="#{escape(Slipdock.Wiki.Files.open_path(file))}">| <>
      escape(ref.label || file.name) <> "</a>"
  end

  # A card is drawn live — title, list and state read at render time — so a
  # renamed or finished card is never stale in somebody's prose.
  defp resolved_html(ref, {:card, card}, _context) do
    classes = ["wiki-chip", card.completed && "wiki-chip-done"] |> Enum.filter(& &1)

    ~s|<a href="/boards/#{card.board_id}/cards/#{card.id}" class="#{Enum.join(classes, " ")}" title="#{escape(card.title)}">| <>
      ~s|<span class="wiki-chip-id">##{card.id}</span>| <>
      ~s|<span class="wiki-chip-title">#{escape(ref.label || card.title)}</span>| <>
      card_meta_html(card) <>
      "</a>"
  end

  defp resolved_html(ref, {:board, board}, _context),
    do:
      ~s|<a href="/boards/#{board.id}" class="wiki-link wiki-link-board">| <>
        escape(ref.label || board.name) <> "</a>"

  defp resolved_html(ref, {:view, view}, _context),
    do:
      ~s|<a href="/boards/#{view.board_id}?view=#{view.id}" class="wiki-link wiki-link-view">| <>
        escape(ref.label || view.name) <> "</a>"

  defp resolved_html(_ref, {:mention, user}, _context),
    do:
      ~s|<span class="wiki-mention" title="#{escape(user.email)}">@#{escape(Wiki.author_name(user))}</span>|

  # A `[[wanted page]]` is the classic way a wiki grows: it reads differently
  # and offers to become a page, carrying its title through. A bare `#412`
  # that matches no card stays literal, so "#1 priority" survives.
  defp unresolved_node(%{kind: :page} = ref, %{static: true}),
    do: %MDEx.Text{literal: ref.label || strip_brackets(ref.raw)}

  # Read through a share, a link the reader can't follow names nothing: not
  # the page, not whether it exists, not the board it would be on (#817).
  defp unresolved_node(%{kind: kind}, %{shared: true}) when kind in [:page, :card, :board, :view],
    do: %MDEx.HtmlInline{literal: ~s|<span class="wiki-hidden-link">#{hidden_label(kind)}</span>|}

  defp unresolved_node(%{kind: :page} = ref, context) do
    if String.starts_with?(ref.raw, "[[") and context.board do
      title = ref.label || ref.target
      href = "/boards/#{context.board.id}/wiki/new?title=#{URI.encode_www_form(ref.target)}"

      %MDEx.HtmlInline{
        literal:
          ~s|<a href="#{href}" class="wiki-link wiki-wanted" title="This page has not been written yet">| <>
            escape(title) <> "</a>"
      }
    else
      %MDEx.Text{literal: ref.raw}
    end
  end

  defp unresolved_node(ref, _context), do: %MDEx.Text{literal: ref.raw}

  defp hidden_label(:card), do: "a card you can't see"
  defp hidden_label(_), do: "a page you can't see"

  # Where a page link goes: its board's wiki, or the share's view of it.
  defp page_href(%Page{id: id}, %{shared: true}), do: "/shared/pages/#{id}"
  defp page_href(page, _context), do: page_path(page)

  ## Directives ---------------------------------------------------------------

  defp directive_html("toc", %{page: %Page{} = page}) do
    case Section.headings(page.body) do
      [] ->
        ""

      headings ->
        items =
          Enum.map_join(headings, "", fn heading ->
            ~s|<li class="wiki-toc-#{heading.level}"><a href="##{anchor(heading.title)}">| <>
              escape(heading.title) <> "</a></li>"
          end)

        ~s|<nav class="wiki-toc"><p class="wiki-toc-title">On this page</p><ul>#{items}</ul></nav>|
    end
  end

  defp directive_html("children", %{page: %Page{} = page} = context) do
    case page |> Wiki.children() |> readable_children(context.reader) do
      [] ->
        ~s|<p class="wiki-empty">No pages under this one yet.</p>|

      children ->
        items =
          Enum.map_join(children, "", fn child ->
            summary =
              case child.summary do
                nil -> ""
                "" -> ""
                text -> ~s| <span class="wiki-list-summary">#{escape(text)}</span>|
              end

            ~s|<li><a href="#{page_href(child, context)}" class="wiki-link">#{escape(child.title)}</a>#{summary}</li>|
          end)

        ~s|<ul class="wiki-children">#{items}</ul>|
    end
  end

  defp directive_html("backlinks", %{page: %Page{} = page, reader: reader} = context) do
    case Links.backlinks(page, reader) do
      [] ->
        ~s|<p class="wiki-empty">Nothing links here yet.</p>|

      links ->
        items =
          Enum.map_join(links, "", fn link ->
            {path, title} = backlink_source(link)
            path = if context.shared, do: shared_backlink(link, path), else: path
            ~s|<li><a href="#{path}" class="wiki-link">#{escape(title)}</a></li>|
          end)

        ~s|<ul class="wiki-backlinks">#{items}</ul>|
    end
  end

  defp directive_html(_name, _context), do: ""

  # A child can be filed somewhere its parent's reader can't go.
  defp readable_children(children, nil), do: children

  defp readable_children(children, reader),
    do: Enum.filter(children, &Wiki.visible?(&1, Slipdock.Access.page_permission(reader, &1)))

  defp shared_backlink(%{page: %Page{id: id}}, _path), do: "/shared/pages/#{id}"
  defp shared_backlink(_link, path), do: path

  defp directive_markdown("toc", %{page: %Page{} = page}) do
    page.body
    |> Section.headings()
    |> Enum.map_join("\n", &(String.duplicate("  ", &1.level - 1) <> "- " <> &1.title))
  end

  defp directive_markdown("children", %{page: %Page{} = page} = context) do
    page
    |> Wiki.children()
    |> readable_children(context.reader)
    |> Enum.map_join("\n", fn child ->
      "- [#{child.title}](#{page_path(child)})#{if child.summary, do: " — #{child.summary}"}"
    end)
  end

  defp directive_markdown("backlinks", %{page: %Page{} = page, reader: reader}) do
    page
    |> Links.backlinks(reader)
    |> Enum.map_join("\n", fn link ->
      {path, title} = backlink_source(link)
      "- [#{title}](#{path})"
    end)
  end

  defp directive_markdown(_name, _context), do: ""

  @doc """
  Where a backlink was written, as `{path, title}`. That is a page, or a card
  whose description or comment names the page — so `link.page` can be nil.
  """
  def backlink_source(%{page: %Page{} = page}), do: {page_path(page), page.title}

  def backlink_source(%{source_card: %Card{} = card}),
    do: {"/boards/#{card.board_id}/cards/#{card.id}", "##{card.id} #{card.title}"}

  ## Query blocks -------------------------------------------------------------

  defp query_html(source, context) do
    case answer(source, context) do
      {:ok, result} -> result_html(result, context)
      {:error, message} -> query_error_html(message, source)
    end
  end

  # A published page's blocks were answered when it was published; a live one
  # answers now, with the reader's own permissions.
  defp answer(source, %{frozen: %{} = frozen} = _context) do
    case Map.fetch(frozen, String.trim(source)) do
      {:ok, result} -> {:ok, atomize(result)}
      :error -> {:error, "this query was not answered when the page was published"}
    end
  end

  defp answer(source, context) do
    with {:ok, query} <- Query.parse(source) do
      Query.run(query, context)
    end
  end

  # A published page's frozen answers come back from JSON with string keys —
  # and a string `kind`, which the clauses below match as an atom. Both have
  # to be put back, or a frozen block renders as nothing at all.
  defp atomize(%{kind: kind} = result) when is_atom(kind), do: result

  defp atomize(%{} = result) do
    result
    |> Map.new(fn {k, v} ->
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, if(is_map(v) or is_list(v), do: atomize_deep(v), else: v)}
    end)
    |> then(fn
      %{kind: kind} = map when is_binary(kind) -> %{map | kind: String.to_existing_atom(kind)}
      map -> map
    end)
  end

  defp atomize_deep(list) when is_list(list), do: Enum.map(list, &atomize_deep/1)
  defp atomize_deep(%{} = map), do: atomize(map)
  defp atomize_deep(other), do: other

  # An unparseable block is a note on the page, never a broken page: a
  # document with one bad query is still worth reading.
  defp query_error_html(message, source) do
    ~s|<div class="wiki-query-error"><p class="wiki-query-error-message">| <>
      escape(message) <>
      ~s|</p><pre><code>| <> escape(String.trim(source)) <> "</code></pre></div>"
  end

  defp result_html(%{kind: :count, count: count}, _context),
    do:
      ~s|<p class="wiki-query-count"><span class="wiki-query-number">#{count}</span> #{plural(count, "card")}</p>|

  defp result_html(%{kind: :progress} = result, _context) do
    label =
      if result[:label],
        do: ~s|<span class="wiki-progress-label">#{escape(result.label)}</span>|,
        else: ""

    label <>
      ~s|<div class="wiki-progress"><div class="wiki-progress-bar" style="width: #{result.percent}%"></div></div>| <>
      ~s|<p class="wiki-progress-text">#{result.done} of #{result.total} done (#{result.percent}%)</p>|
  end

  defp result_html(%{kind: :list, cards: []} = result, _context), do: empty_html(result)

  defp result_html(%{kind: :list, cards: cards}, context) do
    items = Enum.map_join(cards, "", &~s|<li>#{card_link_html(&1, context)}</li>|)
    ~s|<ul class="wiki-query-list">#{items}</ul>|
  end

  defp result_html(%{kind: :groups, groups: []} = result, _context), do: empty_html(result)

  defp result_html(%{kind: :groups, groups: groups}, context) do
    Enum.map_join(groups, "", fn group ->
      heading =
        if group.label,
          do:
            ~s|<p class="wiki-query-group">#{escape(group.label)} <span class="wiki-query-group-count">#{length(group.cards)}</span></p>|,
          else: ""

      heading <>
        ~s|<ul class="wiki-query-list">| <>
        Enum.map_join(group.cards, "", &~s|<li>#{card_link_html(&1, context)}</li>|) <>
        "</ul>"
    end)
  end

  defp result_html(%{kind: :table, rows: []} = result, _context), do: empty_html(result)

  defp result_html(%{kind: :table} = result, context) do
    head =
      Enum.map_join(result.headers, "", &~s|<th>#{escape(&1)}</th>|)

    body =
      Enum.map_join(result.rows, "", fn row ->
        cells =
          result.keys
          |> Enum.zip(row.cells)
          |> Enum.map_join("", fn
            {"title", _text} -> ~s|<td>#{card_link_html(row.card, context)}</td>|
            {_key, text} -> ~s|<td>#{escape(text)}</td>|
          end)

        "<tr>#{cells}</tr>"
      end)

    ~s|<div class="wiki-query-table"><table><thead><tr>#{head}</tr></thead><tbody>#{body}</tbody></table></div>|
  end

  defp result_html(_result, _context), do: ""

  defp empty_html(%{empty: message}) when is_binary(message) and message != "",
    do: ~s|<p class="wiki-empty">#{escape(message)}</p>|

  defp empty_html(_result), do: ~s|<p class="wiki-empty">No cards match.</p>|

  # In a published page there is nobody to follow a link, so cards are named
  # rather than linked.
  defp card_link_html(card, %{static: true}), do: escape(card_text(card))

  defp card_link_html(card, _context) do
    ~s|<a href="/boards/#{card.board_id}/cards/#{card.id}" class="wiki-query-card#{if card.completed, do: " wiki-chip-done"}">| <>
      escape(card_text(card)) <> "</a>"
  end

  defp card_text(card), do: card.title

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  ## Bits and pieces ----------------------------------------------------------

  defp card_meta_html(%Card{} = card) do
    parts =
      [column_name(card), card.completed && "done"]
      |> Enum.filter(& &1)
      |> Enum.map(&escape/1)

    case parts do
      [] -> ""
      _ -> ~s|<span class="wiki-chip-meta">#{Enum.join(parts, " · ")}</span>|
    end
  end

  defp card_meta(%Card{} = card) do
    case column_name(card) do
      nil -> ""
      name -> ", #{name}#{if card.completed, do: ", done"}"
    end
  end

  defp column_name(%Card{column: %Column{name: name}}), do: name
  defp column_name(_), do: nil

  @doc "Where a page lives, as a path."
  def page_path(%Page{} = page), do: "/boards/#{page.board_id}/wiki/#{page.slug}"

  # `[[Note#Heading]]` reads "Note › Heading", as Obsidian shows it.
  defp link_text(page, %{anchor: anchor}) when is_binary(anchor),
    do: page.title <> " › " <> anchor

  defp link_text(page, _ref), do: page.title

  defp fragment(%{anchor: anchor}) when is_binary(anchor), do: "#" <> escape(anchor_id(anchor))
  defp fragment(_ref), do: ""

  # A heading's anchor is the id comrak gives it; a block's is `^id`, as
  # `block_anchor/1` writes it.
  defp anchor_id("^" <> _ = block), do: block
  defp anchor_id(heading), do: anchor(heading)

  ## Embeds -------------------------------------------------------------------

  # `![[Note]]`, `![[Note#Heading]]` or `![[Note#^block]]`: the page, the
  # section under that heading, or the block, drawn in place for this reader.
  # One level deep and never round in a circle — past that, and for anything
  # that is not a page, it is a link. A published page names what it embeds
  # rather than showing it: nobody is behind it to have permissions. The
  # one exception is an image the page embeds (#1166), which is part of the
  # page and is served through its link (`Embeds.published_url/2`).
  @max_embed_depth 2

  defp embed_html(ref, %{static: true} = context) do
    case published_inline(ref, context) do
      nil ->
        ~s|<p><span class="wiki-static">#{escape(ref.label || strip_brackets(ref.raw))}</span></p>|

      img ->
        "<p>" <> img <> "</p>"
    end
  end

  defp embed_html(ref, context) do
    seen = Enum.reject([context.page && context.page.id | context.embedding], &is_nil/1)

    drawing = drawing_html(ref, context)

    cond do
      drawing -> "<p>" <> drawing <> "</p>"
      file_embed?(ref) -> file_html(ref, context)
      true -> page_embed_html(ref, context, seen)
    end
  end

  # `![[photo.png]]` on a published page: the image, through the page's
  # link, when the page vouches for it (`Embeds.published?/2`). Nil for
  # anything else, which stays a name.
  defp published_inline(ref, %{
         page: %Page{public_token: token} = page,
         board: %Slipdock.Boards.Board{} = board
       })
       when is_binary(token) do
    with true <- file_embed?(ref),
         %Slipdock.Wiki.WikiFile{} = file <- Slipdock.Wiki.Files.find(board, ref.target, nil),
         true <- Embeds.published?(page, file) do
      label = escape(ref.label || file.name)

      ~s|<img class="wiki-file-embed" src="#{escape(Embeds.published_url(file, page))}" alt="#{label}">|
    else
      _ -> nil
    end
  end

  defp published_inline(_ref, _context), do: nil

  defp page_embed_html(ref, context, seen) do
    case resolve_one(ref, context) do
      {:page, page} ->
        with false <- page.id in seen or length(seen) >= @max_embed_depth,
             {:ok, source} <- embed_source(page, Map.get(ref, :anchor)) do
          inner =
            to_html(source,
              page: page,
              as: context.reader,
              embedding: seen,
              today: context.today
            )

          ~s|<div class="wiki-embed">| <>
            ~s|<div class="wiki-embed-title">#{resolved_html(ref, {:page, page}, context)}</div>| <>
            inner <> "</div>"
        else
          _ -> "<p>" <> resolved_html(ref, {:page, page}, context) <> "</p>"
        end

      _ ->
        html_of_nodes([unresolved_node(ref, context)])
    end
  end

  # `![[sketch.excalidraw]]` or `![[sketch.excalidraw.md]]`: the drawing's
  # preview, an SVG made on the server (W-103 R5.1) and shown as an image,
  # so it never passes through the sanitiser and cannot run anything. It
  # opens the drawing. Nil when the target is not a drawing this reader has.
  defp drawing_html(%{target: target} = ref, %{board: %Slipdock.Boards.Board{} = board} = context) do
    with true <- Excalidraw.name?(target),
         {_kind, drawing} = found <- Drawings.resolve(board, target, context.reader) do
      label = escape(ref.label || target)

      ~s|<a class="wiki-drawing" href="#{escape(drawing_href(found))}" title="#{label}">| <>
        ~s|<img class="wiki-drawing-preview" src="#{escape(Drawings.preview_url(drawing))}" alt="#{label}"></a>|
    else
      # A drawing, but not one the reader has: maybe through the page.
      nil -> drawing_through_page(ref, context)
      _ -> nil
    end
  end

  defp drawing_html(_ref, _context), do: nil

  defp drawing_href({:page, page}), do: page_path(page)
  defp drawing_href({:file, file}), do: "/drawings/file/#{file.id}"

  # `![[diagram.png]]`: a file in the wiki (W-103 R2.9), drawn in place when
  # it is an image the browser may show, linked when it is anything else, and
  # left exactly as written when there is no such file.
  defp file_html(ref, context), do: "<p>" <> file_inline(ref, context) <> "</p>"

  defp file_inline(ref, %{board: %Slipdock.Boards.Board{} = board} = context) do
    case Slipdock.Wiki.Files.resolve(board, ref.target, context.reader) do
      nil ->
        through_page(ref, context) || escape(ref.raw)

      file ->
        file_tag(ref, file, Slipdock.Wiki.Files.url(file), Slipdock.Wiki.Files.open_path(file))
    end
  end

  defp file_inline(ref, _context), do: escape(ref.raw)

  defp file_tag(ref, file, url, href) do
    label = escape(ref.label || file.name)

    if Slipdock.Wiki.WikiFile.image?(file),
      do: ~s|<img class="wiki-file-embed" src="#{escape(url)}" alt="#{label}">|,
      else: ~s|<a class="wiki-file-link" href="#{escape(href)}">#{label}</a>|
  end

  # A file the reader can't see on their own, embedded in a page they can
  # read — a page shared with them (#832). Sharing the page shares what it
  # embeds, served through the page (`Slipdock.Wiki.Embeds`): an image or a
  # drawing's preview in place, anything else as a download.
  defp through_page(ref, context) do
    case embedded_file(ref, context) do
      {file, page} ->
        url = Embeds.url(file, page)
        file_tag(ref, file, url, url)

      nil ->
        nil
    end
  end

  # A `.excalidraw` file drawing the same way: its preview, not linked, since
  # the editor is the board's.
  defp drawing_through_page(ref, context) do
    case embedded_file(ref, context) do
      {file, page} ->
        label = escape(ref.label || ref.target)
        src = escape(Drawings.preview_url(file) <> "&page=#{page.id}")

        ~s|<span class="wiki-drawing" title="#{label}">| <>
          ~s|<img class="wiki-drawing-preview" src="#{src}" alt="#{label}"></span>|

      nil ->
        nil
    end
  end

  defp embedded_file(ref, %{page: %Page{} = page, reader: %Slipdock.Accounts.User{}} = context) do
    with %Slipdock.Wiki.WikiFile{} = file <-
           Slipdock.Wiki.Files.find(context.board, ref.target, nil),
         true <- Embeds.vouched?(page, file) do
      {file, page}
    else
      _ -> nil
    end
  end

  defp embedded_file(_ref, _context), do: nil

  defp html_of_nodes(nodes) do
    paragraph = %MDEx.Document{nodes: [%MDEx.Paragraph{nodes: nodes}]}

    case MDEx.to_html(paragraph, extension: @extension, render: @render) do
      {:ok, html} -> html
      _ -> ""
    end
  end

  # `![[diagram.png]]` names a file, not a page: anything with an extension
  # other than `.md`.
  defp file_embed?(%{target: target}), do: Embeds.file_target?(target)

  defp embed_source(page, nil), do: {:ok, page.body || ""}

  defp embed_source(page, "^" <> id) do
    body = page.body || ""

    paragraphs = String.split(body, ~r/\n\s*\n/)

    case Enum.find(paragraphs, &Regex.match?(~r/\s\^#{Regex.escape(id)}\s*$/m, &1)) do
      nil -> :error
      paragraph -> {:ok, String.trim(paragraph)}
    end
  end

  defp embed_source(page, heading) do
    wanted = anchor(heading)

    case Enum.find(Section.headings(page.body), &(anchor(&1.title) == wanted)) do
      nil -> :error
      found -> Section.read(page.body, found.path)
    end
  end

  @doc """
  The heading anchor comrak generates for a heading's text: lowercased,
  everything but letters, digits, `_`, `-` and spaces dropped, and each space
  a `-` of its own — so "Two & three" is `two--three`, not `two-three`. A
  repeated heading's `-1` suffix is not reproduced; the link finds the first.
  """
  def anchor(title) do
    title
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}_ -]/u, "")
    |> String.replace(" ", "-")
  end

  defp html_block(html), do: %MDEx.HtmlBlock{literal: html}

  defp strip_brackets(raw) do
    raw
    |> String.trim_leading("!")
    |> String.trim_leading("[[")
    |> String.trim_trailing("]]")
    |> String.split("|", parts: 2)
    |> hd()
  end

  defp escape(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @doc """
  The first paragraph of a body, as plain text — the fallback summary for a
  page whose author has not written one, and what a listing shows.
  """
  def excerpt(body, limit \\ 200)

  def excerpt(body, limit) when is_binary(body) do
    body
    |> Excalidraw.readable()
    |> Meld.conceal()
    |> String.split(~r/\n\s*\n/, parts: 6)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(
      &(&1 == "" or String.starts_with?(&1, "#") or String.starts_with?(&1, "```") or
          String.starts_with?(&1, "[[!"))
    )
    |> List.first()
    |> case do
      nil -> ""
      para -> para |> Markup.to_plain() |> strip_markup() |> truncate(limit)
    end
  end

  def excerpt(_, _), do: ""

  @doc """
  The start of a body as plain-text paragraphs, `limit` characters in all,
  for a preview of the page (#760): headings kept as lines of their own,
  code blocks and embeds left out, encrypted text a 🔒.
  """
  def preview_paragraphs(body, limit \\ 600)

  def preview_paragraphs(body, limit) when is_binary(body) do
    body
    |> Excalidraw.readable()
    |> Meld.conceal()
    |> String.replace(~r/^```.*?(^```[^\n]*$|\z)/ms, "")
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["[[!", "![[", "---"])))
    |> Enum.map(&(&1 |> Markup.to_plain() |> strip_markup()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({[], limit}, fn para, {acc, left} ->
      cond do
        left <= 1 -> {:halt, {acc, left}}
        String.length(para) >= left -> {:halt, {[truncate(para, left) | acc], 0}}
        true -> {:cont, {[para | acc], left - String.length(para)}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  def preview_paragraphs(_, _), do: []

  # Enough to make a one-line summary read as prose rather than as source.
  defp strip_markup(text) do
    text
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/[*_`>#]+/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(text, limit) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit - 1) <> "…",
      else: text
  end
end
