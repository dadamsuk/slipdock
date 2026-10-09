defmodule Slipdock.Portable.Export do
  @moduledoc """
  Writing board trees out as a portable document — see `Slipdock.Portable` for
  the format and the promises it makes.

  Everything a tree holds is fetched once for the whole tree rather than once
  per card, and every id is swapped for a ref on the way out (the numbering is
  `Slipdock.Portable.Refs`), so nothing written here names a row on this
  server.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User

  alias Slipdock.Boards.{
    Board,
    Card,
    CardLink,
    CardUrl,
    ChecklistItem,
    Comment,
    FieldDefinition,
    FieldValue,
    Milestone,
    SavedView,
    StatusUpdate,
    Tag
  }

  alias Slipdock.Portable.Refs
  alias Slipdock.Repo
  alias Slipdock.Wiki.{Folder, Page}

  @doc """
  One document holding whole board trees.

  `boards` is a list of root boards to take; omit it, or pass `:owned`, for
  every root board the user owns. Options:

    * `:archived_cards` — include archived cards (default `false`)
    * `:archived_pages` — include archived wiki pages (default `false`)
    * `:archived_boards` — include archived root boards when taking all of
      them (default `false`)

  Archived *sub-boards* are not a thing — a sub-board goes away with its card —
  so the board-level switch is about root boards only.
  """
  @spec export(User.t(), keyword()) :: map()
  def export(%User{} = user, opts \\ []) do
    roots = roots_for(user, opts)

    %{
      slipdock_portable: Slipdock.Portable.format_version(),
      exported_at: DateTime.utc_now() |> DateTime.truncate(:second),
      exported_by: user.email,
      exported_from: %{
        version: Slipdock.Build.version(),
        commit: Slipdock.Build.sha()
      },
      options: %{
        archived_cards: !!opts[:archived_cards],
        archived_pages: !!opts[:archived_pages]
      },
      boards: Enum.map(roots, &tree_json(&1, opts))
    }
  end

  @doc """
  `export/2` as pretty JSON, with a filename to offer it under.

  Returns `{filename, iodata}`.
  """
  @spec to_json(User.t(), keyword()) :: {String.t(), iodata()}
  def to_json(%User{} = user, opts \\ []) do
    document = export(user, opts)
    name = "slipdock-export-#{Date.utc_today()}.json"
    {name, Jason.encode_to_iodata!(document, pretty: true)}
  end

  @doc """
  What an export of the same selection knowingly leaves behind, as sentences
  for a person.

  Takes the user and options rather than a document, because the counts come
  from the database: the document holds refs, not ids, which is the whole point
  of it. Empty when there was nothing of that kind to leave, so an export of a
  board with no attachments does not warn about attachments.
  """
  @spec warnings(User.t(), keyword()) :: [String.t()]
  def warnings(%User{} = user, opts \\ []) do
    board_ids =
      user
      |> roots_for(opts)
      |> Enum.flat_map(fn root -> [root.id | Enum.map(descendants(root), & &1.id)] end)

    [
      {attachment_count(board_ids),
       "Attachments are not in this file. They are bytes rather than structure, and they " <>
         "stay on the server they were uploaded to."},
      {vote_count(board_ids),
       "Votes are not in this file. A vote is a person's budget spent, which does not mean " <>
         "the same thing on another server."},
      {revision_count(board_ids),
       "Wiki page history is not in this file — only each page as it stands now. A record " <>
         "of who changed what here is not something another server can honestly adopt."},
      {outside_dependency_count(board_ids),
       "Dependencies between a board in this file and a board outside it are not in this " <>
         "file: a dependency is kept only when both of its cards are in the same board tree."}
    ]
    |> Enum.filter(fn {count, _} -> count > 0 end)
    |> Enum.map(fn {count, sentence} -> "#{count} left behind. #{sentence}" end)
  end

  ## Internals: choosing what to export -----------------------------------------

  defp roots_for(user, opts) do
    case opts[:boards] do
      nil -> owned_roots(user, opts)
      :owned -> owned_roots(user, opts)
      boards when is_list(boards) -> boards |> Enum.map(&root_of/1) |> Enum.uniq_by(& &1.id)
    end
  end

  defp owned_roots(user, opts) do
    query =
      from(b in Board,
        where: b.owner_id == ^user.id and is_nil(b.parent_card_id),
        order_by: [asc: b.id]
      )

    query = if opts[:archived_boards], do: query, else: where(query, [b], is_nil(b.archived_at))

    Repo.all(query)
  end

  @doc """
  The export options an `archived` parameter asks for: a comma-separated mix
  of `cards`, `pages` and `boards`, or `all` (or `true`) for every kind.
  Anything else leaves archived things out.
  """
  def archived_opts(value) when is_binary(value) do
    parts = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    all? = "all" in parts or "true" in parts

    [
      archived_cards: all? or "cards" in parts,
      archived_pages: all? or "pages" in parts,
      archived_boards: all? or "boards" in parts
    ]
  end

  def archived_opts(_), do: []

  @doc """
  Given any board of a tree, the root of it — exporting a sub-board on its
  own would hand out cards whose tags and fields were left behind. So the
  root is also what anybody asking to export a board has to own.
  """
  def root_of(%Board{} = board) do
    case board.root_id do
      nil -> board
      root_id -> Repo.get!(Board, root_id)
    end
  end

  def root_of(id) when is_integer(id) or is_binary(id),
    do: Board |> Repo.get!(id) |> root_of()

  ## Internals: writing a tree ---------------------------------------------------

  defp tree_json(%Board{} = root, opts) do
    boards = [root | descendants(root)]
    board_ids = Enum.map(boards, & &1.id)

    cards = cards_in(board_ids, opts)
    pages = pages_in(board_ids, opts)
    columns = Enum.flat_map(boards, &columns_of/1)
    tags = tags_of(root)
    fields = fields_of(root)
    folders = folders_in(board_ids)

    refs = %{
      boards: Refs.numbered(boards, "b"),
      cards: Refs.numbered(cards, "k"),
      pages: Refs.numbered(pages, "w"),
      columns: Refs.numbered(columns, "c"),
      tags: Refs.numbered(tags, "t"),
      fields: Refs.numbered(fields, "f"),
      folders: Refs.numbered(folders, "fo")
    }

    # Everything hanging off the cards and pages, fetched once for the tree
    # rather than once per card: an export of a large board was ten queries a
    # card and another for every email address.
    refs = Map.put(refs, :loaded, load_attached(boards, cards, pages))

    %{
      ref: refs.boards[root.id],
      root: board_json(root, columns, refs),
      boards: Enum.map(tl(boards), &board_json(&1, columns, refs)),
      tags: Enum.map(tags, &tag_json(&1, refs)),
      fields: Enum.map(fields, &field_json(&1, refs)),
      milestones: Enum.map(milestones_of(root), &milestone_json(&1, refs)),
      saved_views: Enum.map(saved_views_of(root), &saved_view_json/1),
      folders: Enum.map(folders, &folder_json(&1, refs)),
      cards: Enum.map(cards, &card_json(&1, refs)),
      pages: Enum.map(pages, &page_json(&1, refs)),
      # Meeting captures, for the record: read back by nobody (an import
      # leaves them out — see `Slipdock.Portable`), but the trail behind cards
      # that came from a meeting should not be lost by moving the board.
      captures:
        board_ids
        |> Slipdock.Meetings.Export.on_boards()
        |> Enum.map(fn capture ->
          capture
          |> Slipdock.Meetings.Export.capture_json()
          |> Map.put(:board, refs.boards[capture.board_id])
        end)
    }
  end

  # Every board under this one, however deep: a sub-board hangs off a card,
  # and that card's board is already in the set.
  defp descendants(%Board{} = root) do
    Repo.all(
      from(b in Board,
        where: b.root_id == ^root.id and not is_nil(b.parent_card_id),
        order_by: [asc: b.id]
      )
    )
  end

  defp board_json(%Board{} = board, columns, refs) do
    %{
      ref: refs.boards[board.id],
      name: board.name,
      code: board.code,
      shortcut: board.shortcut,
      description: board.description,
      color: board.color,
      vote_budget: board.vote_budget,
      vote_max: board.vote_max,
      add_card: board.add_card,
      add_page: board.add_page,
      add_document: board.add_document,
      simple: board.simple,
      kind: board.kind,
      archived: board.archived_at != nil,
      # A sub-board hangs off a card; a root board hangs off nothing.
      inside_card: board.parent_card_id && refs.cards[board.parent_card_id],
      lists:
        columns
        |> Enum.filter(&(&1.board_id == board.id))
        |> Enum.map(&column_json(&1, refs))
    }
  end

  defp column_json(column, refs) do
    %{
      ref: refs.columns[column.id],
      name: column.name,
      position: column.position,
      wip_limit: column.wip_limit,
      color: column.color,
      category: column.category,
      horizon_from: column.horizon_from,
      horizon_to: column.horizon_to,
      horizon_unit: column.horizon_unit,
      sort_by: column.sort_by,
      sort_dir: column.sort_dir,
      group_by: column.group_by
    }
  end

  defp tag_json(tag, refs), do: %{ref: refs.tags[tag.id], name: tag.name, color: tag.color}

  defp field_json(field, refs) do
    %{
      ref: refs.fields[field.id],
      name: field.name,
      key: field.key,
      kind: field.kind,
      position: field.position,
      options: field.options,
      config: field.config,
      sum: field.sum
    }
  end

  defp milestone_json(milestone, refs) do
    %{
      name: milestone.name,
      date: milestone.date,
      color: milestone.color,
      card: milestone.card_id && refs.cards[milestone.card_id]
    }
  end

  defp saved_view_json(view), do: %{name: view.name, config: view.config}

  defp folder_json(folder, refs) do
    %{
      ref: refs.folders[folder.id],
      board: refs.boards[folder.board_id],
      name: folder.name,
      slug: folder.slug,
      position: folder.position,
      parent: folder.parent_id && refs.folders[folder.parent_id]
    }
  end

  defp card_json(%Card{} = card, refs) do
    %{
      ref: refs.cards[card.id],
      board: refs.boards[card.board_id],
      list: refs.columns[card.column_id],
      title: card.title,
      description: card.description,
      position: card.position,
      priority: card.priority,
      flags: card.flags,
      start_date: card.start_date,
      due_date: card.due_date,
      date_precision: card.date_precision,
      completed: card.completed,
      percent_complete: card.percent_complete,
      # Minutes, whatever the unit; a running timer's time isn't spent yet.
      time_spent: card.time_spent,
      time_estimate: card.time_estimate,
      time_unit: card.time_unit,
      color: card.color,
      archived: card.archived_at != nil,
      created_at: card.inserted_at,
      assignee: Refs.email_of(card.assignee_id, refs),
      assignees: card |> Refs.assignee_ids(refs) |> Enum.map(&Refs.email_of(&1, refs)),
      # A sub-board is a board in this document; the card points at it so an
      # import can rebuild the nesting without guessing.
      subcards: refs.boards[refs.loaded.sub_boards[card.id]],
      tags: Refs.tag_refs(card.id, refs),
      blocked_by: Refs.dependency_refs(card.id, refs),
      links: Refs.link_refs(card.id, refs),
      checklist: owned(refs, :checklist, {:card, card.id}),
      comments: owned(refs, :comments, {:card, card.id}),
      status_updates: status_json({:card, card.id}, refs),
      urls: owned(refs, :urls, {:card, card.id}),
      fields: field_value_json({:card, card.id}, refs)
    }
  end

  defp page_json(%Page{} = page, refs) do
    %{
      ref: refs.pages[page.id],
      board: refs.boards[page.board_id],
      list: page.column_id && refs.columns[page.column_id],
      title: page.title,
      slug: page.slug,
      code: page.code,
      number: page.number,
      body: page.body,
      summary: page.summary,
      position: page.position,
      board_position: page.board_position,
      status: page.status,
      template: page.template,
      folder: page.folder_id && refs.folders[page.folder_id],
      parent: page.parent_id && refs.pages[page.parent_id],
      priority: page.priority,
      flags: page.flags,
      start_date: page.start_date,
      due_date: page.due_date,
      date_precision: page.date_precision,
      completed: page.completed,
      percent_complete: page.percent_complete,
      color: page.color,
      archived: page.archived_at != nil,
      created_at: page.inserted_at,
      assignee: Refs.email_of(page.assignee_id, refs),
      checklist: owned(refs, :checklist, {:page, page.id}),
      comments: owned(refs, :comments, {:page, page.id}),
      status_updates: status_json({:page, page.id}, refs),
      urls: owned(refs, :urls, {:page, page.id}),
      fields: field_value_json({:page, page.id}, refs)
    }
  end

  ## Internals: the queries ------------------------------------------------------

  defp columns_of(%Board{} = board) do
    Repo.all(
      from(c in Slipdock.Boards.Column,
        where: c.board_id == ^board.id,
        order_by: [asc: c.position, asc: c.id]
      )
    )
  end

  defp tags_of(%Board{} = root),
    do: Repo.all(from(t in Tag, where: t.board_id == ^root.id, order_by: [asc: t.name]))

  defp fields_of(%Board{} = root),
    do:
      Repo.all(
        from(f in FieldDefinition,
          where: f.board_id == ^root.id,
          order_by: [asc: f.position, asc: f.id]
        )
      )

  defp milestones_of(%Board{} = root),
    do:
      Repo.all(
        from(m in Milestone, where: m.board_id == ^root.id, order_by: [asc: m.date, asc: m.id])
      )

  defp saved_views_of(%Board{} = root),
    do: Repo.all(from(v in SavedView, where: v.board_id == ^root.id, order_by: [asc: v.name]))

  defp folders_in(board_ids) do
    Repo.all(
      from(f in Folder,
        where: f.board_id in ^board_ids,
        order_by: [asc: f.position, asc: f.id]
      )
    )
  end

  defp cards_in(board_ids, opts) do
    query =
      from(c in Card,
        # Stand-ins are left behind: they point at a card by id, which means
        # nothing once imported, and would come back as ordinary cards.
        where: c.board_id in ^board_ids and is_nil(c.stand_in_for_id),
        order_by: [asc: c.board_id, asc: c.position, asc: c.id]
      )

    query = if opts[:archived_cards], do: query, else: where(query, [c], is_nil(c.archived_at))

    Repo.all(query)
  end

  defp pages_in(board_ids, opts) do
    query =
      from(p in Page,
        where: p.board_id in ^board_ids,
        order_by: [asc: p.board_id, asc: p.position, asc: p.id]
      )

    query = if opts[:archived_pages], do: query, else: where(query, [p], is_nil(p.archived_at))

    Repo.all(query)
  end

  # One query per kind of thing, for every card and page in the tree at once.
  # Rows that hang off a card or a page are keyed {:card, id} / {:page, id};
  # each list keeps its query's order.
  defp load_attached(boards, cards, pages) do
    card_ids = Enum.map(cards, & &1.id)
    page_ids = Enum.map(pages, & &1.id)

    owned = fn query ->
      from(r in query, where: r.card_id in ^card_ids or r.page_id in ^page_ids)
      |> Repo.all()
      |> Enum.group_by(&owner_key/1, &Map.drop(&1, [:card_id, :page_id]))
    end

    assignees =
      from(a in "card_assignees",
        where: a.card_id in ^card_ids,
        select: {a.card_id, a.user_id}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    statuses =
      owned.(
        from(s in StatusUpdate,
          order_by: [asc: s.inserted_at, asc: s.id],
          select: %{
            card_id: s.card_id,
            page_id: s.page_id,
            health: s.health,
            body: s.body,
            written_at: s.inserted_at,
            author_id: s.user_id
          }
        )
      )

    user_ids =
      Enum.map(cards, & &1.assignee_id) ++
        Enum.map(pages, & &1.assignee_id) ++
        Enum.concat(Map.values(assignees)) ++
        (statuses |> Map.values() |> Enum.concat() |> Enum.map(& &1.author_id))

    user_ids = user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      sub_boards:
        for(
          %Board{parent_card_id: card_id, id: id} <- boards,
          card_id,
          into: %{},
          do: {card_id, id}
        ),
      assignees: assignees,
      emails:
        Map.new(Repo.all(from(u in User, where: u.id in ^user_ids, select: {u.id, u.email}))),
      tags:
        from(t in "card_tags",
          where: t.card_id in ^card_ids,
          order_by: [asc: t.tag_id],
          select: {t.card_id, t.tag_id}
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
      blockers:
        from(d in "card_dependencies",
          where: d.blocked_id in ^card_ids,
          order_by: [asc: d.blocker_id],
          select: {d.blocked_id, d.blocker_id}
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
      links:
        from(l in CardLink, where: l.from_id in ^card_ids, order_by: [asc: l.id])
        |> Repo.all()
        |> Enum.group_by(& &1.from_id),
      checklist:
        owned.(
          from(i in ChecklistItem,
            order_by: [asc: i.position, asc: i.id],
            select: %{
              card_id: i.card_id,
              page_id: i.page_id,
              text: i.text,
              done: i.done,
              position: i.position
            }
          )
        ),
      comments:
        owned.(
          from(c in Comment,
            order_by: [asc: c.inserted_at, asc: c.id],
            select: %{
              card_id: c.card_id,
              page_id: c.page_id,
              body: c.body,
              written_at: c.inserted_at
            }
          )
        ),
      statuses: statuses,
      urls:
        owned.(
          from(u in CardUrl,
            order_by: [asc: u.inserted_at, asc: u.id],
            select: %{card_id: u.card_id, page_id: u.page_id, url: u.url, title: u.title}
          )
        ),
      field_values:
        from(v in FieldValue,
          where: v.card_id in ^card_ids or v.page_id in ^page_ids,
          order_by: [asc: v.id]
        )
        |> Repo.all()
        |> Enum.group_by(&owner_key/1)
    }
  end

  defp owner_key(%{card_id: id}) when not is_nil(id), do: {:card, id}
  defp owner_key(%{page_id: id}), do: {:page, id}

  defp owned(refs, kind, key), do: Map.get(refs.loaded[kind], key, [])

  defp status_json(key, refs) do
    refs
    |> owned(:statuses, key)
    |> Enum.map(fn update ->
      update |> Map.put(:author, Refs.email_of(update.author_id, refs)) |> Map.delete(:author_id)
    end)
  end

  defp field_value_json(key, refs) do
    refs
    |> owned(:field_values, key)
    |> Enum.map(
      &%{
        field: refs.fields[&1.field_id],
        number: &1.number,
        text: &1.text,
        date: &1.date,
        option: &1.option
      }
    )
    |> Enum.reject(&is_nil(&1.field))
  end

  ## Internals: the warnings -----------------------------------------------------

  defp attachment_count([]), do: 0

  defp attachment_count(board_ids) do
    Repo.one(
      from(a in Slipdock.Boards.Attachment,
        join: c in Card,
        on: c.id == a.card_id,
        where: c.board_id in ^board_ids,
        select: count(a.id)
      )
    ) || 0
  end

  defp vote_count([]), do: 0

  defp vote_count(board_ids) do
    Repo.one(
      from(v in Slipdock.Boards.Vote,
        join: c in Card,
        on: c.id == v.card_id,
        where: c.board_id in ^board_ids,
        select: count(v.id)
      )
    ) || 0
  end

  # Dependencies joining a board inside the export to one outside it — or to
  # another exported tree, since each tree's refs are its own. Cards on
  # different boards can depend on each other, so there can be some.
  defp outside_dependency_count([]), do: 0

  defp outside_dependency_count(board_ids) do
    root_ids =
      from(b in Board, where: b.id in ^board_ids, select: coalesce(b.root_id, b.id))
      |> Repo.all()
      |> Enum.uniq()

    Repo.one(
      from(d in "card_dependencies",
        join: x in Card,
        on: x.id == d.blocked_id,
        join: xb in Board,
        on: xb.id == x.board_id,
        join: y in Card,
        on: y.id == d.blocker_id,
        join: yb in Board,
        on: yb.id == y.board_id,
        where: coalesce(xb.root_id, xb.id) != coalesce(yb.root_id, yb.id),
        where:
          coalesce(xb.root_id, xb.id) in ^root_ids or coalesce(yb.root_id, yb.id) in ^root_ids,
        select: count()
      )
    ) || 0
  end

  defp revision_count([]), do: 0

  defp revision_count(board_ids) do
    Repo.one(
      from(r in Slipdock.Wiki.Revision,
        join: p in Page,
        on: p.id == r.page_id,
        where: p.board_id in ^board_ids,
        select: count(r.id)
      )
    ) || 0
  end
end
