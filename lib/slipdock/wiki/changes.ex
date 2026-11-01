defmodule Slipdock.Wiki.Changes do
  @moduledoc """
  The wiki's change log, and the feed a vault's sync polls (W-103 R2.8).

  Every mutation of a page, a folder, a page's attachment or a wiki file
  (`Slipdock.Wiki.WikiFile`) appends a row:
  `board`, `subject` and its id, and what happened (`changed`, `moved`,
  `archived`, `restored`, `deleted`). The row's id is the **cursor**, increasing and
  never reused, so "what has changed since cursor 812?" has one exact answer
  however many boards a vault spans.

  Rows are written for every board, not just boards in a vault: it costs a
  row per save, and a board that joins a vault later needs nothing backfilled
  — a client starting out lists the vault, then follows the feed.

  Rows older than a retention window (`config :slipdock, :wiki_changes,
  retention_days: 90`) are pruned (`prune/1`). A client asking from a cursor
  older than what is kept is told `resync: true`: re-list the vault, because
  some changes — deletions among them — are no longer here to be read.

  **Moves.** A card, a short name or a board renamed changes paths without
  touching what lies under them, so `tracking/2` compares where everything
  was before the rename with where it is after and writes a `moved` row, with
  the old path in `from_path`, for each thing whose path is different: the
  folder and everything under it, and anything a clash renumbered. It costs a
  placing of the vault (no bodies) on each side of a rename of something that
  has a folder, and nothing on any other save.

  A change is also announced on `"vault_changes:<vault id>"` as
  `{:vault_change, vault_id, cursor}`, which is what the websocket channel
  passes on, so an open client knows to poll rather than polling blind.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Vaults}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Attachment, Board}
  alias Slipdock.Vaults.{Layout, Names, Vault}
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Change, Folder, Page, Placement, WikiFile}

  @pubsub Slipdock.PubSub

  ## Writing ------------------------------------------------------------------

  @doc "Appends one change. Never fails the write it records."
  def record(board_id, subject, subject_id, action \\ "changed")

  def record(board_id, subject, subject_id, action)
      when is_integer(board_id) and is_integer(subject_id) do
    {1, [%{id: cursor}]} =
      Repo.insert_all(
        Change,
        [
          %{
            board_id: board_id,
            subject: subject,
            subject_id: subject_id,
            action: action,
            inserted_at: DateTime.utc_now()
          }
        ],
        returning: [:id]
      )

    announce(board_id, cursor)
    :ok
  rescue
    # A log row is never worth losing a save over (a board deleted a moment
    # ago, say). The next change brings the feed up to date anyway.
    _ -> :ok
  end

  def record(_board_id, _subject, _subject_id, _action), do: :ok

  @doc "`record/4` for several pages at once (an archive takes its children)."
  def record_pages(board_id, ids, action),
    do: Enum.each(ids, &record(board_id, "page", &1, action))

  @doc """
  Runs `fun`, a rename on `board_id` that may change paths, and records what
  it moved in the board's vault. Answers what `fun` does. A nil `board_id`
  says nothing can move, and just runs it. Never fails the write it records.
  """
  def tracking(nil, fun), do: fun.()

  def tracking(board_id, fun) do
    vault = Vaults.for_board(board_id)
    before = vault && before_rename(vault)
    result = fun.()
    if before, do: record_moves(vault, before)
    result
  end

  defp before_rename(vault) do
    places(vault)
  rescue
    _ -> nil
  end

  # Where everything is, as `{subject, id} => {board_id, path}`.
  defp places(vault), do: vault |> Layout.build() |> places_in()

  defp places_in(layout) do
    pages = for {id, p} <- layout.pages, do: {{"page", id}, {p.board_id, p.path}}
    files = for {id, f} <- layout.files, do: {{"file", id}, {f.board_id, f.path}}
    folders = for {id, d} <- layout.folders, do: {{"folder", id}, {layout.folder_boards[id], d}}
    boards = for {id, dir} <- layout.boards, do: {{"board", id}, {id, dir}}

    Map.new(pages ++ files ++ folders ++ boards)
  end

  defp record_moves(vault, before) do
    now = places(vault)

    moved =
      for {key, {board_id, path}} <- now,
          {_board, was} <- [before[key]],
          was != path do
        {key, board_id, was}
      end

    rows =
      Enum.map(moved, fn {{subject, id}, board_id, was} ->
        row(board_id, subject, id, "moved", was, DateTime.utc_now())
      end)

    insert(vault, rows ++ rewritten(moved, now))
  rescue
    _ -> :ok
  end

  # A file names the other folders its page is filed in (`also-in`), so a
  # folder moving changes the bytes of a page that stayed where it was.
  defp rewritten(moved, now) do
    folder_ids = for {{"folder", id}, _board, _was} <- moved, do: id
    moved_pages = MapSet.new(for {{"page", id}, _board, _was} <- moved, do: id)

    from(pl in Placement, where: pl.folder_id in ^folder_ids, select: pl.page_id)
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(moved_pages, &1))
    |> Enum.flat_map(fn id ->
      case now[{"page", id}] do
        {board_id, _path} -> [row(board_id, "page", id, "changed", nil, DateTime.utc_now())]
        nil -> []
      end
    end)
  end

  defp row(board_id, subject, subject_id, action, from_path, at) do
    %{
      board_id: board_id,
      subject: subject,
      subject_id: subject_id,
      action: action,
      from_path: from_path,
      inserted_at: at
    }
  end

  # A move can be thousands of rows, and one announcement is enough for them.
  defp insert(_vault, []), do: :ok

  defp insert(%Vault{id: vault_id}, rows) do
    cursor =
      rows
      |> Enum.chunk_every(1000)
      |> Enum.map(fn chunk ->
        {_count, ids} = Repo.insert_all(Change, chunk, returning: [:id])
        ids |> Enum.map(& &1.id) |> Enum.max()
      end)
      |> Enum.max()

    Phoenix.PubSub.broadcast(@pubsub, topic(vault_id), {:vault_change, vault_id, cursor})
  end

  defp announce(board_id, cursor) do
    case Vaults.for_board(board_id) do
      %Vault{id: vault_id} ->
        Phoenix.PubSub.broadcast(@pubsub, topic(vault_id), {:vault_change, vault_id, cursor})

      nil ->
        :ok
    end
  end

  @doc "The PubSub topic a vault's changes are announced on."
  def topic(vault_id), do: "vault_changes:#{vault_id}"

  @doc "Listens for a vault's changes: `{:vault_change, vault_id, cursor}`."
  def subscribe(vault_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(vault_id))

  ## The feed -----------------------------------------------------------------

  @doc """
  What changed in a vault after `since`, for `reader`:

      %{changes: [...], cursor: 931, more: false}

  Each subject appears once, at its latest change in the window, with what
  it is now — a page's code, title, icon, colour, position, times,
  `content_hash`, home folder, whether it is archived, and its vault path; a
  folder's path, title, short name, card id, icon, colour, position, sort and
  times; a file's path, title, folder, times, size and hash; a board's path
  and title; an attachment's page, name and size — or `deleted` when it is
  gone. `path` is the one the listing has, built from disk names, and nil for
  what is archived itself and so has no file. `archived` is true for what is
  archived itself, and for whatever sits under an archived card, which keeps
  its path; only the former has a nil `path`. An archived board is out of the
  feed but for its own `archived` and `restored` changes.

  A subject whose path changed in the window is `moved`, with `from_path`
  the path it had at the start of the window: however many times it moved, a
  client holding the old path has what it needs, and a subject that came back
  to where it was is merely `changed`. Edited as well as moved, it is still
  `moved`; compare hashes for the bytes.

  A new icon or colour is a change like any other, and leaves
  `content_hash` and the sync hash alone, since neither is in the file. Pages the reader cannot open
  are left out. Pass the `cursor` back as `since` next time; `more: true`
  means call again straight away.

  `since: nil` answers with no changes and the cursor as it stands, which is
  where a client that has just listed the vault starts following from.
  """
  def since(%Vault{} = vault, since, %User{} = reader, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 500) |> max(1) |> min(1000)
    # An API token scoped to some boards sees those boards' changes only.
    board_ids =
      vault
      |> Vaults.board_ids()
      |> Enum.filter(&(Access.narrow(:read, opts[:token], &1) |> elem(0) != :none))

    case since do
      nil ->
        %{changes: [], cursor: latest(board_ids), more: false, resync: false}

      since when is_integer(since) ->
        if pruned_past?(since),
          do: %{changes: [], cursor: latest(board_ids), more: false, resync: true},
          else: window(vault, board_ids, since, reader, limit)
    end
  end

  # An archived board's tree is out of the vault's (W-2201): of it, only the
  # board's own change comes, archived or restored, so a client drops its
  # folder, or lists again to have it back.
  defp window(vault, board_ids, since, reader, limit) do
    hidden = vault |> Vaults.hidden_board_ids() |> MapSet.to_list()
    shown = board_ids -- hidden

    rows =
      from(c in Change,
        where:
          (c.board_id in ^shown or (c.board_id in ^hidden and c.subject == "board")) and
            c.id > ^since,
        order_by: [asc: c.id],
        limit: ^(limit + 1)
      )
      |> Repo.all()

    {rows, more?} =
      if length(rows) > limit, do: {Enum.take(rows, limit), true}, else: {rows, false}

    cursor = if rows == [], do: since, else: List.last(rows).id

    %{changes: describe(rows, vault, reader), cursor: cursor, more: more?, resync: false}
  end

  ## Keeping it short ---------------------------------------------------------

  @doc "How many days of changes are kept."
  def retention_days,
    do: Application.get_env(:slipdock, :wiki_changes, [])[:retention_days] || 90

  @doc """
  Deletes the rows older than the retention window, as of `now`. Returns how
  many went. A client whose cursor falls among them is told to resync.
  """
  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -retention_days(), :day)

    {count, ids} =
      Repo.delete_all(from(c in Change, where: c.inserted_at < ^cutoff, select: c.id))

    if ids != [] do
      up_to = Enum.max(ids)

      Repo.query!(
        """
        INSERT INTO wiki_change_marks (name, cursor) VALUES ('pruned', $1)
        ON CONFLICT (name) DO UPDATE SET cursor = GREATEST(wiki_change_marks.cursor, EXCLUDED.cursor)
        """,
        [up_to]
      )
    end

    count
  end

  @doc "`prune/1`, at most once an hour on this node, for a clock that ticks every minute."
  def prune_hourly(now \\ DateTime.utc_now()) do
    last = :persistent_term.get({__MODULE__, :pruned_at}, nil)

    if is_nil(last) or DateTime.diff(now, last) >= 3600 do
      :persistent_term.put({__MODULE__, :pruned_at}, now)
      prune(now)
    else
      0
    end
  end

  # Whether rows after `since` have been pruned: the highest cursor pruned
  # so far is kept, and a client below it may have missed something.
  defp pruned_past?(since) do
    case Repo.query!("SELECT cursor FROM wiki_change_marks WHERE name = 'pruned'") do
      %{rows: [[pruned]]} -> since < pruned
      _ -> false
    end
  end

  defp latest([]), do: 0

  defp latest(board_ids),
    do: Repo.one(from(c in Change, where: c.board_id in ^board_ids, select: max(c.id))) || 0

  # The latest row per subject, in the order those rows were written, each
  # with what its subject is now.
  defp describe(rows, vault, reader) do
    latest =
      rows
      |> Enum.reverse()
      |> Enum.uniq_by(&{&1.subject, &1.subject_id})
      |> Enum.reverse()

    from =
      rows
      |> Enum.reject(&is_nil(&1.from_path))
      |> Enum.uniq_by(&{&1.subject, &1.subject_id})
      |> Map.new(&{{&1.subject, &1.subject_id}, &1.from_path})

    place = if rows == [], do: nil, else: place(vault)

    latest
    |> Enum.flat_map(&entry(&1, place, reader))
    |> Enum.map(&moved(&1, from[{&1.subject, &1.id}]))
  end

  defp place(vault) do
    layout = Layout.build(vault)
    %{layout: layout, names: Names.build(layout)}
  end

  # A move stays a move under later saves, and one undone is no move at all.
  defp moved(%{action: action} = change, was) when action in ["changed", "moved"] do
    path = change[:path]

    if is_nil(was) or is_nil(path) or was == path,
      do: %{change | action: "changed"},
      else: Map.merge(change, %{action: "moved", from_path: was})
  end

  defp moved(change, _was), do: change

  defp entry(%Change{subject: "page"} = row, %{layout: layout, names: names}, reader) do
    case Repo.get(Page, row.subject_id) do
      nil ->
        [base(row, "deleted")]

      page ->
        if Wiki.visible?(page, Access.page_permission(reader, page)) do
          [
            row
            |> base(row.action)
            |> Map.merge(%{
              code: page.code,
              title: page.title,
              icon: page.icon,
              color: page.color,
              position: page.position,
              inserted_at: page.inserted_at,
              updated_at: page.updated_at,
              content_hash: page.content_hash,
              folder_id: page.folder_id,
              parent_id: page.parent_id,
              short_name: nil,
              archived:
                not is_nil(page.archived_at) or under_archived?(layout.pages[page.id], names),
              path: layout.pages[page.id][:path]
            })
          ]
        else
          []
        end
    end
  end

  defp entry(%Change{subject: "folder"} = row, %{layout: layout, names: names}, _reader) do
    case Repo.get(Folder, row.subject_id) do
      nil ->
        [base(row, "deleted")]

      folder ->
        name = names.folders[folder.id] || %{}

        [
          row
          |> base(row.action)
          |> Map.merge(%{
            name: folder.name,
            title: name[:title] || folder.name,
            short_name: name[:short_name],
            card_id: folder.card_id,
            archived: name[:archived] == true,
            path: layout.folders[folder.id],
            icon: folder.icon,
            color: folder.color,
            position: folder.position,
            sort: folder.sort,
            inserted_at: folder.inserted_at,
            updated_at: folder.updated_at
          })
        ]
    end
  end

  defp entry(%Change{subject: "attachment"} = row, _place, reader) do
    case Repo.get(Attachment, row.subject_id) |> Repo.preload(:page) do
      nil ->
        [base(row, "deleted")]

      %Attachment{page: %Page{} = page} = a ->
        if Wiki.visible?(page, Access.page_permission(reader, page)),
          do: [
            row
            |> base(row.action)
            |> Map.merge(%{page_id: page.id, filename: a.filename, size: a.size})
          ],
          else: []

      _ ->
        []
    end
  end

  defp entry(%Change{subject: "file"} = row, %{layout: layout, names: names}, reader) do
    case Repo.get(WikiFile, row.subject_id) do
      nil ->
        [base(row, "deleted")]

      file ->
        board = Repo.get(Board, file.board_id)

        if board && Access.can_read?(Access.board_permission(reader, board)),
          do: [
            row
            |> base(row.action)
            |> Map.merge(%{
              name: file.name,
              title: file.name,
              short_name: nil,
              path: layout.files[file.id][:path],
              folder_id: file.folder_id,
              inserted_at: file.inserted_at,
              updated_at: file.updated_at,
              size: file.size,
              sha256: file.sha256,
              archived:
                not is_nil(file.archived_at) or under_archived?(layout.files[file.id], names)
            })
          ],
          else: []
    end
  end

  defp entry(%Change{subject: "board"} = row, %{layout: layout, names: names}, reader) do
    board = Repo.get(Board, row.subject_id)

    cond do
      is_nil(board) ->
        [base(row, "deleted")]

      Access.can_read?(Access.board_permission(reader, board)) ->
        [
          row
          |> base(row.action)
          |> Map.merge(%{
            name: board.name,
            title: board.name,
            short_name: nil,
            path: layout.boards[board.id],
            archived: names.boards[board.id][:archived] == true
          })
        ]

      true ->
        []
    end
  end

  defp entry(_row, _place, _reader), do: []

  defp under_archived?(nil, _names), do: false
  defp under_archived?(%{dir: dir}, names), do: Names.archived?(names, dir)

  defp base(row, action),
    do: %{
      cursor: row.id,
      subject: row.subject,
      id: row.subject_id,
      board_id: row.board_id,
      action: action,
      at: row.inserted_at
    }
end
