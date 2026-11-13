defmodule Slipdock.Boards.Attachments do
  @moduledoc """
  Files on a card or a wiki page: attachments stored, hidden, transcribed and
  removed, and the storage keys and paths behind them.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Attachment
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Quota
  alias Slipdock.Repo
  alias Slipdock.Search.Indexer
  alias Slipdock.Wiki.Changes

  ## Attachments

  @doc "The directory uploaded files are stored in (see `:uploads_dir` in config)."
  def uploads_dir do
    Slipdock.Config.get(:uploads_dir) ||
      Path.join(:code.priv_dir(:slipdock), "uploads")
  end

  @doc "The absolute path of an attachment's file on disk."
  def attachment_path(%Attachment{key: key}), do: Path.join(uploads_dir(), key)

  def get_attachment!(id), do: Attachment |> Repo.get!(id) |> Repo.preload([:card, :page])

  @doc """
  Attaches a file to the card. `meta` names the file (`:filename`,
  `:content_type`, and optionally `:size`); `source` is the path of the
  uploaded bytes, which are copied into the uploads directory.
  """
  def add_attachment(%Card{} = card, meta, source) do
    with {:ok, attachment} <-
           store_attachment(%{card_id: card.id}, Integer.to_string(card.id), meta, source) do
      Boards.ActivityLog.log(
        Repo,
        card.board_id,
        card.id,
        "attachment",
        "attached #{attachment.filename} to “#{card.title}”"
      )

      Boards.PubSub.broadcast(card.board_id)
      {:ok, attachment}
    end
  end

  @doc """
  Puts an uploaded file on disk and records it, whatever it hangs off.

  `owner` is `%{card_id: id}` or `%{page_id: id}`; `folder` is the directory
  under the uploads root the bytes go in. Shared so the wiki's paste-an-image
  is the same code path as a card's, rather than a second one to keep honest.
  """
  def store_attachment(owner, folder, meta, source) when is_map(owner) do
    ext = meta |> Map.get(:filename, "") |> Path.extname() |> String.downcase() |> safe_ext()
    key = Path.join(folder, Ecto.UUID.generate() <> ext)

    owner
    |> attachment_changeset(key, meta, source)
    |> insert_attachment(source, key)
  end

  defp attachment_changeset(owner, key, meta, source) do
    size = Map.get(meta, :size) || File.stat!(source).size
    scope = attachment_scope(owner)

    Attachment.changeset(
      struct(Attachment, owner),
      Map.merge(owner, %{
        filename: meta[:filename],
        content_type: meta[:content_type],
        size: size,
        key: key,
        hide_on_card: Map.get(meta, :hide_on_card, false)
      })
    )
    # An upload is both a thing stored and bytes on a disk, so it is checked
    # against both limits before a single byte is copied anywhere.
    |> Quota.enforce(scope, :items)
    |> Quota.enforce(scope, :storage, want: size)
  end

  defp insert_attachment(changeset, source, key) do
    # The hash is of the copy as it landed on disk, not of what was sent, so
    # it vouches for what a download will return (#1015).
    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- store_file(source, key),
         {sha256, _size} = Attachment.file_sha256(Path.join(uploads_dir(), key)),
         {:ok, attachment} <- Repo.insert(Ecto.Changeset.put_change(changeset, :sha256, sha256)) do
      Slipdock.OCR.enqueue(attachment)
      {:ok, attachment}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}

      {:error, reason} ->
        {:error,
         Ecto.Changeset.add_error(changeset, :key, "could not be stored: #{inspect(reason)}")}
    end
  end

  @doc """
  Hashes the stored file of every attachment that has no `sha256` yet — rows
  from before it was kept (#1015) — and records it. A file missing from disk
  is left as it is, nil, rather than given a hash of nothing. Returns how
  many were filled in. Run on boot, so it is safe to run again.
  """
  def backfill_attachment_hashes do
    from(a in Attachment, where: is_nil(a.sha256), select: %{id: a.id, key: a.key})
    |> Repo.all()
    |> Enum.count(fn %{id: id, key: key} ->
      path = Path.join(uploads_dir(), key)

      if File.regular?(path) do
        {sha256, _size} = Attachment.file_sha256(path)

        {n, _} =
          Repo.update_all(from(a in Attachment, where: a.id == ^id and is_nil(a.sha256)),
            set: [sha256: sha256]
          )

        n == 1
      else
        false
      end
    end)
  end

  # Which board's owner pays for this file: the card's, or the page's.
  defp attachment_scope(%{card_id: card_id}) when not is_nil(card_id),
    do: Repo.one(from(c in Card, where: c.id == ^card_id, select: c.board_id))

  defp attachment_scope(%{page_id: page_id}) when not is_nil(page_id),
    do: Repo.one(from(p in Slipdock.Wiki.Page, where: p.id == ^page_id, select: p.board_id))

  defp attachment_scope(_owner), do: nil

  @doc """
  Keeps an image off the front of its card (`hide? = true`), or puts it back.
  The card's front shows the first image that is not kept off it.
  """
  def hide_attachment_on_card(%Attachment{} = attachment, hide?) when is_boolean(hide?) do
    attachment
    |> Attachment.front_changeset(hide?)
    |> Repo.update()
    |> Boards.Shared.tap_ok(&broadcast_attachment/1)
  end

  @doc "Records where a transcription has got to (see `Slipdock.Transcription`)."
  def update_attachment_transcript(%Attachment{} = attachment, attrs) do
    attachment
    |> Attachment.transcript_changeset(attrs)
    |> Repo.update()
    |> Boards.Shared.tap_ok(fn a ->
      broadcast_attachment(a)
      # A finished transcript is something to find (see `Slipdock.Search.Chunk`).
      if a.card_id && a.transcript_status == "done", do: Indexer.enqueue(a.card_id)
    end)
  end

  @doc "Text has been read from an attachment (see `Slipdock.OCR`): show it, and index it."
  def attachment_text_changed(%Attachment{} = attachment) do
    broadcast_attachment(attachment)
    Indexer.enqueue(attachment.card_id)
    Indexer.enqueue_page(attachment.page_id)
  end

  defp broadcast_attachment(attachment) do
    case Repo.preload(attachment, [:card, :page]) do
      %Attachment{card: %Card{board_id: board_id}} -> Boards.PubSub.broadcast(board_id)
      %Attachment{page: %{board_id: board_id}} -> Boards.PubSub.broadcast(board_id)
      _ -> :ok
    end
  end

  def delete_attachment(%Attachment{} = attachment) do
    attachment = Repo.preload(attachment, [:card, :page])

    Repo.delete(attachment)
    |> Boards.Shared.tap_ok(fn a ->
      remove_files([a.key])

      # Its text and transcript were in search; reindexing takes them out.
      Indexer.enqueue(a.card_id)
      Indexer.enqueue_page(a.page_id)

      case attachment do
        %Attachment{card: %Card{board_id: board_id}} ->
          Boards.PubSub.broadcast(board_id)

        %Attachment{page: %{board_id: board_id}} ->
          Changes.record(board_id, "attachment", a.id, "deleted")
          Boards.PubSub.broadcast(board_id)

        _ ->
          :ok
      end
    end)
  end

  @doc """
  Deletes the files on `kept`'s card or page that share its filename, so a
  rebuild uploaded with `replace` leaves one current copy (#1017). Runs after
  the new file is stored, so a refused upload never costs the old one.
  Answers the ids it deleted, oldest first.
  """
  def delete_namesakes(%Attachment{} = kept) do
    owner =
      case kept do
        %Attachment{card_id: id} when not is_nil(id) -> dynamic([a], a.card_id == ^id)
        %Attachment{page_id: id} -> dynamic([a], a.page_id == ^id)
      end

    from(a in Attachment,
      where: a.filename == ^kept.filename and a.id != ^kept.id,
      order_by: [asc: a.id]
    )
    |> where(^owner)
    |> Repo.all()
    |> Enum.flat_map(fn a ->
      case delete_attachment(a) do
        {:ok, _} -> [a.id]
        _ -> []
      end
    end)
  end

  @doc "The public path an attachment is served from."
  def attachment_url(%Attachment{} = a), do: "/attachments/#{a.id}/#{URI.encode(a.filename)}"

  defp store_file(source, key), do: put_file(source, key)

  @doc """
  Copies `source` into the uploads directory under `key`, making the folders
  it needs. Returns `:ok` or `{:error, reason}`.

  Folders are shared by many files, and `remove_files/1` takes a folder away
  once it is empty, so one could vanish between making it and copying into
  it (#1102, #1636, #2831). So the folder is made, and a placeholder put in
  it, under the lock `remove_files/1` takes a folder away under
  (`Slipdock.Boards.Attachments.Folders`): from then on the folder isn't
  empty and can't be taken. The copy runs outside the lock, into the
  placeholder, which is then renamed into place. Nothing is retried, and
  nothing races a clock: a store fails only for a reason that won't go
  away, such as a source that isn't there or a file standing where a
  folder on the way should be.
  """
  def put_file(source, key) do
    dest = Path.join(uploads_dir(), key)
    part = "#{dest}.storing-#{System.unique_integer([:positive])}"

    with :ok <- __MODULE__.Folders.run(fn -> hold_folder(part) end),
         {:ok, _} <- copy_or_drop(source, part) do
      case File.rename(part, dest) do
        :ok -> :ok
        error -> drop(part, error)
      end
    end
  end

  # Makes the folder `part` goes in and puts `part` in it, empty: run under
  # the folders' lock, so no removal can come between the two.
  defp hold_folder(part) do
    with :ok <- File.mkdir_p(Path.dirname(part)), do: File.touch(part)
  end

  defp copy_or_drop(source, part) do
    case File.copy(source, part) do
      {:ok, _} = ok -> ok
      error -> drop(part, error)
    end
  end

  defp drop(part, error) do
    File.rm(part)
    error
  end

  defp attachment_keys(query), do: Repo.all(from(a in query, select: a.key))

  @doc """
  The on-disk keys of every file deleting these cards takes with it: their
  own attachments, and everything on the boards beneath them — subcards'
  files, sub-board wiki pages' images, meeting recordings — which the
  database cascade deletes the rows of and leaves the bytes behind. Read
  them before the delete; hand them to `remove_files/1` after it.
  """
  def card_file_keys([]), do: []

  def card_file_keys(card_ids) when is_list(card_ids) do
    own = attachment_keys(from(a in Attachment, where: a.card_id in ^card_ids))

    case Enum.flat_map(card_ids, &Boards.Moves.subtree_board_ids/1) do
      [] -> own
      board_ids -> own ++ file_keys(from(b in Board, where: b.id in ^board_ids))
    end
  end

  @doc """
  The on-disk keys of every file on the boards `boards` selects — cards',
  wiki pages' and meeting recordings' alike. Read them before the rows go, and hand them to
  `remove_files/1` once the delete has committed: the database cascades take
  the rows, but nothing takes the bytes.
  """
  def file_keys(%Ecto.Query{} = boards) do
    ids = from(b in subquery(boards), select: b.id)

    attachment_keys(
      from(a in Attachment,
        left_join: c in assoc(a, :card),
        left_join: p in assoc(a, :page),
        where: c.board_id in subquery(ids) or p.board_id in subquery(ids)
      )
    ) ++
      Repo.all(
        from(f in Slipdock.Wiki.WikiFile, where: f.board_id in subquery(ids), select: f.key)
      ) ++ Slipdock.Wiki.Autosaves.board_keys(ids)
  end

  @doc "Removes uploaded files by key, and any folder they leave empty."
  def remove_files(keys) do
    dir = uploads_dir()

    Enum.each(keys, fn key ->
      path = Path.join(dir, key)
      File.rm(path)
      # Drop the card's folder once it's empty, under the lock a store makes
      # its folder under (see `put_file/2`).
      folder = Path.dirname(path)
      __MODULE__.Folders.run(fn -> File.rmdir(folder) end)
    end)
  end

  # Only keep a short, plain extension so the on-disk name is predictable.
  defp safe_ext(ext) do
    if Regex.match?(~r/^\.[a-z0-9]{1,8}$/, ext), do: ext, else: ""
  end

  ## Lookups (#2791): plain reads the web layer makes through this context

  @doc "The attachment `id`, or nil, with `preloads` loaded."
  def get_attachment(id, preloads \\ []) do
    case Repo.get(Attachment, id) do
      nil -> nil
      attachment -> Repo.preload(attachment, preloads)
    end
  end

  @doc "`attachment` with the text read from its document loaded."
  def with_document_text(%Attachment{} = attachment),
    do: Repo.preload(attachment, :document_text)
end

defmodule Slipdock.Boards.Attachments.Folders do
  @moduledoc """
  The lock between making a folder under the uploads directory and taking
  an empty one away (#2831). `run/1` runs a function in this one process,
  so two never overlap and each waits its turn: a store's folder can't be
  removed between `File.mkdir_p/1` and the placeholder that keeps it from
  being empty. The functions are short file operations on paths the caller
  worked out (a test's uploads directory is the caller's, not this
  process's).
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Runs `fun` under the lock, and answers what it returns."
  def run(fun) when is_function(fun, 0), do: GenServer.call(__MODULE__, {:run, fun}, :infinity)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:run, fun}, _from, state) do
    {:reply, fun.(), state}
  end
end
