defmodule Slipdock.Wiki.Archive do
  @moduledoc """
  A board's wiki, out and back in as a folder of Markdown files.

  This is the escape hatch, and it is here on purpose. A wiki you cannot get
  your writing out of is a wiki you should think twice about putting writing
  into; a zip of `.md` files opens in Obsidian, in a text editor, or in
  `grep`, and that is the whole promise.

  **Out.** One file per page, in the directory its wiki folder names and
  nested as the page tree is, with front matter carrying what Markdown has no
  way to say (the code, the summary, the tags, who last wrote it).
  `[[Retry policy]]` is left exactly as written — the dialect is the one
  Obsidian reads — and `#412`, `[[!toc]]` and live query blocks are left as
  written too, because rewriting them would be a lie about what the page says.
  A folder holding nothing at all has no directory to write, so it does not
  survive the trip; a folder holding pages does.

  **In.** A folder of Markdown becomes pages, and a directory becomes one of
  two things, told apart by one rule: **a directory with an `index.md` is a
  page with children; a directory without one is a folder.** That is exactly
  what `files/2` writes, so a wiki exported and imported comes back as it
  went — and a folder of notes somebody wrote by hand reads the way they
  would expect, with their directories as filing rather than as pages about
  nothing.

  Front matter is honoured when it is there. Nothing is overwritten unless
  asked: a file whose title already exists on the board is skipped and
  reported, so an import twice over is not a wiki twice over.
  """

  alias Slipdock.Boards.Board
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{FrontMatter, Page}

  ## Out -----------------------------------------------------------------------

  @doc """
  Every page of a board's wiki as `{path, contents}` pairs, ready to zip.

  Paths mirror both axes: the wiki folder a page is filed in is the directory
  it sits in, and a page with children becomes a directory of its own name
  plus an `index.md` for itself, so opening the export in a Markdown editor
  reads the way the wiki does.
  """
  @spec files(Board.t(), keyword) :: [{String.t(), String.t()}]
  def files(%Board{} = board, opts \\ []) do
    pages = Wiki.list_pages(board, Keyword.take(opts, [:archived, :status, :template]))
    folders = Map.new(Wiki.folders(board), &{&1.id, folder_dir(&1)})

    pages
    |> Wiki.tree_from()
    |> Enum.flat_map(fn %{page: page} = node ->
      walk([node], Map.get(folders, page.folder_id, ""))
    end)
    |> dedupe()
  end

  # Two pages in one directory may share a title, and a filename is not
  # allowed to be ambiguous: the second one takes its code as well. Silently
  # writing one over the other would lose writing, which is the one thing an
  # export must never do.
  defp dedupe(files) do
    files
    |> Enum.reduce({[], MapSet.new()}, fn {path, contents}, {kept, taken} ->
      path =
        if MapSet.member?(taken, path) do
          code = contents |> code_in_front_matter() |> to_string()
          Path.rootname(path) <> "-" <> code <> Path.extname(path)
        else
          path
        end

      {[{path, contents} | kept], MapSet.put(taken, path)}
    end)
    |> then(fn {kept, _taken} -> Enum.reverse(kept) end)
  end

  defp code_in_front_matter(contents) do
    case Regex.run(~r/^code: (\S+)$/m, contents) do
      [_, code] -> code
      _ -> Integer.to_string(System.unique_integer([:positive]))
    end
  end

  # A folder's path as directories, each segment made safe for a filename.
  defp folder_dir(folder) do
    folder
    |> Wiki.folder_ancestors()
    |> Kernel.++([folder])
    |> Enum.map_join("/", &safe_name(&1.name))
  end

  defp walk(nodes, prefix) do
    Enum.flat_map(nodes, fn %{page: page, children: children} ->
      name = file_name(page)

      case children do
        [] ->
          [{Path.join(prefix, name <> ".md"), file(page)}]

        _ ->
          folder = Path.join(prefix, name)
          [{Path.join(folder, "index.md"), file(page)} | walk(children, folder)]
      end
    end)
  end

  @doc """
  One page as a Markdown file, front matter and all.

  A page that came from a file with front matter of its own keeps it: the
  keys Slipdock owns are patched where they stand, and every other key,
  comment and quote is written back exactly as it was read (see
  `Slipdock.Wiki.FrontMatter`). A page with none gets Slipdock's keys alone.
  """
  def file(%Page{front_matter: nil} = page) do
    front =
      [
        {"title", page.title},
        {"code", page.code},
        {"slug", page.slug},
        {"summary", page.summary},
        {"status", page.status},
        {"template", page.template && "true"},
        {"tags", tags(page)},
        {"updated", page.updated_at && DateTime.to_iso8601(page.updated_at)}
      ]
      |> Enum.reject(fn {_k, v} -> blank?(v) end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

    "---\n" <> front <> "\n---\n\n" <> String.trim_trailing(to_string(page.body)) <> "\n"
  end

  def file(%Page{front_matter: header} = page) do
    yaml =
      header
      |> FrontMatter.yaml()
      |> FrontMatter.put("title", page.title)
      |> FrontMatter.put("code", page.code)
      |> FrontMatter.put("slug", page.slug)
      |> FrontMatter.put("summary", page.summary)
      |> put_ours("status", page.status, Page.statuses())
      |> put_ours("template", page.template && true, ~w(true false))
      |> put_board_tags(page)
      |> FrontMatter.put("updated", page.updated_at && DateTime.to_iso8601(page.updated_at))

    FrontMatter.with_yaml(header, yaml) <> String.trim_trailing(to_string(page.body)) <> "\n"
  end

  @doc """
  One page as the file a sync writes: its own front matter, exactly as it
  was read, with only what the page has changed since patched in — and no
  key that changes on every save (W-103 R3.3), so a sync never rewrites a
  file just to move a timestamp.

    * `title` only when it differs from `:file_title`, the title the file's
      name already says (or when the file carried one already);
    * `code` only with `code: true`;
    * `summary` when there is one, `status` when it is a draft, `template`
      when it is one — or when the file already said otherwise;
    * no `updated`, no `slug`, no author.

  A page with nothing to say and no front matter of its own is its body.
  """
  def sync_file(%Page{} = page, opts \\ []) do
    header = page.front_matter
    yaml = FrontMatter.yaml(header) || ""
    file_title = Keyword.get(opts, :file_title, page.title)

    yaml =
      yaml
      |> put_if(
        "title",
        page.title,
        page.title != file_title or FrontMatter.has_key?(yaml, "title")
      )
      |> put_if("code", page.code, opts[:code] == true)
      |> put_if(
        "summary",
        page.summary,
        page.summary != nil or FrontMatter.has_key?(yaml, "summary")
      )
      |> put_if(
        "status",
        page.status,
        page.status == "draft" or ours?(yaml, "status", Page.statuses())
      )
      |> put_if(
        "template",
        page.template,
        page.template or ours?(yaml, "template", ~w(true false))
      )

    case FrontMatter.with_yaml(header, yaml) do
      nil -> to_string(page.body)
      header -> header <> to_string(page.body)
    end
  end

  defp put_if(yaml, key, value, true), do: FrontMatter.put(yaml, key, value)
  defp put_if(yaml, _key, _value, false), do: yaml

  # A key Slipdock owns, unless the file already uses it for something else:
  # `status: reading` is the writer's own, and stays.
  defp put_ours(yaml, key, value, vocabulary) do
    if FrontMatter.has_key?(yaml, key) and not ours?(yaml, key, vocabulary),
      do: yaml,
      else: FrontMatter.put(yaml, key, value)
  end

  defp ours?(yaml, key, vocabulary), do: FrontMatter.get(yaml, key) in vocabulary

  # A file's own `tags` are the note's (see W-103 R3.2); the board's tags are
  # written only where the file has none.
  defp put_board_tags(yaml, page) do
    if FrontMatter.has_key?(yaml, "tags"),
      do: yaml,
      else: FrontMatter.put(yaml, "tags", tags(page))
  end

  # Not `v in [nil, "", false]`: :cover cannot compile that inside an
  # anonymous function, and `mix test --cover` dies on this module.
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(false), do: true
  defp blank?(_), do: false

  defp tags(%Page{} = page) do
    case Wiki.tags(page) do
      [] -> nil
      tags -> Enum.map_join(tags, ", ", & &1.name)
    end
  end

  # Enough to be a filename on any machine, and still recognisable.
  defp file_name(%Page{title: title, code: code}) do
    case safe_name(title) do
      "" -> code
      name -> name
    end
  end

  # A leading dot goes too: a title of `..` would otherwise be a path segment
  # that climbs out of the export folder (or the zip), and `.claude` a hidden
  # directory nobody asked to have written.
  defp safe_name(name) do
    name
    |> to_string()
    |> String.replace(~r/[\/\\:*?"<>|]+/u, "-")
    |> String.trim()
    |> String.replace(~r/^\.+/u, "-")
    |> String.slice(0, 80)
  end

  @doc "The whole wiki as a zip, as `{filename, binary}`."
  @spec zip(Board.t(), keyword) :: {String.t(), binary}
  def zip(%Board{} = board, opts \\ []) do
    entries =
      for {path, contents} <- files(board, opts),
          do: {String.to_charlist(path), contents}

    {:ok, {_name, binary}} =
      :zip.create(String.to_charlist(zip_name(board)), entries, [:memory])

    {zip_name(board), binary}
  end

  defp zip_name(%Board{} = board) do
    base = (board.code || "wiki") |> String.replace(~r/[^\w-]+/u, "")
    "#{if base == "", do: "wiki", else: base}-wiki.zip"
  end

  ## In ------------------------------------------------------------------------

  @doc """
  Reads a folder of Markdown into a board's wiki.

  Returns `{:ok, %{created: [page], skipped: [%{path:, reason:}]}}`. Options:

    * `:user`, `:via`, `:message` — as `Slipdock.Wiki.create_page/3`
    * `:overwrite` — replace a page whose title already exists rather than
      skipping it (default `false`)

  A directory with an `index.md` becomes a page with children; a directory
  without one becomes a wiki folder. It reads the folder into the same
  `{path, body}` pairs `files/2` produces and hands them to `import_files/3`,
  so there is one importer rather than two.
  """
  @spec import_folder(Board.t(), String.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def import_folder(%Board{} = board, dir, opts \\ []) do
    if File.dir?(dir) do
      {:ok, board |> import_files(read_folder(dir), opts)}
    else
      {:error, "#{inspect(dir)} is not a folder"}
    end
  end

  defp read_folder(dir) do
    dir
    |> walk_folder()
    |> Enum.map(fn path ->
      {Path.relative_to(path, dir), File.read!(path)}
    end)
  end

  defp walk_folder(dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)

      cond do
        File.dir?(path) -> walk_folder(path)
        markdown?(name) -> [path]
        true -> []
      end
    end)
  end

  @doc """
  Writes `{path, body}` pairs into a board's wiki — the shape `files/2`
  returns, so a wiki moves between boards by handing one answer to the other.

  Directories are read by the one rule the module documents: with an
  `index.md` a directory is a page and the files beside it are its children;
  without one it is a wiki folder and the files in it are filed there.
  Shallowest first, so a child always has a parent to hang off.
  """
  @spec import_files(Board.t(), [{String.t(), String.t()}], keyword) :: map
  def import_files(%Board{} = board, files, opts \\ []) do
    # Which directories in this set are pages: the ones with an index file.
    page_dirs =
      for {path, _body} <- files, index?(path), into: MapSet.new(), do: Path.dirname(path)

    files
    |> Enum.sort_by(fn {path, _body} ->
      {length(Path.split(path)), (index?(path) && 0) || 1, path}
    end)
    |> Enum.reduce(%{created: [], skipped: [], parents: %{}, folders: %{}}, fn {path, body},
                                                                               acc ->
      dir = Path.dirname(path)
      # A page's own file sits beside its children, so its parent and its
      # folder are read from the directory above it.
      from = if index?(path), do: Path.dirname(dir), else: dir

      parent = acc.parents[nearest_page_dir(from, page_dirs)]
      {folder, acc} = ensure_folder(board, from, page_dirs, acc)

      case write(board, path, body, parent, folder, opts) do
        {:ok, page} ->
          parents = if index?(path), do: Map.put(acc.parents, dir, page), else: acc.parents
          %{acc | created: acc.created ++ [page], parents: parents}

        {:skip, reason} ->
          %{acc | skipped: acc.skipped ++ [%{path: path, reason: reason}]}
      end
    end)
    |> Map.drop([:parents, :folders])
  end

  defp index?(path), do: Path.basename(path) in ["index.md", "index.markdown"]

  # The nearest directory at or above `dir` that carries a page of its own.
  defp nearest_page_dir(".", _page_dirs), do: nil

  defp nearest_page_dir(dir, page_dirs) do
    if MapSet.member?(page_dirs, dir),
      do: dir,
      else: nearest_page_dir(Path.dirname(dir), page_dirs)
  end

  # The folder a file in `dir` is filed in: the directories at or above it
  # that are not pages, in order. A path of names makes the whole chain, and
  # making one twice over is making it once (see `Slipdock.Wiki.Folders`).
  defp ensure_folder(_board, ".", _page_dirs, acc), do: {nil, acc}

  defp ensure_folder(board, dir, page_dirs, acc) do
    name =
      dir
      |> Path.split()
      |> Enum.reject(&(&1 == "."))
      |> Enum.with_index()
      |> Enum.reject(fn {_segment, index} ->
        MapSet.member?(page_dirs, dir |> Path.split() |> Enum.take(index + 1) |> Path.join())
      end)
      |> Enum.map_join("/", &elem(&1, 0))

    cond do
      name == "" ->
        {nil, acc}

      folder = acc.folders[name] ->
        {folder, acc}

      true ->
        case Wiki.create_folder(board, %{"name" => name}) do
          {:ok, folder} -> {folder, %{acc | folders: Map.put(acc.folders, name, folder)}}
          _ -> {nil, acc}
        end
    end
  end

  defp write(board, path, text, parent, folder, opts) do
    {header, body} = FrontMatter.split(text)
    front = known_keys(header)
    title = front["title"] || readable_title(path)

    attrs =
      %{
        "title" => title,
        "body" => body,
        "summary" => front["summary"],
        "status" => if(front["status"] in ["draft", "published"], do: front["status"]),
        "template" => front["template"] == "true",
        "front_matter" => header || ""
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    create(board, attrs, parent, folder, opts)
  end

  # "Deploys/index.md" is the "Deploys" page; "Deploys/Rollback.md" is
  # "Rollback".
  defp readable_title(path) do
    if index?(path),
      do: path |> Path.dirname() |> Path.basename(),
      else: path |> Path.basename() |> Path.rootname()
  end

  defp create(board, attrs, parent, folder, opts) do
    attrs =
      attrs
      |> Map.put("parent_id", parent && parent.id)
      |> Map.put("folder_id", folder && folder.id)

    case Wiki.find_page(board, attrs["title"]) do
      {:ok, %Page{} = existing} ->
        if opts[:overwrite] do
          case Wiki.update_page(existing, Map.drop(attrs, ["parent_id"]), write_opts(opts)) do
            {:ok, page} -> {:ok, page}
            _ -> {:skip, "could not be updated"}
          end
        else
          {:skip, "a page called #{inspect(attrs["title"])} is already here"}
        end

      _ ->
        case Wiki.create_page(board, attrs, write_opts(opts)) do
          {:ok, page} -> {:ok, page}
          {:error, changeset} -> {:skip, errors(changeset)}
        end
    end
  end

  defp write_opts(opts) do
    opts
    |> Keyword.take([:user, :via, :agent])
    |> Keyword.put_new(:message, opts[:message] || "imported")
  end

  defp markdown?(name), do: String.ends_with?(String.downcase(name), [".md", ".markdown"])

  @doc """
  Splits front matter off a Markdown file: `{map, body}`, the map holding the
  keys a page maps onto its own fields — `title`, `summary`, `status`,
  `template` — as strings. The rest is kept, exactly, by the page's
  `front_matter` (see `Slipdock.Wiki.FrontMatter`).
  """
  def split_front_matter(text) do
    {header, body} = FrontMatter.split(text)
    {known_keys(header), body}
  end

  defp known_keys(nil), do: %{}

  defp known_keys(header) do
    yaml = FrontMatter.yaml(header)

    for key <- ~w(title summary status template),
        value = FrontMatter.get(yaml, key),
        is_binary(value),
        into: %{},
        do: {key, value}
  end

  defp errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
