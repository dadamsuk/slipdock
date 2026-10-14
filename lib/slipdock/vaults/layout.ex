defmodule Slipdock.Vaults.Layout do
  @moduledoc """
  A vault laid out as files: where on disk a sync writes every page, and
  which folder or parent page a path on disk names (W-103 R2.10, R2.11).

  The layout is `Slipdock.Vaults.Index`'s, made into file names:

    * every segment is the name a file can hold (`Slipdock.Wiki.Archive.safe_name/1`);
    * a page is `Title.md`, or `Title/index.md` when it has children, which
      sit beside that index as they do in an export;
    * two things wanting one name — two pages titled alike in one folder, a
      page with children and a folder of the same name — are told apart by
      the later one taking its code (`Title-W-31.md`), compared case aside,
      since half the machines a vault is synced to cannot tell `Note.md`
      from `note.md`.

  Built from narrow queries with no bodies in them, so a write can ask where
  everything is without reading every page.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Vaults.{Mapping, Vault}
  alias Slipdock.Wiki.{Archive, Folder, Page}

  @type page :: %{
          id: pos_integer,
          board_id: pos_integer,
          path: String.t(),
          stem: String.t(),
          dir: String.t(),
          children?: boolean
        }

  @type t :: %{
          pages: %{pos_integer => page},
          paths: %{String.t() => pos_integer},
          page_dirs: %{String.t() => pos_integer},
          files: %{pos_integer => map},
          file_paths: %{String.t() => pos_integer},
          folders: %{pos_integer => String.t()},
          folder_dirs: %{String.t() => pos_integer},
          mappings: [%{board_id: pos_integer, folder_id: pos_integer | nil, path: String.t()}]
        }

  @doc "Where every live page and mapped folder of the vault sits on disk."
  @spec build(Vault.t()) :: t
  def build(%Vault{id: vault_id}) do
    mappings =
      Repo.all(
        from(m in Mapping,
          where: m.vault_id == ^vault_id,
          select: %{board_id: m.board_id, folder_id: m.folder_id, path: m.path}
        )
      )

    board_ids = mappings |> Enum.map(& &1.board_id) |> Enum.uniq()
    by_board = Enum.group_by(mappings, & &1.board_id)
    folder_dirs = folder_dirs(mappings)

    pages =
      from(p in Page,
        where: p.board_id in ^board_ids and is_nil(p.archived_at),
        select: %{
          id: p.id,
          board_id: p.board_id,
          parent_id: p.parent_id,
          folder_id: p.folder_id,
          title: p.title,
          code: p.code,
          file_name: p.file_name
        }
      )
      |> Repo.all()

    by_id = Map.new(pages, &{&1.id, &1})

    parents =
      for p <- pages, p.parent_id && by_id[p.parent_id], into: MapSet.new(), do: p.parent_id

    # A page with children is a directory too, and must not be one a folder
    # or a mapping already is.
    taken =
      folder_dirs
      |> Map.values()
      |> Kernel.++(Enum.map(mappings, & &1.path))
      |> Enum.flat_map(&prefixes/1)
      |> Map.new(&{String.downcase(&1), :folder})

    {placed, _taken, _dirs} =
      pages
      |> Enum.map(&{&1, depth(&1, by_id, 0)})
      |> Enum.sort_by(fn {page, depth} -> {depth, page.id} end)
      |> Enum.reduce({[], taken, %{}}, fn {page, _depth}, {acc, taken, dirs} ->
        case base_dir(page, by_id, dirs, folder_dirs, by_board) do
          nil ->
            {acc, taken, dirs}

          dir ->
            children? = MapSet.member?(parents, page.id)
            {stem, path} = name(page, dir, children?, taken)

            dirs = if children?, do: Map.put(dirs, page.id, join(dir, stem)), else: dirs
            taken = Map.put(taken, String.downcase(path), page.id)

            taken =
              if children?,
                do: Map.put(taken, String.downcase(join(dir, stem)), page.id),
                else: taken

            entry = %{
              id: page.id,
              board_id: page.board_id,
              path: path,
              stem: stem,
              dir: dir,
              children?: children?
            }

            {[entry | acc], taken, dirs}
        end
      end)

    page_map = Map.new(placed, &{&1.id, &1})

    taken =
      Enum.reduce(placed, taken, fn p, taken ->
        taken = Map.put(taken, String.downcase(p.path), p.id)

        if p.children?,
          do: Map.put(taken, String.downcase(join(p.dir, p.stem)), p.id),
          else: taken
      end)

    files = place_files(board_ids, folder_dirs, by_board, taken)

    %{
      pages: page_map,
      paths: Map.new(placed, &{String.downcase(&1.path), &1.id}),
      page_dirs:
        for(
          %{children?: true} = p <- placed,
          into: %{},
          do: {String.downcase(join(p.dir, p.stem)), p.id}
        ),
      files: Map.new(files, &{&1.id, &1}),
      file_paths: Map.new(files, &{String.downcase(&1.path), &1.id}),
      folders: folder_dirs,
      folder_dirs: Map.new(folder_dirs, fn {id, dir} -> {String.downcase(dir), id} end),
      mappings: mappings
    }
  end

  # A vault's other files (W-103 R2.9): each in its folder's directory, or
  # at its board's mapped root, under its own name — with its id added when
  # something placed earlier has that name already.
  defp place_files(board_ids, folder_dirs, by_board, taken) do
    from(f in Slipdock.Wiki.WikiFile,
      where: f.board_id in ^board_ids and is_nil(f.archived_at),
      order_by: [asc: f.id],
      select: %{id: f.id, board_id: f.board_id, folder_id: f.folder_id, name: f.name}
    )
    |> Repo.all()
    |> Enum.reduce({[], taken}, fn file, {acc, taken} ->
      dir =
        case file.folder_id do
          nil -> root_dir(Map.get(by_board, file.board_id, []))
          id -> folder_dirs[id]
        end

      if is_nil(dir) do
        {acc, taken}
      else
        name = String.replace(file.name, ~r/[:*?"<>|]+/, "-")
        path = join(dir, name)

        path =
          if Map.has_key?(taken, String.downcase(path)) do
            ext = Path.extname(name)
            join(dir, Path.basename(name, ext) <> "-F#{file.id}" <> ext)
          else
            path
          end

        entry = Map.merge(file, %{path: path, dir: dir})
        {[entry | acc], Map.put(taken, String.downcase(path), {:file, file.id})}
      end
    end)
    |> elem(0)
  end

  # How many pages sit above this one.
  defp depth(%{parent_id: nil}, _by_id, n), do: n

  defp depth(page, by_id, n) do
    case by_id[page.parent_id] do
      parent when not is_nil(parent) and n < 64 -> depth(parent, by_id, n + 1)
      _ -> n
    end
  end

  # The directory a page's file goes in: its parent's own directory, or, at
  # the top of the tree, wherever its folder (or its board's root) is mapped.
  defp base_dir(page, by_id, dirs, folder_dirs, by_board) do
    case page.parent_id && by_id[page.parent_id] do
      nil ->
        case page.folder_id do
          nil -> root_dir(Map.get(by_board, page.board_id, []))
          folder_id -> folder_dirs[folder_id]
        end

      parent ->
        # Placed already, being shallower; nil when the parent is in no vault path.
        dirs[parent.id]
    end
  end

  defp root_dir(mappings) do
    case Enum.find(mappings, &is_nil(&1.folder_id)) do
      nil -> nil
      m -> m.path
    end
  end

  @doc """
  Where every mapped folder of `mappings`' boards sits in the vault, as
  `%{folder_id => dir}`: the deepest mapping above it, then the folders
  below that mapping's own. A folder nothing maps is left out. One narrow
  query of the folders, so the tree can ask without placing every page.
  """
  def folder_dirs(mappings) do
    board_ids = mappings |> Enum.map(& &1.board_id) |> Enum.uniq()

    rows =
      from(f in Folder,
        where: f.board_id in ^board_ids,
        select: {f.id, f.board_id, f.parent_id, f.name}
      )
      |> Repo.all()

    folders = Map.new(rows, fn {id, _board, parent, name} -> {id, {parent, name}} end)
    by_board = Enum.group_by(mappings, & &1.board_id)

    for {id, board_id, _parent, _name} <- rows,
        dir = folder_dir(id, folders, Map.get(by_board, board_id, [])),
        dir != nil,
        into: %{},
        do: {id, dir}
  end

  # A folder's directory: the deepest mapping above it, then the folders
  # below that mapping's own. Nil when nothing maps it.
  defp folder_dir(id, folders, mappings) do
    chain = chain(id, folders, [])

    mappings
    |> Enum.map(fn m ->
      {if(m.folder_id, do: Enum.find_index(chain, &(&1 == m.folder_id)), else: -1), m}
    end)
    |> Enum.reject(fn {depth, _m} -> is_nil(depth) end)
    |> Enum.max_by(fn {depth, _m} -> depth end, fn -> nil end)
    |> case do
      nil ->
        nil

      {depth, m} ->
        below = chain |> Enum.drop(depth + 1) |> Enum.map(&safe(folders[&1] |> elem(1)))
        Enum.reduce(below, m.path, &join(&2, &1))
    end
  end

  defp chain(nil, _folders, acc), do: acc

  defp chain(id, folders, acc) do
    case folders[id] do
      {parent_id, _name} when length(acc) < 64 -> chain(parent_id, folders, [id | acc])
      _ -> acc
    end
  end

  # The page's file name, made unique among everything placed before it.
  defp name(page, dir, children?, taken) do
    plain = file_name(page)

    Enum.find_value([plain, plain <> "-" <> page.code], fn stem ->
      path = file_path(dir, stem, children?)
      own_dir = String.downcase(join(dir, stem))

      if Map.has_key?(taken, String.downcase(path)) or
           (children? and Map.has_key?(taken, own_dir)),
         do: nil,
         else: {stem, path}
    end) || {plain <> "-" <> page.code, file_path(dir, plain <> "-" <> page.code, children?)}
  end

  defp file_path(dir, stem, true), do: join(join(dir, stem), "index.md")
  defp file_path(dir, stem, false), do: join(dir, stem <> ".md")

  # The name the page's own file had, kept; otherwise its title.
  defp file_name(%{file_name: name}) when is_binary(name) and name != "", do: name

  defp file_name(page) do
    case safe(page.title) do
      "" -> page.code
      name -> name
    end
  end

  defp safe(name), do: Archive.safe_name(name)

  defp prefixes(dir) do
    segments = String.split(dir, "/", trim: true)
    for n <- 1..length(segments)//1, do: segments |> Enum.take(n) |> Enum.join("/")
  end

  @doc "Two path parts joined with a slash, an empty one being no part at all."
  def join("", b), do: b
  def join(a, ""), do: a
  def join(a, b), do: a <> "/" <> b

  @doc """
  Where a file at `path` (vault-relative, `Projects/Acme/Call.md`) would go:

    * `{:parent, page_id}` — beside a page's `index.md`, so a child of it;
    * `{:folder, mapping, segments}` — under a mapping, in the folders named
      by `segments` below the mapping's own folder (made as needed);
    * `{:error, reason}` — in no mapping, or a folder inside a page.
  """
  def place(layout, path) do
    dir = path |> Path.dirname() |> then(&if(&1 == ".", do: "", else: &1))
    key = String.downcase(dir)

    cond do
      id = layout.page_dirs[key] ->
        {:parent, id}

      Enum.any?(Map.keys(layout.page_dirs), &String.starts_with?(key, &1 <> "/")) ->
        {:error, "#{dir} is inside a page, and a page holds pages, not folders"}

      true ->
        segments = String.split(dir, "/", trim: true)

        layout.mappings
        |> Enum.filter(fn m -> prefix?(String.split(m.path, "/", trim: true), segments) end)
        |> Enum.max_by(&length(String.split(&1.path, "/", trim: true)), fn -> nil end)
        |> case do
          nil ->
            {:error, "nothing in the vault is mapped at /#{dir}"}

          m ->
            {:folder, m, Enum.drop(segments, length(String.split(m.path, "/", trim: true)))}
        end
    end
  end

  defp prefix?(prefix, segments) do
    length(prefix) <= length(segments) and
      Enum.zip(prefix, segments)
      |> Enum.all?(fn {a, b} -> String.downcase(a) == String.downcase(b) end)
  end

  @doc """
  The vault-relative directory of a folder, for `also-in`, or nil when the
  folder is in no mapped part of the vault.
  """
  def folder_dir(layout, folder_id), do: layout.folders[folder_id]
end
