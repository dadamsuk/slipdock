defmodule Slipdock.Vaults.Sync do
  @moduledoc """
  The server half of `slipdock sync` (W-103 R2): a vault as a folder of
  files, read and written one file at a time.

  **Files, not pages.** Everything here speaks in vault paths
  (`Projects/Acme/Call.md`) and in the exact bytes a sync writes for a page
  (`Slipdock.Wiki.Archive.sync_file/2`). A file's **hash** is the sha256 of
  those bytes, so it moves when anything in the file moves — the body, the
  title it carries, its front matter — and never when nothing in the file
  did. A client compares it with the hash of what is on its disk, and the two
  agree exactly when the two sides do.

  **Writes carry a base.** A write names the hash it was made against; when
  the page's file has moved on since, nothing is written and the call answers
  `{:error, :conflict, entry}` with the page as it now stands, which is what
  lets a sync keep both versions rather than lose one (R2.4).

  **A path is a place.** Writing a file at a new path files the page there:
  a new name is a new title (R2.10), a new directory a new folder or parent
  page (made as needed), and a directory under another board's mapping
  moves the page to that board — as a new page there, the old one archived,
  since a page's history belongs to its board.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Vaults
  alias Slipdock.Vaults.{Layout, Vault}

  alias Slipdock.Wiki.{
    Archive,
    Changes,
    Files,
    Folder,
    FrontMatter,
    Page,
    Placement,
    Placements,
    WikiFile
  }

  @doc "The sha256 of a file's bytes, as a sync compares them."
  def hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  ## Reading ------------------------------------------------------------------

  @doc """
  Every file of the vault `reader` may open — and with `stubs: true`, a
  stub for each thing shared with them and filed here (`Slipdock.Vaults.Stubs`,
  `%{kind: "stub", id:, path:, hash:, content:}`), with its directories in
  `folders`. `base_url` is what a stub's link starts with.

      %{cursor: 931, entries: [%{kind: "page", id:, board_id:, path:, hash:, code:, title:},
                               %{kind: "file", id:, board_id:, path:, hash:, size:, name:}],
        folders: ["Projects", "Projects/Acme"]}

  `folders` is every folder of the vault as a directory, empty ones too, so
  a client can make the ones it hasn't got and take away the ones the
  server no longer has. It is its own key rather than entries of a kind of
  their own, which a client from before it would take for pages.

  `cursor` is the change feed's position taken *before* the listing was
  read, so following the feed from it sees anything that changed while it
  was being made, rather than missing it.
  """
  def listing(%Vault{} = vault, %User{} = reader, opts \\ []) do
    %{cursor: cursor} = Changes.since(vault, nil, reader, token: opts[:token])
    layout = Layout.build(vault)
    levels = levels(vault, reader, opts[:token])

    also = also_in(layout, Map.keys(layout.pages))

    entries =
      layout.pages
      |> Map.keys()
      |> Enum.chunk_every(200)
      |> Enum.flat_map(fn ids ->
        from(p in Page, where: p.id in ^ids) |> Repo.all()
      end)
      |> Enum.filter(&Wiki.visible?(&1, Map.get(levels, &1.board_id, :none)))
      |> Enum.map(&(entry(layout, &1, also) |> Map.drop([:content])))

    files =
      layout.files
      |> Map.keys()
      |> then(&from(f in WikiFile, where: f.id in ^&1))
      |> Repo.all()
      |> Enum.filter(&Access.can_read?(Map.get(levels, &1.board_id, :none)))
      |> Enum.map(&file_entry(layout, &1))

    # What is shared with the reader and filed here, as stubs (#819), for
    # a client that knows what they are.
    {stubs, stub_dirs} =
      if opts[:stubs],
        do: Slipdock.Vaults.Stubs.build(vault, layout, reader, opts[:base_url] || ""),
        else: {[], []}

    entries = Enum.sort_by(entries ++ files ++ stubs, & &1.path)
    folders = Enum.sort(Enum.uniq(folders(layout, levels) ++ stub_dirs))

    %{cursor: cursor, entries: entries, folders: folders}
  end

  # The folders on the boards `levels` lets the reader open, as directories.
  # A folder mapped at the vault's root is the root itself, so no directory.
  defp folders(layout, levels) do
    ids = Map.keys(layout.folders)

    from(f in Folder, where: f.id in ^ids, select: {f.id, f.board_id})
    |> Repo.all()
    |> Enum.filter(fn {_id, board_id} -> Access.can_read?(Map.get(levels, board_id, :none)) end)
    |> Enum.map(fn {id, _board_id} -> layout.folders[id] end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "One page's file: `{:ok, %{id:, path:, hash:, content:, ...}}`."
  def read_page(%Vault{} = vault, %User{} = reader, id, opts \\ []) do
    layout = Layout.build(vault)

    with {:ok, page} <- vault_page(layout, id, reader, :read, opts) do
      {:ok, entry(layout, page)}
    end
  end

  # What a listing and every write answer with for a page.
  defp entry(layout, %Page{} = page, also \\ nil) do
    placed = layout.pages[page.id]
    also = also || also_in(layout, [page.id])

    content =
      Archive.sync_file(page,
        file_title: String.trim(placed.stem),
        also_in: Map.get(also, page.id, [])
      )

    %{
      kind: "page",
      id: page.id,
      board_id: page.board_id,
      code: page.code,
      title: page.title,
      path: placed.path,
      hash: hash(content),
      content: content
    }
  end

  # The other folders each page is filed in (R12.5), as vault paths, in the
  # order they were added. A folder in no mapped part of the vault has no
  # path to write, and is left out of the file (and alone on the server).
  defp also_in(layout, page_ids) do
    from(pl in Placement,
      where: pl.page_id in ^page_ids,
      order_by: [asc: pl.inserted_at, asc: pl.id],
      select: {pl.page_id, pl.folder_id}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {page_id, folder_id} ->
      case layout.folders[folder_id] do
        nil -> []
        "" -> []
        dir -> [{page_id, dir}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  ## Writing ------------------------------------------------------------------

  @doc """
  Writes a Markdown file into the vault: `params` carries `path`, `content`,
  and — for a page the client already knows — its `id` and the `base` hash
  the edit was made against. Without an `id` it is a new page, unless a page
  already has that path, which is a conflict.

  Answers `{:ok, entry}` with the file as the server now writes it, which
  may differ from what was sent (a title key patched after a rename); the
  client writes that back.
  """
  def write_page(%Vault{} = vault, %User{} = user, params, opts \\ []) do
    layout = Layout.build(vault)

    with {:ok, path} <- clean_path(params["path"]),
         {:ok, content} <- content(params["content"]),
         {:ok, current} <- current(layout, params["id"], user, opts),
         :ok <- check_base(layout, current, params["base"]),
         :ok <- path_free(layout, path, current, user),
         {where, stem} = location(layout, path, current),
         {:ok, board, parent_id, folder_ref} <- target(layout, where, user, opts) do
      attrs = attrs(content, stem, current, layout)

      result =
        cond do
          is_nil(current) ->
            with {:ok, folder_id} <- ensure_folder(board, folder_ref) do
              attrs
              |> Map.merge(%{"parent_id" => parent_id, "folder_id" => folder_id})
              |> then(&Wiki.create_page(board, &1, write_opts(user)))
            end

          current.board_id == board.id ->
            with {:ok, folder_id} <- ensure_folder(board, folder_ref) do
              Wiki.update_page(
                current,
                Map.merge(attrs, %{"parent_id" => parent_id, "folder_id" => folder_id}),
                write_opts(user) ++ [base_hash: current.content_hash]
              )
            end

          match?(%{children?: true}, layout.pages[current.id]) ->
            {:error, :unprocessable_entity,
             "#{current.code} has pages under it, so it can't move to another board by sync"}

          true ->
            # Another board: a page's history belongs to its board, so the
            # page there is a new one and this one is archived, recoverable.
            with {:ok, folder_id} <- ensure_folder(board, folder_ref),
                 {:ok, page} <-
                   attrs
                   |> Map.merge(%{"parent_id" => parent_id, "folder_id" => folder_id})
                   |> then(&Wiki.create_page(board, &1, write_opts(user))),
                 {:ok, _} <- Wiki.archive_page(current) do
              {:ok, page}
            end
        end

      with {:ok, page} <- result do
        place_also(vault, Repo.get!(Page, page.id), content, user)
        written = vault |> Layout.build() |> entry(Repo.get!(Page, page.id))

        {:ok,
         if(current && current.id != page.id,
           do: Map.put(written, :replaced, current.id),
           else: written
         )}
      end
    end
  end

  @doc """
  Archives a page whose file was deleted (R2.5): never purged, so a delete
  made by mistake is a restore away. Refused as a conflict when the page has
  changed since `base`, so an edit made elsewhere is not put away unseen.
  """
  def archive_page(%Vault{} = vault, %User{} = user, id, base, opts \\ []) do
    layout = Layout.build(vault)

    with {:ok, page} <- vault_page(layout, id, user, :write, opts),
         :ok <- check_base(layout, page, base),
         {:ok, archived} <- Wiki.archive_page(page) do
      {:ok, %{kind: "page", id: archived.id, archived: true}}
    end
  end

  # A file's `also-in` (R12.5) made true: placements in vault folders it no
  # longer names are taken away, the ones it names are added, their folders
  # made where missing. Placements in folders outside the vault's paths are
  # not the file's to say anything about, and stay. A path that can't be a
  # placement — the page's home, another vault's board — is simply left out,
  # and the file the server writes back shows that.
  defp place_also(vault, page, content, user) do
    {header, _body} = FrontMatter.split(content)

    wanted =
      case FrontMatter.get(FrontMatter.yaml(header), "also-in") do
        nil -> []
        path when is_binary(path) -> [path]
        paths -> paths
      end
      |> Enum.map(&String.trim(&1, "/"))
      |> Enum.reject(&(&1 == ""))

    layout = Layout.build(vault)
    in_vault = Placements.folders(page) |> Enum.filter(&Map.has_key?(layout.folders, &1.id))

    wanted_ids =
      Enum.flat_map(wanted, fn path ->
        case layout.folder_dirs[String.downcase(path)] do
          nil ->
            case Placements.folder_at(page, "/" <> path, create: true) do
              {:ok, folder} -> [folder.id]
              _ -> []
            end

          id ->
            [id]
        end
      end)

    for folder <- in_vault, folder.id not in wanted_ids, do: Placements.remove(page, folder, user)

    have = MapSet.new(in_vault, & &1.id)

    for id <- Enum.uniq(wanted_ids),
        id != page.folder_id,
        not MapSet.member?(have, id),
        do: Placements.add(page, Slipdock.Wiki.Folders.get!(id), user)

    :ok
  end

  ## Other files ---------------------------------------------------------------

  @doc """
  A file that is not a note (W-103 R2.9): `{:ok, %WikiFile{}, entry}`, for
  the caller to stream from `Slipdock.Wiki.Files.disk_path/1`.
  """
  def read_file(%Vault{} = vault, %User{} = reader, id, opts \\ []) do
    layout = Layout.build(vault)

    with {:ok, file} <- vault_file(layout, id, reader, :read, opts),
         do: {:ok, file, file_entry(layout, file)}
  end

  @doc """
  Stores the bytes at `source` as the file at `params["path"]`: a new file
  without an `id`, new bytes (and perhaps a new place) for one with. As
  `write_page/4`: a stale `base`, or a path another file has, is a conflict.
  """
  def write_file(%Vault{} = vault, %User{} = user, params, source, opts \\ []) do
    layout = Layout.build(vault)

    with {:ok, path} <- clean_path(params["path"], :file),
         {:ok, current} <- current_file(layout, params["id"], user, opts),
         :ok <- check_file_base(layout, current, params["base"]),
         :ok <- file_path_free(layout, path, current),
         {:ok, board, folder_ref} <- file_target(layout, path, user, opts),
         {:ok, folder_id} <- ensure_folder(board, folder_ref) do
      attrs = %{name: Path.basename(path), folder_id: folder_id}

      result =
        cond do
          is_nil(current) ->
            Files.create(board, attrs, source, user)

          current.board_id == board.id ->
            Files.replace(current, attrs, source)

          true ->
            with {:ok, file} <- Files.create(board, attrs, source, user),
                 {:ok, _} <- Files.archive(current),
                 do: {:ok, file}
        end

      with {:ok, file} <- result do
        written = vault |> Layout.build() |> file_entry(Repo.get!(WikiFile, file.id))

        {:ok,
         if(current && current.id != file.id,
           do: Map.put(written, :replaced, current.id),
           else: written
         )}
      end
    end
  end

  @doc """
  Renames or moves a file without sending its bytes again: what a rename
  on disk is. Between boards the bytes are copied to the new board's file.
  """
  def move_file(%Vault{} = vault, %User{} = user, id, params, opts \\ []) do
    layout = Layout.build(vault)

    with {:ok, path} <- clean_path(params["path"], :file),
         {:ok, file} <- vault_file(layout, id, user, :write, opts),
         :ok <- check_file_base(layout, file, params["base"]),
         :ok <- file_path_free(layout, path, file),
         {:ok, board, folder_ref} <- file_target(layout, path, user, opts),
         {:ok, folder_id} <- ensure_folder(board, folder_ref) do
      attrs = %{name: Path.basename(path), folder_id: folder_id}

      result =
        if board.id == file.board_id do
          Files.move(file, attrs)
        else
          with {:ok, moved} <- Files.create(board, attrs, Files.disk_path(file), user),
               {:ok, _} <- Files.archive(file),
               do: {:ok, moved}
        end

      with {:ok, moved} <- result do
        written = vault |> Layout.build() |> file_entry(Repo.get!(WikiFile, moved.id))
        {:ok, if(moved.id != file.id, do: Map.put(written, :replaced, file.id), else: written)}
      end
    end
  end

  @doc "Archives a file whose copy on disk was deleted, guarded by its base."
  def archive_file(%Vault{} = vault, %User{} = user, id, base, opts \\ []) do
    layout = Layout.build(vault)

    with {:ok, file} <- vault_file(layout, id, user, :write, opts),
         :ok <- check_file_base(layout, file, base),
         {:ok, archived} <- Files.archive(file) do
      {:ok, %{kind: "file", id: archived.id, archived: true}}
    end
  end

  defp file_entry(layout, %WikiFile{} = file) do
    %{
      kind: "file",
      id: file.id,
      board_id: file.board_id,
      name: file.name,
      path: layout.files[file.id].path,
      hash: file.sha256,
      size: file.size
    }
  end

  defp current_file(_layout, id, _user, _opts) when id in [nil, ""], do: {:ok, nil}
  defp current_file(layout, id, user, opts), do: vault_file(layout, id, user, :write, opts)

  defp vault_file(layout, id, user, need, opts) do
    with {:ok, id} <- int(id),
         %WikiFile{} = file <- Repo.get(WikiFile, id),
         true <- Map.has_key?(layout.files, file.id) do
      level = level(user, Repo.get!(Board, file.board_id), opts[:token])

      cond do
        not Access.can_read?(level) ->
          {:error, :not_found, "file #{id} in this vault"}

        need == :write and not Access.can_write?(level) ->
          {:error, :forbidden, "you don't edit #{file.name}"}

        true ->
          {:ok, file}
      end
    else
      {:error, _, _} = error -> error
      _ -> {:error, :not_found, "file #{id} in this vault"}
    end
  end

  defp check_file_base(_layout, nil, _base), do: :ok
  defp check_file_base(_layout, _file, base) when base in [nil, ""], do: :ok

  defp check_file_base(layout, file, base) do
    if String.downcase(String.trim(base)) == file.sha256,
      do: :ok,
      else: {:error, :conflict, file_entry(layout, file)}
  end

  defp file_path_free(layout, path, current) do
    case layout.file_paths[String.downcase(path)] do
      nil -> :ok
      id when not is_nil(current) and id == current.id -> :ok
      id -> {:error, :conflict, file_entry(layout, Repo.get!(WikiFile, id))}
    end
  end

  defp file_target(layout, path, user, opts) do
    case Layout.place(layout, path) do
      {:parent, _id} ->
        {:error, :unprocessable_entity,
         "#{Path.dirname(path)} is a page's own folder, which holds pages; keep files in a folder"}

      other ->
        with {:ok, board, nil, folder_ref} <- target(layout, other, user, opts),
             do: {:ok, board, folder_ref}
    end
  end

  ## The parts ----------------------------------------------------------------

  @doc """
  A vault path as a sync may name it: relative, forward slashes, no `.` or
  `..` segment, no hidden segment — ending in `.md` for a page (`:markdown`),
  and in anything else for a file (`:file`).
  """
  def clean_path(path, ext \\ :markdown)

  def clean_path(path, ext) when is_binary(path) do
    segments = path |> String.replace("\\", "/") |> String.split("/", trim: true)

    cond do
      segments == [] ->
        {:error, :bad_request, "say which file: a path in the vault"}

      Enum.any?(segments, &String.starts_with?(&1, ".")) ->
        {:error, :unprocessable_entity, "#{path}: hidden files and . or .. are not synced"}

      ext == :markdown and not String.ends_with?(String.downcase(path), ".md") ->
        {:error, :unprocessable_entity, "#{path} is not a Markdown file"}

      ext == :file and String.ends_with?(String.downcase(path), ".md") ->
        {:error, :unprocessable_entity, "#{path} is a Markdown file, so a page, not a file"}

      true ->
        {:ok, Enum.join(segments, "/")}
    end
  end

  def clean_path(_path, _ext), do: {:error, :bad_request, "say which file: a path in the vault"}

  defp content(content) when is_binary(content), do: {:ok, content}
  defp content(_), do: {:error, :bad_request, "send the file's content"}

  defp current(_layout, id, _user, _opts) when id in [nil, ""], do: {:ok, nil}
  defp current(layout, id, user, opts), do: vault_page(layout, id, user, :write, opts)

  # A live page of this vault, that `user` has `need` on.
  defp vault_page(layout, id, user, need, opts) do
    with {:ok, id} <- int(id),
         %Page{} = page <- Repo.get(Page, id),
         true <- Map.has_key?(layout.pages, page.id) do
      level = level(user, Repo.get!(Board, page.board_id), opts[:token])

      cond do
        not Wiki.visible?(page, level) ->
          {:error, :not_found, "page #{id} in this vault"}

        need == :write and not Access.can_write?(level) ->
          {:error, :forbidden, "you don't edit #{page.code}"}

        true ->
          {:ok, page}
      end
    else
      {:error, _, _} = error -> error
      _ -> {:error, :not_found, "page #{id} in this vault"}
    end
  end

  defp int(id) when is_integer(id), do: {:ok, id}

  defp int(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_request, "a page id is a whole number"}
    end
  end

  defp check_base(_layout, nil, _base), do: :ok
  defp check_base(_layout, _page, base) when base in [nil, ""], do: :ok

  defp check_base(layout, page, base) do
    current = entry(layout, page)

    if String.downcase(String.trim(base)) == current.hash,
      do: :ok,
      else: {:error, :conflict, current}
  end

  # Somebody else's page at this path is a conflict: the client keeps both.
  defp path_free(layout, path, current, user) do
    case layout.paths[String.downcase(path)] do
      nil ->
        :ok

      id when not is_nil(current) and id == current.id ->
        :ok

      id ->
        page = Repo.get!(Page, id)

        if Wiki.visible?(page, Access.page_permission(user, page)),
          do: {:error, :conflict, entry(layout, page)},
          else: {:error, :unprocessable_entity, "#{path} is taken"}
    end
  end

  # Where the file puts the page, and the name its file gives it. A page's
  # own `Title/index.md` names the page `Title`, filed where `Title` is.
  defp location(layout, path, current) do
    own_index? =
      Path.basename(path) == "index.md" and current != nil and
        match?(%{children?: true}, layout.pages[current.id])

    if own_index? do
      dir = Path.dirname(path)
      {Layout.place(layout, dir), Path.basename(dir)}
    else
      {Layout.place(layout, path), Path.basename(path, Path.extname(path))}
    end
  end

  defp target(_layout, {:error, reason}, _user, _opts),
    do: {:error, :unprocessable_entity, reason}

  defp target(_layout, {:parent, id}, user, opts) do
    parent = Repo.get!(Page, id)
    board = Repo.get!(Board, parent.board_id)

    with :ok <- writable(board, user, opts),
         do: {:ok, board, parent.id, {:id, parent.folder_id}}
  end

  defp target(_layout, {:folder, mapping, segments}, user, opts) do
    board = Repo.get!(Board, mapping.board_id)

    with :ok <- writable(board, user, opts),
         do: {:ok, board, nil, {:path, mapping.folder_id, segments}}
  end

  defp writable(board, user, opts) do
    if Access.can_write?(level(user, board, opts[:token])),
      do: :ok,
      else: {:error, :forbidden, "you don't edit #{board.name}"}
  end

  # The folder a path names below a mapping's own, matched by the name its
  # directory has on disk and made where it is missing.
  defp ensure_folder(_board, {:id, id}), do: {:ok, id}
  defp ensure_folder(_board, {:path, folder_id, []}), do: {:ok, folder_id}

  defp ensure_folder(board, {:path, parent_id, [segment | rest]}) do
    existing =
      from(f in Folder,
        where: f.board_id == ^board.id,
        where:
          ^if(parent_id,
            do: dynamic([f], f.parent_id == ^parent_id),
            else: dynamic([f], is_nil(f.parent_id))
          )
      )
      |> Repo.all()
      |> Enum.find(&(String.downcase(Archive.safe_name(&1.name)) == String.downcase(segment)))

    folder =
      case existing do
        %Folder{} = folder -> {:ok, folder}
        nil -> Wiki.create_folder(board, %{"name" => segment, "parent_id" => parent_id})
      end

    with {:ok, folder} <- folder, do: ensure_folder(board, {:path, folder.id, rest})
  end

  # The page's fields from its file. The title is the file's name (R2.10)
  # unless front matter says otherwise and the file was not renamed since:
  # renaming either side renames the other, so a file renamed to `New.md`
  # with `title: Old` still in it is `New`, and its title key is patched.
  defp attrs(content, stem, current, layout) do
    {header, body} = FrontMatter.split(content)
    yaml = FrontMatter.yaml(header)
    said = FrontMatter.get(yaml, "title")
    said = if is_binary(said) and String.trim(said) != "", do: String.trim(said)

    title =
      cond do
        is_nil(said) -> stem
        is_nil(current) -> said
        names?(said, stem, current) -> said
        stem == layout.pages[current.id].stem -> said
        true -> stem
      end

    header =
      if said && said != title,
        do: FrontMatter.with_yaml(header, FrontMatter.put(yaml, "title", title)),
        else: header

    status = FrontMatter.get(yaml, "status")

    %{
      "title" => title,
      "body" => body,
      "front_matter" => header || "",
      "summary" => summary(FrontMatter.get(yaml, "summary")),
      "status" => if(status in Page.statuses(), do: status, else: "published"),
      "template" => FrontMatter.get(yaml, "template") == "true"
    }
    |> file_name(stem, title, current, layout)
  end

  # The file's own name is kept when the title alone wouldn't give it back
  # (R9: an import renames nothing) — for a new note, and for a file renamed
  # here. A title changed in the file's front matter, the file not renamed,
  # renames the file after it, as a title changed anywhere else does.
  defp file_name(attrs, stem, title, current, layout) do
    own = if stem != Archive.safe_name(title), do: stem

    cond do
      is_nil(current) -> Map.put(attrs, "file_name", own)
      stem != layout.pages[current.id].stem -> Map.put(attrs, "file_name", own)
      String.trim(title) != current.title -> Map.put(attrs, "file_name", nil)
      true -> attrs
    end
  end

  defp names?(title, stem, page) do
    safe = String.downcase(Archive.safe_name(title))
    String.downcase(stem) in [safe, safe <> "-" <> String.downcase(page.code)]
  end

  # A `summary` key becomes the page's summary when it can be one. A longer
  # one (Obsidian's Web Clipper writes whole paragraphs) is the writer's own
  # key, kept in the file as it is, rather than a reason to refuse the note.
  defp summary(value) when is_binary(value) do
    if String.length(value) <= Page.summary_length(), do: value
  end

  defp summary(_), do: nil

  defp write_opts(user), do: [user: user, via: "sync", message: "synced"]

  # What `reader` may do on each board of the vault, narrowed by the token.
  defp levels(vault, reader, token) do
    vault
    |> Vaults.board_ids()
    |> Enum.map(&Repo.get!(Board, &1))
    |> Map.new(&{&1.id, level(reader, &1, token)})
  end

  defp level(user, board, token) do
    level = Access.board_permission(user, board)
    level = if level == :view, do: :none, else: level
    {level, _why} = Access.narrow(level, token, board.id)
    level
  end
end
