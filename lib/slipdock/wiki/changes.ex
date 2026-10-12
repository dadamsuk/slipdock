defmodule Slipdock.Wiki.Changes do
  @moduledoc """
  The wiki's change log, and the feed a vault's sync polls (W-103 R2.8).

  Every mutation of a page, a folder or a page's attachment appends a row:
  `board`, `subject` and its id, and what happened (`changed`, `archived`,
  `restored`, `deleted`). The row's id is the **cursor**, increasing and
  never reused, so "what has changed since cursor 812?" has one exact answer
  however many boards a vault spans.

  Rows are written for every board, not just boards in a vault: it costs a
  row per save, and a board that joins a vault later needs nothing backfilled
  — a client starting out lists the vault, then follows the feed.

  Rows older than a retention window (`config :slipdock, :wiki_changes,
  retention_days: 90`) are pruned (`prune/1`). A client asking from a cursor
  older than what is kept is told `resync: true`: re-list the vault, because
  some changes — deletions among them — are no longer here to be read.

  A change is also announced on `"vault_changes:<vault id>"` as
  `{:vault_change, vault_id, cursor}`, which is what the websocket channel
  passes on, so an open client knows to poll rather than polling blind.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Vaults}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Attachment
  alias Slipdock.Vaults.{Index, Vault}
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Change, Folder, Page}

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
  it is now — a page's code, title, `content_hash`, home folder, whether it
  is archived, and its vault path; a folder's path; an attachment's page,
  name and size — or `deleted` when it is gone. Pages the reader cannot open
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

  defp window(vault, board_ids, since, reader, limit) do
    rows =
      from(c in Change,
        where: c.board_id in ^board_ids and c.id > ^since,
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

    paths = if Enum.any?(latest, &(&1.subject == "page")), do: page_paths(vault), else: %{}

    Enum.flat_map(latest, &entry(&1, paths, reader))
  end

  defp page_paths(vault), do: vault |> Index.build() |> Map.new(&{&1.id, "/" <> &1.path})

  defp entry(%Change{subject: "page"} = row, paths, reader) do
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
              content_hash: page.content_hash,
              folder_id: page.folder_id,
              parent_id: page.parent_id,
              archived: not is_nil(page.archived_at),
              path: paths[page.id]
            })
          ]
        else
          []
        end
    end
  end

  defp entry(%Change{subject: "folder"} = row, _paths, _reader) do
    case Repo.get(Folder, row.subject_id) do
      nil ->
        [base(row, "deleted")]

      folder ->
        [
          row
          |> base(row.action)
          |> Map.merge(%{name: folder.name, path: Wiki.folder_path(folder)})
        ]
    end
  end

  defp entry(%Change{subject: "attachment"} = row, _paths, reader) do
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

  defp entry(_row, _paths, _reader), do: []

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
