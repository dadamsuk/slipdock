defmodule Slipdock.Vaults.Sync do
  @moduledoc """
  The server half of `slipdock sync` (W-103 R2): a vault as a folder of
  files, read and written one file at a time.

  **Files, not pages.** Everything here speaks in vault paths
  (`Jobs/Acme/Call.md`) and in the exact bytes a sync writes for a page
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
  alias Slipdock.Wiki.{Archive, Changes, Folder, FrontMatter, Page}

  @doc "The sha256 of a file's bytes, as a sync compares them."
  def hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  ## Reading ------------------------------------------------------------------

  @doc """
  Every file of the vault `reader` may open:

      %{cursor: 931, entries: [%{kind: "page", id:, board_id:, path:, hash:, code:, title:}]}

  `cursor` is the change feed's position taken *before* the listing was
  read, so following the feed from it sees anything that changed while it
  was being made, rather than missing it.
  """
  def listing(%Vault{} = vault, %User{} = reader, opts \\ []) do
    %{cursor: cursor} = Changes.since(vault, nil, reader, token: opts[:token])
    layout = Layout.build(vault)
    levels = levels(vault, reader, opts[:token])

    entries =
      layout.pages
      |> Map.keys()
      |> Enum.chunk_every(200)
      |> Enum.flat_map(fn ids ->
        from(p in Page, where: p.id in ^ids) |> Repo.all()
      end)
      |> Enum.filter(&Wiki.visible?(&1, Map.get(levels, &1.board_id, :none)))
      |> Enum.map(&(entry(layout, &1) |> Map.drop([:content])))
      |> Enum.sort_by(& &1.path)

    %{cursor: cursor, entries: entries}
  end

  @doc "One page's file: `{:ok, %{id:, path:, hash:, content:, ...}}`."
  def read_page(%Vault{} = vault, %User{} = reader, id, opts \\ []) do
    layout = Layout.build(vault)

    with {:ok, page} <- vault_page(layout, id, reader, :read, opts) do
      {:ok, entry(layout, page)}
    end
  end

  # What a listing and every write answer with for a page.
  defp entry(layout, %Page{} = page) do
    placed = layout.pages[page.id]
    content = render(page, placed)

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

  defp render(page, placed), do: Archive.sync_file(page, file_title: placed.stem)

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

  ## The parts ----------------------------------------------------------------

  @doc """
  A vault path as a sync may name it: relative, forward slashes, no `.` or
  `..` segment, no hidden segment, ending in `.md`.
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
      "summary" => string(FrontMatter.get(yaml, "summary")),
      "status" => if(status in Page.statuses(), do: status, else: "published"),
      "template" => FrontMatter.get(yaml, "template") == "true"
    }
  end

  defp names?(title, stem, page) do
    safe = String.downcase(Archive.safe_name(title))
    String.downcase(stem) in [safe, safe <> "-" <> String.downcase(page.code)]
  end

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil

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
