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

  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Links, Markup, Page, Query, Section}

  @extension [
    table: true,
    tasklist: true,
    strikethrough: true,
    autolink: true,
    footnotes: true,
    header_id_prefix: ""
  ]

  # Raw HTML is rendered so the chips below survive; the sanitiser decides
  # what any of it is allowed to be.
  @render [unsafe: true]

  @sanitize [
    add_tags: ["input"],
    add_tag_attributes: %{
      "input" => ["type", "checked", "disabled"],
      "a" => ["title"],
      "span" => ["title"]
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

  A body that cannot be parsed comes back as escaped plain text rather than
  an error page: a document is worth more half-rendered than not at all.
  """
  def to_html(body, opts \\ [])

  def to_html(body, opts) when is_binary(body) do
    context = context(opts)

    # Extensions belong on the *parse*, not just the render: a pipe table is
    # only a table if the parser was told tables exist.
    with {:ok, doc} <- MDEx.parse_document(body, extension: @extension),
         {:ok, html} <-
           doc
           |> expand(context)
           |> MDEx.to_html(extension: @extension, render: @render, sanitize: @sanitize) do
      html
    else
      _ -> "<pre>" <> escape(body) <> "</pre>"
    end
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

  defp markdown_for(ref, context) do
    case resolve_one(ref, context) do
      {:page, page} -> "[#{ref.label || page.title}](#{page_path(page)})"
      {:card, card} -> "#{ref.label || card.title} (##{card.id}#{card_meta(card)})"
      {:board, board} -> "[#{ref.label || board.name}](/boards/#{board.id})"
      {:view, view} -> "[#{ref.label || view.name}](/boards/#{view.board_id}?view=#{view.id})"
      {:mention, user} -> "@#{Wiki.author_name(user)}"
      {:directive, name} -> directive_markdown(name, context)
      _ -> ref.label || strip_brackets(ref.raw)
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
      # A published page answers its queries as of the moment it was
      # published: there is nobody on the other side to have permissions, so
      # a live query would be a way to read private cards from the open web.
      frozen: Keyword.get(opts, :frozen)
    }
  end

  defp resolve_one(_ref, %{board: nil}), do: nil

  defp resolve_one(ref, context) do
    [resolution] = Links.resolve(context.board, [Map.put(ref, :count, 1)], as: context.reader)
    resolution.to
  end

  ## Tree rewriting -----------------------------------------------------------

  defp expand(%MDEx.Document{nodes: nodes} = doc, context),
    do: %{doc | nodes: expand_list(nodes, context)}

  defp expand_list(nodes, context), do: Enum.flat_map(nodes, &expand_node(&1, context))

  # A paragraph that is nothing but a directive becomes a block of its own:
  # a table of contents does not belong inside a <p>.
  defp expand_node(%MDEx.Paragraph{nodes: [%MDEx.Text{literal: text}]} = node, context) do
    case Markup.tokens(String.trim(text)) do
      [{:ref, %{kind: :directive} = ref}] -> [html_block(directive_html(ref.target, context))]
      _ -> [%{node | nodes: expand_list(node.nodes, context)}]
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

  defp expand_node(%MDEx.Text{literal: text}, context), do: text_nodes(text, context)

  defp expand_node(%{nodes: children} = node, context) when is_list(children),
    do: [%{node | nodes: expand_list(children, context)}]

  defp expand_node(node, _context), do: [node]

  defp text_nodes(text, context) do
    text
    |> Markup.tokens()
    |> Enum.map(fn
      {:text, literal} -> %MDEx.Text{literal: literal}
      {:ref, ref} -> ref_node(ref, context)
    end)
  end

  defp ref_node(%{kind: :inline} = ref, context) do
    case inline_answer(ref, context) do
      {:ok, text} ->
        %MDEx.HtmlInline{literal: ~s|<span class="wiki-inline">#{escape(text)}</span>|}

      :error ->
        %MDEx.Text{literal: ref.raw}
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

  defp resolved_html(ref, {:page, page}, _context) do
    ~s|<a href="#{page_path(page)}" class="wiki-link" title="#{escape(page.code)}">| <>
      escape(ref.label || page.title) <> "</a>"
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

  defp directive_html("children", %{page: %Page{} = page}) do
    case Wiki.children(page) do
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

            ~s|<li><a href="#{page_path(child)}" class="wiki-link">#{escape(child.title)}</a>#{summary}</li>|
          end)

        ~s|<ul class="wiki-children">#{items}</ul>|
    end
  end

  defp directive_html("backlinks", %{page: %Page{} = page, reader: reader}) do
    case Links.backlinks(page, reader) do
      [] ->
        ~s|<p class="wiki-empty">Nothing links here yet.</p>|

      links ->
        items =
          Enum.map_join(links, "", fn link ->
            ~s|<li><a href="#{page_path(link.page)}" class="wiki-link">#{escape(link.page.title)}</a></li>|
          end)

        ~s|<ul class="wiki-backlinks">#{items}</ul>|
    end
  end

  defp directive_html(_name, _context), do: ""

  defp directive_markdown("toc", %{page: %Page{} = page}) do
    page.body
    |> Section.headings()
    |> Enum.map_join("\n", &(String.duplicate("  ", &1.level - 1) <> "- " <> &1.title))
  end

  defp directive_markdown("children", %{page: %Page{} = page}) do
    page
    |> Wiki.children()
    |> Enum.map_join("\n", fn child ->
      "- [#{child.title}](#{page_path(child)})#{if child.summary, do: " — #{child.summary}"}"
    end)
  end

  defp directive_markdown("backlinks", %{page: %Page{} = page, reader: reader}) do
    page
    |> Links.backlinks(reader)
    |> Enum.map_join("\n", &"- [#{&1.page.title}](#{page_path(&1.page)})")
  end

  defp directive_markdown(_name, _context), do: ""

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
