defmodule Slipdock.Wiki.Files do
  @moduledoc """
  Files in a board's wiki that are not pages (`Slipdock.Wiki.WikiFile`):
  stored, replaced, moved, archived and deleted, each change written to the
  wiki's change log as a `file` so a sync hears of it (W-103 R2.9).

  The bytes are copied into the uploads directory from a path — an upload
  the web server has already spooled to disk — and hashed on the way, a
  megabyte at a time, so a 250 MB file is never held in memory. They count
  against the board owner's storage like any upload.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Boards, Quota, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Changes, WikiFile}

  def get(id), do: Repo.get(WikiFile, id)

  @doc "The live files on these boards."
  def live(board_ids) do
    from(f in WikiFile, where: f.board_id in ^board_ids and is_nil(f.archived_at))
    |> Repo.all()
  end

  @doc "Where a file's bytes are on disk."
  def disk_path(%WikiFile{key: key}), do: Path.join(Boards.uploads_dir(), key)

  @doc """
  Stores the file at `source` in `board`'s wiki: `attrs` has `name` and
  optionally `folder_id` and `content_type` (guessed from the name when
  absent).
  """
  def create(%Board{} = board, attrs, source, user \\ nil) do
    name = attrs[:name] || attrs["name"]
    {sha, size} = digest(source)
    key = key(board, name)

    changeset =
      %WikiFile{board_id: board.id, created_by_id: user_id(user)}
      |> WikiFile.changeset(%{
        name: name,
        folder_id: attrs[:folder_id] || attrs["folder_id"],
        content_type:
          attrs[:content_type] || attrs["content_type"] || WikiFile.content_type(name),
        size: size,
        sha256: sha,
        key: key
      })
      |> Quota.enforce(board.id, :items)
      |> Quota.enforce(board.id, :storage, want: size)

    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- copy(source, key),
         {:ok, file} <- Repo.insert(changeset) do
      touched(file)
      # Pages that embed or link this file by name before it arrived.
      Wiki.resolve_waiting(board.id, [file.name])
      {:ok, file}
    end
  end

  @doc """
  New bytes for a file, and optionally a new `name` and `folder_id`. The old
  bytes go once the new ones are in.
  """
  def replace(%WikiFile{} = file, attrs, source) do
    {sha, size} = digest(source)
    name = attrs[:name] || file.name
    key = key(%Board{id: file.board_id}, name)

    changeset =
      file
      |> WikiFile.changeset(%{
        name: name,
        folder_id: Map.get(attrs, :folder_id, file.folder_id),
        content_type: WikiFile.content_type(name),
        size: size,
        sha256: sha,
        key: key
      })
      |> Quota.enforce(file.board_id, :storage, want: max(size - file.size, 0))

    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :update),
         :ok <- copy(source, key),
         {:ok, updated} <- Repo.update(changeset) do
      Boards.remove_files([file.key])
      touched(updated)
      {:ok, updated}
    end
  end

  @doc "Renames a file or files it elsewhere: `name`, `folder_id`."
  def move(%WikiFile{} = file, attrs) do
    with {:ok, moved} <-
           file
           |> WikiFile.changeset(%{
             name: attrs[:name] || file.name,
             folder_id: Map.get(attrs, :folder_id, file.folder_id)
           })
           |> Repo.update() do
      touched(moved)
      {:ok, moved}
    end
  end

  @doc """
  Whether another live file on `board_id` already has `name` in the folder
  `folder_id` (nil: the top of the wiki), case aside — the one path on disk
  a vault would give them both.
  """
  def taken?(board_id, folder_id, name, except_id \\ nil) do
    from(f in WikiFile,
      where: f.board_id == ^board_id and is_nil(f.archived_at),
      where: fragment("lower(?)", f.name) == ^String.downcase(name)
    )
    |> where([f], ^folder_is(folder_id))
    |> where([f], f.id != ^(except_id || 0))
    |> Repo.exists?()
  end

  @doc "Puts a file away. The bytes stay, so it can come back."
  def archive(%WikiFile{} = file) do
    at = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, archived} <- file |> Ecto.Changeset.change(archived_at: at) |> Repo.update() do
      Changes.record(file.board_id, "file", file.id, "archived")
      Wiki.broadcast_board(file.board_id)
      {:ok, archived}
    end
  end

  @doc """
  Deletes a file for good: its row, and its bytes on disk, which is what
  gives the owner's storage back. A sync hears of it as `deleted` and takes
  its copy away too.
  """
  def delete(%WikiFile{} = file) do
    with {:ok, deleted} <- Repo.delete(file) do
      Boards.remove_files([file.key])
      Changes.record(file.board_id, "file", file.id, "deleted")
      Wiki.broadcast_board(file.board_id)
      {:ok, deleted}
    end
  end

  @doc """
  The file `![[target]]` names from a page on `board`, for `reader`: by name
  on the board, then across its vault, `Folder/name.png` narrowing to files
  whose folder path ends that way. The board's own file wins, then the
  shortest folder path. Nil when there is none the reader can see.
  """
  def resolve(%Board{} = board, target, reader), do: lookup(board, target, reader, true)

  @doc """
  As `resolve/3`, but with no reader it looks as the system does — what a
  page's stored links are worked out as, whoever is looking (see
  `Slipdock.Wiki.Links`). With a reader it is `resolve/3`.
  """
  def find(%Board{} = board, target, nil), do: lookup(board, target, nil, false)
  def find(%Board{} = board, target, reader), do: resolve(board, target, reader)

  defp lookup(board, target, reader, check?) do
    # `../attachments/x.png`, as Obsidian writes a relative link: the
    # folders it names, wherever they are.
    parts =
      target
      |> to_string()
      |> String.split("/", trim: true)
      |> Enum.reject(&(&1 in [".", ".."]))

    case parts do
      [] ->
        nil

      _ ->
        {dirs, [name]} = Enum.split(parts, -1)

        board_ids =
          case Slipdock.Vaults.for_board(board) do
            nil -> [board.id]
            vault -> Slipdock.Vaults.board_ids(vault)
          end

        from(f in WikiFile,
          where: f.board_id in ^board_ids and is_nil(f.archived_at),
          where: fragment("lower(?)", f.name) == ^String.downcase(name),
          preload: [:folder, :board]
        )
        |> Repo.all()
        |> Enum.map(&{&1, folder_segments(&1)})
        |> Enum.filter(fn {_f, segments} ->
          ends_with?(segments, Enum.map(dirs, &String.downcase/1))
        end)
        |> Enum.filter(fn {f, _} ->
          not check? or
            Slipdock.Access.can_read?(Slipdock.Access.board_permission(reader, f.board))
        end)
        |> Enum.sort_by(fn {f, segments} -> {f.board_id != board.id, length(segments), f.id} end)
        |> case do
          [{file, _} | _] -> file
          [] -> nil
        end
    end
  end

  defp folder_segments(%WikiFile{folder: nil}), do: []

  defp folder_segments(%WikiFile{folder: folder}),
    do: folder |> Wiki.folder_path() |> String.downcase() |> String.split("/", trim: true)

  defp ends_with?(list, suffix),
    do: length(suffix) <= length(list) and Enum.take(list, -length(suffix)) == suffix

  @doc "The browser path a file is served from."
  def url(%WikiFile{id: id, name: name}), do: "/wiki-files/#{id}/#{URI.encode(name)}"

  @doc """
  Where a file opens when somebody clicks it, in the tree or as a
  `[[link]]`: a whole note Meld encrypted where the browser can decrypt it,
  a drawing in the Excalidraw editor, anything else in the file viewer
  (`SlipdockWeb.FileLive`), which offers the download too.
  """
  def open_path(%WikiFile{id: id, name: name} = file) do
    cond do
      Slipdock.Wiki.Meld.note_file?(name) -> url(file) <> "?view=locked"
      Slipdock.Wiki.Excalidraw.name?(name) -> "/drawings/file/#{id}"
      true -> "/files/#{id}"
    end
  end

  @doc "The sha256 and size of a file on disk, read a megabyte at a time."
  def digest(path) do
    File.stream!(path, 1_048_576)
    |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn chunk, {ctx, n} ->
      {:crypto.hash_update(ctx, chunk), n + byte_size(chunk)}
    end)
    |> then(fn {ctx, n} -> {:crypto.hash_final(ctx) |> Base.encode16(case: :lower), n} end)
  end

  defp key(board, name) do
    ext = name |> to_string() |> Path.extname() |> String.downcase()
    ext = if Regex.match?(~r/^\.[a-z0-9]{1,12}$/, ext), do: ext, else: ""
    Path.join(["wiki", Integer.to_string(board.id), Ecto.UUID.generate() <> ext])
  end

  defp copy(source, key) do
    dest = Path.join(Boards.uploads_dir(), key)

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _} <- File.copy(source, dest) do
      :ok
    else
      {:error, reason} ->
        {:error, :unprocessable_entity, "could not store the file: #{inspect(reason)}"}
    end
  end

  defp touched(file) do
    Changes.record(file.board_id, "file", file.id)
    Wiki.broadcast_board(file.board_id)
  end

  defp folder_is(nil), do: dynamic([f], is_nil(f.folder_id))
  defp folder_is(id), do: dynamic([f], f.folder_id == ^id)

  defp user_id(%User{id: id}), do: id
  defp user_id(_), do: nil
end
