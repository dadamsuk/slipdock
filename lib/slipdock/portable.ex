defmodule Slipdock.Portable do
  @moduledoc """
  Board trees out as one JSON document, and back in again.

  This is not the same thing as `Slipdock.AccountExport`, which answers "let
  me leave with my data" and writes a zip a person reads. That one flattens a
  board to lists of cards and drops subcards, tags, checklists, comments,
  custom fields and dependencies, because nothing is ever going to read it
  back. This one is the opposite promise: **what comes out can go back in**,
  on this server or another one, and come back the same shape.

  Which forces three decisions.

  **The unit is a board tree, not a board.** Tags, custom fields, milestones
  and saved views are stored against the root of a tree and shared by every
  sub-board under it (see `Slipdock.Boards.Board`), and a card's subcards *are*
  a sub-board. Exporting one board of a tree would hand you cards whose tags
  and fields live somewhere you did not export, so a root board always comes
  with its descendants.

  **Nothing inside the document is a database id.** Every board, list, tag,
  field, card and page gets a `ref` — `"k12"`, `"t3"` — unique in the document
  and meaningless outside it. Anything pointing at anything else points at a
  ref. A document is then self-contained: the importer never has to care which
  server wrote it, and two documents can be imported into one server without
  colliding.

  **People are email addresses.** An assignee or a status update's author is
  written as an address, because an id from another server names nobody here.
  On the way back in an address that has no account is simply dropped, and the
  import says so — the alternative is an import that fails on the last card
  because somebody left the company.

  What is deliberately *not* in a document: attachments (bytes, not structure —
  they stay with the server), votes (a person's budget, not a board's content),
  activity and page revision history (a record of this server's past, which
  another server cannot honestly adopt), and public share tokens (a secret
  that would then be valid in two places). Each of those is a decision rather
  than an omission, and `warnings/1` on an export says which of them had
  something to leave behind.
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

  alias Slipdock.Repo
  alias Slipdock.Wiki.{Folder, Page}

  @format_version 1

  @doc "The format version this module writes, and the only one it reads."
  def format_version, do: @format_version

  ## Out ------------------------------------------------------------------------

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
      slipdock_portable: @format_version,
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
         "of who changed what here is not something another server can honestly adopt."}
    ]
    |> Enum.filter(fn {count, _} -> count > 0 end)
    |> Enum.map(fn {count, sentence} -> "#{count} left behind. #{sentence}" end)
  end

  ## Internals: choosing what to export -----------------------------------------

  defp roots_for(user, opts) do
    case opts[:boards] do
      nil -> owned_roots(user, opts)
      :owned -> owned_roots(user, opts)
      boards when is_list(boards) -> Enum.map(boards, &root_of/1)
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

  # Given any board of a tree, the root of it — exporting a sub-board on its
  # own would hand out cards whose tags and fields were left behind.
  defp root_of(%Board{} = board) do
    case board.root_id do
      nil -> board
      root_id -> Repo.get!(Board, root_id)
    end
  end

  defp root_of(id) when is_integer(id) or is_binary(id),
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
      boards: numbered(boards, "b"),
      cards: numbered(cards, "k"),
      pages: numbered(pages, "w"),
      columns: numbered(columns, "c"),
      tags: numbered(tags, "t"),
      fields: numbered(fields, "f"),
      folders: numbered(folders, "fo")
    }

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
      pages: Enum.map(pages, &page_json(&1, refs))
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

  defp numbered(records, prefix) do
    records
    |> Enum.with_index(1)
    |> Map.new(fn {record, index} -> {record.id, "#{prefix}#{index}"} end)
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
      horizon_unit: column.horizon_unit
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
      color: card.color,
      archived: card.archived_at != nil,
      created_at: card.inserted_at,
      assignee: email_of(card.assignee_id),
      # A sub-board is a board in this document; the card points at it so an
      # import can rebuild the nesting without guessing.
      subcards: refs.boards[sub_board_id(card.id)],
      tags: tag_refs(card.id, refs),
      blocked_by: dependency_refs(card.id, refs),
      links: link_json(card.id, refs),
      checklist: checklist_json(card_id: card.id),
      comments: comment_json(card_id: card.id),
      status_updates: status_json(card_id: card.id),
      urls: url_json(card_id: card.id),
      fields: field_value_json([card_id: card.id], refs)
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
      assignee: email_of(page.assignee_id),
      checklist: checklist_json(page_id: page.id),
      comments: comment_json(page_id: page.id),
      status_updates: status_json(page_id: page.id),
      urls: url_json(page_id: page.id),
      fields: field_value_json([page_id: page.id], refs)
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
        where: c.board_id in ^board_ids,
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

  defp sub_board_id(card_id) do
    Repo.one(from(b in Board, where: b.parent_card_id == ^card_id, select: b.id))
  end

  defp tag_refs(card_id, refs) do
    Repo.all(
      from(t in "card_tags",
        where: t.card_id == ^card_id,
        select: t.tag_id,
        order_by: [asc: t.tag_id]
      )
    )
    |> Enum.map(&refs.tags[&1])
    |> Enum.reject(&is_nil/1)
  end

  defp dependency_refs(card_id, refs) do
    Repo.all(
      from(d in "card_dependencies",
        where: d.blocked_id == ^card_id,
        select: d.blocker_id,
        order_by: [asc: d.blocker_id]
      )
    )
    |> Enum.map(&refs.cards[&1])
    |> Enum.reject(&is_nil/1)
  end

  defp link_json(card_id, refs) do
    Repo.all(from(l in CardLink, where: l.from_id == ^card_id, order_by: [asc: l.id]))
    |> Enum.map(&%{kind: &1.kind, to: refs.cards[&1.to_id]})
    |> Enum.reject(&is_nil(&1.to))
  end

  defp checklist_json(owner) do
    Repo.all(
      from(i in ChecklistItem,
        where: ^owner_where(owner),
        order_by: [asc: i.position, asc: i.id],
        select: %{text: i.text, done: i.done, position: i.position}
      )
    )
  end

  defp comment_json(owner) do
    Repo.all(
      from(c in Comment,
        where: ^owner_where(owner),
        order_by: [asc: c.inserted_at, asc: c.id],
        select: %{body: c.body, written_at: c.inserted_at}
      )
    )
  end

  defp status_json(owner) do
    Repo.all(
      from(s in StatusUpdate,
        where: ^owner_where(owner),
        order_by: [asc: s.inserted_at, asc: s.id],
        select: %{health: s.health, body: s.body, written_at: s.inserted_at, author_id: s.user_id}
      )
    )
    |> Enum.map(fn update ->
      update |> Map.put(:author, email_of(update.author_id)) |> Map.delete(:author_id)
    end)
  end

  defp url_json(owner) do
    Repo.all(
      from(u in CardUrl,
        where: ^owner_where(owner),
        order_by: [asc: u.inserted_at, asc: u.id],
        select: %{url: u.url, title: u.title}
      )
    )
  end

  defp field_value_json(owner, refs) do
    Repo.all(from(v in FieldValue, where: ^owner_where(owner), order_by: [asc: v.id]))
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

  # Checklists, comments, status updates, web links and field values all hang
  # off either a card or a page, so one `where` builder serves all five.
  defp owner_where(card_id: card_id), do: dynamic([r], r.card_id == ^card_id)
  defp owner_where(page_id: page_id), do: dynamic([r], r.page_id == ^page_id)

  defp email_of(nil), do: nil

  defp email_of(user_id) do
    Repo.one(from(u in User, where: u.id == ^user_id, select: u.email))
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
