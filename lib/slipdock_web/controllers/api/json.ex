defmodule SlipdockWeb.API.JSON do
  @moduledoc "Plain-map serializers for API responses."

  alias Slipdock.Boards.{
    Activity,
    Board,
    Card,
    ChecklistItem,
    Column,
    Comment,
    SavedView,
    Tag,
    Template
  }

  alias Slipdock.Automations.{Alert, Rule}
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Wiki.{Link, Page, Revision}

  def board_summary(%Board{} = b) do
    cards = if Ecto.assoc_loaded?(b.cards), do: b.cards, else: []
    columns = if Ecto.assoc_loaded?(b.columns), do: b.columns, else: []

    %{
      id: b.id,
      name: b.name,
      code: b.code,
      shortcut: b.shortcut,
      description: b.description,
      color: b.color,
      columns: length(columns),
      cards: length(cards),
      completed: Enum.count(cards, & &1.completed),
      archived_at: b.archived_at,
      inserted_at: b.inserted_at
    }
  end

  def template(%Template{} = t) do
    %{id: t.id, name: t.name, description: t.description, columns: t.columns}
  end

  def board(%Board{} = b) do
    %{
      id: b.id,
      name: b.name,
      code: b.code,
      shortcut: b.shortcut,
      description: b.description,
      color: b.color,
      archived_at: b.archived_at,
      root_id: Board.root_id(b),
      parent_card:
        case b.parent_card do
          %Card{} = c -> %{id: c.id, title: c.title, board_id: c.board_id}
          _ -> nil
        end,
      tags: Enum.map(b.tags, &tag/1),
      milestones: Enum.map(Map.get(b, :milestones) || [], &milestone/1),
      fields: Enum.map(Map.get(b, :fields) || [], &field_definition/1),
      votes: %{budget: b.vote_budget, max_per_card: b.vote_max},
      # What the foot of every list offers, and so what a client should draw.
      add: %{card: b.add_card, page: b.add_page, document: b.add_document},
      columns:
        Enum.map(b.columns, fn col ->
          col
          |> column()
          |> Map.put(:cards, Enum.map(col.cards, &card/1))
          # Wiki pages placed in this list sit in the same order as its
          # cards, so a client that draws the list draws both.
          |> Map.put(:pages, Enum.map(placed(col), &page_summary/1))
        end)
    }
  end

  defp placed(%Column{pages: pages}) when is_list(pages), do: pages
  defp placed(_), do: []

  def column(%Column{} = c) do
    %{
      id: c.id,
      name: c.name,
      position: c.position,
      wip_limit: c.wip_limit,
      color: c.color,
      category: c.category,
      horizon:
        if Column.horizon?(c) do
          %{
            from: c.horizon_from,
            to: c.horizon_to,
            unit: c.horizon_unit,
            label: Column.horizon_label(c)
          }
        end
    }
  end

  def field_definition(%Slipdock.Boards.FieldDefinition{} = f) do
    %{
      id: f.id,
      name: f.name,
      key: f.key,
      kind: f.kind,
      position: f.position,
      options: f.options,
      config: f.config,
      sum: f.sum
    }
  end

  def milestone(%Slipdock.Boards.Milestone{} = m),
    do: %{id: m.id, name: m.name, date: m.date, color: m.color, card_id: m.card_id}

  def status_update(%Slipdock.Boards.StatusUpdate{} = u) do
    %{
      id: u.id,
      health: u.health,
      body: u.body,
      user_id: u.user_id,
      inserted_at: u.inserted_at
    }
  end

  def tag(%Tag{} = t), do: %{id: t.id, name: t.name, color: t.color}

  # A wiki page placed in a list stands beside the cards in every view, so it
  # comes back from a grid too — as the page summary it is, `kind: "page"` and
  # all, rather than pretending to be a card.
  def card(%Page{} = p), do: page_summary(p)

  def card(%Card{} = c) do
    checklist = if Ecto.assoc_loaded?(c.checklist_items), do: c.checklist_items, else: []
    comments = if Ecto.assoc_loaded?(c.comments), do: c.comments, else: []
    attachments = if Ecto.assoc_loaded?(c.attachments), do: c.attachments, else: []
    urls = if Ecto.assoc_loaded?(c.urls), do: c.urls, else: []

    %{
      id: c.id,
      board_id: c.board_id,
      column_id: c.column_id,
      column: if(Ecto.assoc_loaded?(c.column), do: c.column.name),
      position: c.position,
      title: c.title,
      # "card" or "document" — a card whose whole content is the file on it
      # (see `Slipdock.Kinds`), which is what `cards?kind=` filters by.
      kind: Slipdock.Kinds.kind_of(c),
      description: c.description,
      priority: c.priority,
      flags: c.flags,
      tags: if(Ecto.assoc_loaded?(c.tags), do: Enum.map(c.tags, & &1.name), else: []),
      start_date: c.start_date,
      due_date: c.due_date,
      date_precision: c.date_precision,
      completed: c.completed,
      percent_complete: c.percent_complete,
      stated_health: Card.stated_health(c),
      fields: field_values(c),
      scores: Map.get(c, :scores) || %{},
      votes: Card.vote_total(c),
      status_updates:
        if(Ecto.assoc_loaded?(c.status_updates),
          do: Enum.map(c.status_updates, &status_update/1),
          else: []
        ),
      color: c.color,
      archived_at: c.archived_at,
      assignee: assignee(c),
      rollup: rollup(c),
      blocked: Card.blocked?(c),
      blocked_by: dependency_stubs(c.blocked_by),
      blocks: dependency_stubs(c.blocks),
      links: links(c),
      sub_board: sub_board_summary(c),
      checklist: %{
        done: Enum.count(checklist, & &1.done),
        total: length(checklist),
        items: Enum.map(checklist, &checklist_item/1)
      },
      comments: Enum.map(comments, &comment/1),
      attachments: Enum.map(attachments, &attachment/1),
      urls: Enum.map(urls, &card_url/1),
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  # Stored custom field values keyed by field key (formulas are under `scores`).
  defp field_values(%Card{field_values: values}) when is_list(values) do
    for %{field: %Slipdock.Boards.FieldDefinition{} = f} = v <- values,
        into: %{},
        do: {f.key, Slipdock.Boards.FieldValue.get(v)}
  end

  defp field_values(_), do: %{}

  defp assignee(%Card{assignee: %Slipdock.Accounts.User{} = u}),
    do: %{id: u.id, email: u.email, name: Slipdock.Accounts.User.display_name(u)}

  defp assignee(_), do: nil

  # What the card's subcards roll up to (see Slipdock.Rollup); nil for a leaf.
  defp rollup(%Card{rollup: %{children: n} = r}) when n > 0 do
    %{
      done: r.done,
      total: r.total,
      start: r.start,
      due: r.due,
      start_derived: r.start_derived?,
      due_derived: r.due_derived?,
      slip_days: r.slip,
      blocked: r.blocked,
      overdue: r.overdue,
      health: r.health,
      depth: r.depth
    }
  end

  defp rollup(_), do: nil

  defp sub_board_summary(%Card{sub_board: %Board{} = b} = c) do
    {done, total} = Card.subcard_progress(c)
    columns = if Ecto.assoc_loaded?(b.columns), do: b.columns, else: []
    cards = if Ecto.assoc_loaded?(b.cards), do: b.cards, else: []

    %{
      id: b.id,
      name: b.name,
      completed: done,
      total: total,
      columns:
        Enum.map(columns, fn col ->
          %{id: col.id, name: col.name, cards: Enum.count(cards, &(&1.column_id == col.id))}
        end)
    }
  end

  defp sub_board_summary(_), do: nil

  defp links(%Card{links_out: out, links_in: inn}) when is_list(out) and is_list(inn) do
    Enum.map(out, fn l -> %{id: l.id, kind: l.kind, direction: "out", card: link_stub(l.to)} end) ++
      Enum.map(inn, fn l ->
        %{id: l.id, kind: l.kind, direction: "in", card: link_stub(l.from)}
      end)
  end

  defp links(_), do: []

  defp link_stub(%Card{} = c) do
    %{
      id: c.id,
      title: c.title,
      completed: c.completed,
      board_id: c.board_id,
      board: if(match?(%Board{}, c.board), do: c.board.name)
    }
  end

  defp dependency_stubs(deps) when is_list(deps) do
    Enum.map(deps, fn d ->
      %{id: d.id, title: d.title, completed: d.completed, archived: not is_nil(d.archived_at)}
    end)
  end

  defp dependency_stubs(_), do: []

  def attachment(%Slipdock.Boards.Attachment{} = a) do
    %{
      id: a.id,
      filename: a.filename,
      content_type: a.content_type,
      size: a.size,
      url: Slipdock.Boards.attachment_url(a),
      inserted_at: a.inserted_at
    }
  end

  def card_url(%Slipdock.Boards.CardUrl{} = u) do
    %{
      id: u.id,
      url: u.url,
      title: u.title,
      label: Slipdock.Boards.CardUrl.label(u),
      added_at: u.inserted_at
    }
  end

  def checklist_item(%ChecklistItem{} = i),
    do: %{id: i.id, text: i.text, done: i.done, position: i.position}

  def comment(%Comment{} = c), do: %{id: c.id, body: c.body, inserted_at: c.inserted_at}

  @doc """
  A saved view. `favourite?` is the *reading* user's own mark, not the
  view's: favourites belong to people (see `Slipdock.Favourites`).
  """
  def saved_view(%SavedView{} = v, favourite? \\ false) do
    %{
      id: v.id,
      board_id: v.board_id,
      name: v.name,
      favourite: favourite?,
      config: v.config |> Config.from_map() |> Config.to_map(),
      url: "/boards/#{v.board_id}/swimlanes?view=#{v.id}",
      inserted_at: v.inserted_at,
      updated_at: v.updated_at
    }
  end

  @doc "A swimlane grid (see `Slipdock.Swimlanes.grid/2`) with each cell's cards."
  def grid(%Board{} = board, grid, %Config{} = config, view \\ nil, favourite? \\ false) do
    col_names = Map.new(board.columns, &{&1.id, &1.name})

    %{
      view: view && saved_view(view, favourite?),
      config: Config.to_map(config),
      rows: Enum.map(grid.rows, &bucket/1),
      cols: Enum.map(grid.cols, &bucket/1),
      cells:
        Enum.map(grid.rows, fn row ->
          Enum.map(row.cells, fn cards ->
            Enum.map(cards, fn c -> c |> card() |> Map.put(:column, col_names[c.column_id]) end)
          end)
        end),
      shown: grid.shown,
      hidden: grid.hidden
    }
  end

  defp bucket(b), do: %{key: b.key, label: b.label, count: b.count, color: b.color, tone: b.tone}

  def activity(%Activity{} = a),
    do: %{
      id: a.id,
      kind: a.kind,
      card_id: a.card_id,
      page_id: a.page_id,
      message: a.message,
      at: a.inserted_at
    }

  ## Wiki --------------------------------------------------------------------

  @doc """
  A page without its body: what listings and trees return, so asking for a
  board's wiki does not hand back every word on it.
  """
  def page_summary(%Page{} = p) do
    %{
      id: p.id,
      code: p.code,
      number: p.number,
      board_id: p.board_id,
      parent_id: p.parent_id,
      # Where it is filed, as opposed to what it is part of.
      folder_id: p.folder_id,
      title: p.title,
      # The third kind of thing a list can hold (see `Slipdock.Kinds`), said out
      # loud so a client holding cards and pages together can tell them apart.
      kind: "page",
      slug: p.slug,
      summary: p.summary,
      status: p.status,
      template: p.template,
      position: p.position,
      archived_at: p.archived_at,
      content_hash: p.content_hash,
      url: page_url(p),
      # Whether anyone with a link can read it, and the link if so.
      # The card facets a page carries (see `Slipdock.Wiki.Page`), so a client
      # that draws a card can draw a page.
      priority: p.priority,
      flags: p.flags,
      start_date: p.start_date,
      due_date: p.due_date,
      date_precision: p.date_precision,
      completed: p.completed,
      percent_complete: p.percent_complete,
      color: p.color,
      assignee: assignee_ref(p),
      tags: page_tags(p),
      # Where it sits on the board, when it has been put there.
      column_id: p.column_id,
      board_position: p.column_id && p.board_position,
      published: not is_nil(p.public_token),
      published_at: p.published_at,
      public_url: p.public_token && "/w/#{p.public_token}",
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  @doc "A page in full: the Markdown source, not HTML — the model edits what it reads."
  def page(%Page{} = p) do
    checklist = loaded(p.checklist_items)

    p
    |> page_summary()
    |> Map.merge(%{
      body: p.body,
      created_by: user_ref(p.created_by),
      updated_by: user_ref(p.updated_by),
      # The card contents a page carries (see `Slipdock.Boards.Owned`), named
      # and shaped exactly as a card's are.
      stated_health: Card.stated_health(p),
      votes: Card.vote_total(p),
      fields: page_field_values(p),
      status_updates: Enum.map(loaded(p.status_updates), &status_update/1),
      checklist: %{
        done: Enum.count(checklist, & &1.done),
        total: length(checklist),
        items: Enum.map(checklist, &checklist_item/1)
      },
      comments: Enum.map(loaded(p.comments), &comment/1),
      urls: Enum.map(loaded(p.urls), &card_url/1)
    })
  end

  defp loaded(list) when is_list(list), do: list
  defp loaded(_), do: []

  defp page_field_values(%Page{field_values: values}) when is_list(values) do
    for %{field: %Slipdock.Boards.FieldDefinition{} = f} = v <- values,
        into: %{},
        do: {f.key, Slipdock.Boards.FieldValue.get(v)}
  end

  defp page_field_values(_), do: %{}

  @doc "A page and its children, however deep — `%{page: …, children: […]}` nodes."
  def page_tree(nodes) when is_list(nodes) do
    Enum.map(nodes, fn %{page: page, children: children} ->
      page |> page_summary() |> Map.put(:children, page_tree(children))
    end)
  end

  @doc "One wiki folder — filing, not writing (see `Slipdock.Wiki.Folder`)."
  def folder(%Slipdock.Wiki.Folder{} = f) do
    %{
      id: f.id,
      board_id: f.board_id,
      parent_id: f.parent_id,
      name: f.name,
      slug: f.slug,
      path: Slipdock.Wiki.folder_path(f),
      position: f.position,
      inserted_at: f.inserted_at,
      updated_at: f.updated_at
    }
  end

  @doc """
  A folder tree with the pages filed in each — `%{folder:, children:, pages:}`
  nodes, as `Slipdock.Wiki.Folders.tree/2` builds them.
  """
  def folder_tree(nodes) when is_list(nodes) do
    Enum.map(nodes, fn %{folder: f, children: children, pages: pages} ->
      f
      |> folder()
      |> Map.merge(%{folders: folder_tree(children), pages: page_tree(pages)})
    end)
  end

  def revision(%Revision{} = r) do
    %{
      id: r.id,
      page_id: r.page_id,
      title: r.title,
      summary: r.summary,
      via: r.via,
      agent: r.agent,
      byte_size: r.byte_size,
      author: user_ref(r.author),
      at: r.inserted_at
    }
  end

  @doc "A diff as `Slipdock.Wiki.diff/2` returns it, as JSON-safe hunks."
  def diff(hunks) do
    Enum.map(hunks, fn {op, lines} -> %{op: to_string(op), lines: lines} end)
  end

  def page_url(%Page{} = p), do: "/boards/#{p.board_id}/wiki/#{p.slug}"

  defp assignee_ref(%Page{assignee: %Slipdock.Accounts.User{} = u}),
    do: %{id: u.id, email: u.email, name: u.name}

  defp assignee_ref(_), do: nil

  defp page_tags(%Page{tags: tags}) when is_list(tags), do: Enum.map(tags, & &1.name)
  defp page_tags(_), do: []

  @doc "One reference written in a page."
  def link(%Link{} = l) do
    %{
      id: l.id,
      kind: l.kind,
      raw: l.raw,
      label: l.label,
      count: l.count,
      pinned: l.pinned,
      resolved: l.resolved,
      target: link_target(l)
    }
  end

  defp link_target(%Link{kind: "page", target_page: %Page{} = p}),
    do: %{id: p.id, code: p.code, title: p.title, url: page_url(p)}

  defp link_target(%Link{kind: "card", target_card: %Card{} = c}),
    do: %{
      id: c.id,
      title: c.title,
      url: "/boards/#{c.board_id}/cards/#{c.id}",
      completed: c.completed
    }

  defp link_target(%Link{kind: "board", target_board: %Board{} = b}),
    do: %{id: b.id, code: b.code, name: b.name, url: "/boards/#{b.id}"}

  defp link_target(%Link{kind: "view", target_view: %SavedView{} = v}),
    do: %{id: v.id, name: v.name, url: "/boards/#{v.board_id}?view=#{v.id}"}

  defp link_target(_), do: nil

  @doc "A page that links here, as the other end of the arrow."
  def backlink(%Link{page: %Page{} = p} = l),
    do: %{page: page_summary(p), count: l.count, pinned: l.pinned, raw: l.raw}

  @doc "The answer a live query block gives, whatever shape it takes."
  def query_result(%{kind: :count} = result), do: %{kind: "count", count: result.count}

  def query_result(%{kind: :progress} = result),
    do: %{
      kind: "progress",
      done: result.done,
      total: result.total,
      percent: result.percent,
      label: result[:label]
    }

  def query_result(%{kind: :list} = result),
    do: %{kind: "list", count: result[:count], cards: Enum.map(result.cards, &card_stub/1)}

  def query_result(%{kind: :groups} = result),
    do: %{
      kind: "groups",
      count: result[:count],
      groups:
        Enum.map(
          result.groups,
          &%{label: &1.label, cards: Enum.map(&1.cards, fn c -> card_stub(c) end)}
        )
    }

  def query_result(%{kind: :table} = result),
    do: %{
      kind: "table",
      count: result[:count],
      headers: result.headers,
      fields: result.keys,
      rows: Enum.map(result.rows, &%{card: card_stub(&1.card), cells: &1.cells})
    }

  def query_result(_result), do: %{kind: "unknown"}

  defp card_stub(%Card{} = c),
    do: %{
      id: c.id,
      title: c.title,
      board_id: c.board_id,
      completed: c.completed,
      url: "/boards/#{c.board_id}/cards/#{c.id}"
    }

  @doc "A page linked to but never written."
  def wanted(%{raw: raw, title: title, count: count, from: from}),
    do: %{raw: raw, title: title, count: count, from: Enum.map(from, &page_summary/1)}

  defp user_ref(%Slipdock.Accounts.User{} = u), do: %{id: u.id, email: u.email, name: u.name}
  defp user_ref(_), do: nil

  def automation(%Rule{} = r) do
    %{
      id: r.id,
      board_id: r.board_id,
      name: r.name,
      summary: Rule.summary(r),
      source: r.source,
      spec: r.spec,
      trigger: Rule.trigger_type(r),
      scheduled: Rule.scheduled?(r),
      scope: r.scope,
      enabled: r.enabled,
      run_count: r.run_count,
      last_run_at: r.last_run_at,
      last_error: r.last_error,
      inserted_at: r.inserted_at
    }
  end

  def alert(%Alert{} = a) do
    %{
      id: a.id,
      title: a.title,
      body: a.body,
      severity: a.severity,
      board_id: a.board_id,
      board: if(Ecto.assoc_loaded?(a.board) and a.board, do: a.board.name),
      card_id: a.card_id,
      card: if(Ecto.assoc_loaded?(a.card) and a.card, do: a.card.title),
      rule_id: a.rule_id,
      url:
        if(a.card_id,
          do: "/boards/#{a.board_id}/cards/#{a.card_id}",
          else: "/boards/#{a.board_id}"
        ),
      at: a.inserted_at
    }
  end

  def errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
