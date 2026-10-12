defmodule Slipdock.Vaults.Index do
  @moduledoc """
  Where every page of a vault sits, as a vault path, and finding pages by a
  link's words the way Obsidian does (W-103 R4).

  A page's vault path is the path of the mapping that holds it, then the
  folders below that mapping's folder, then the pages it sits under, then its
  own title — exactly the layout an export writes (`Slipdock.Wiki.Archive`),
  so a link that resolved in the files resolves here. A board mapped more
  than once has each page claimed by the deepest mapping above it; a page in
  no mapped part of its board is in no vault path at all.

  Matching compares names as their files would be named, case aside: the last
  part of a link against a page's title, slug or aliases, any parts before it
  against the end of the page's directory path. Of several matches the
  shortest path wins — fewest segments, then alphabetical — which is the
  "shortest unique path" rule; writing more of the path picks another.

  Built from a few narrow queries over the vault's boards. A caller resolving
  many links at once wraps the work in `cached/1`, so the index is built once
  per render or save rather than once per link.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Vaults.{Mapping, Vault}
  alias Slipdock.Wiki.{Archive, Folder, Page}

  @type entry :: %{
          id: pos_integer,
          board_id: pos_integer,
          segments: [String.t()],
          path: String.t(),
          names: [String.t()],
          dirs: [String.t()]
        }

  @doc "Every live page of the vault with its vault path, shortest paths first."
  @spec build(Vault.t()) :: [entry]
  def build(%Vault{id: vault_id}) do
    mappings =
      Repo.all(
        from(m in Mapping,
          where: m.vault_id == ^vault_id,
          select: {m.board_id, m.folder_id, m.path}
        )
      )

    board_ids = mappings |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    folders =
      from(f in Folder, where: f.board_id in ^board_ids, select: {f.id, {f.parent_id, f.name}})
      |> Repo.all()
      |> Map.new()

    pages =
      from(p in Page,
        where: p.board_id in ^board_ids,
        select: %{
          id: p.id,
          board_id: p.board_id,
          parent_id: p.parent_id,
          folder_id: p.folder_id,
          title: p.title,
          slug: p.slug,
          aliases: p.aliases,
          file_name: p.file_name,
          archived: not is_nil(p.archived_at)
        }
      )
      |> Repo.all()

    by_id = Map.new(pages, &{&1.id, &1})
    by_board = Enum.group_by(mappings, &elem(&1, 0))

    pages
    |> Enum.reject(& &1.archived)
    |> Enum.flat_map(fn page ->
      case place(page, by_id, folders, Map.get(by_board, page.board_id, [])) do
        nil -> []
        segments -> [entry(page, segments)]
      end
    end)
    |> Enum.sort_by(&{length(&1.segments), &1.path})
  end

  # The page's vault path as segments, or nil when no mapping holds it. A
  # child page sits wherever its top ancestor is filed, as in an export.
  defp place(page, by_id, folders, mappings) do
    {top, ancestors} = ancestry(page, by_id, [])
    chain = folder_chain(top.folder_id, folders, [])

    mappings
    |> Enum.map(fn {_board, folder_id, path} -> {depth(folder_id, chain), folder_id, path} end)
    |> Enum.reject(fn {depth, _f, _p} -> is_nil(depth) end)
    |> Enum.max_by(fn {depth, _f, _p} -> depth end, fn -> nil end)
    |> case do
      nil ->
        nil

      {depth, _folder_id, path} ->
        below = chain |> Enum.drop(depth + 1) |> Enum.map(&folder_name(&1, folders))
        split(path) ++ below ++ Enum.map(ancestors, & &1.title) ++ [page.title]
    end
  end

  # How deep in the chain a mapping's folder sits: -1 for a board's root
  # (above every folder), nil when the page is not under it at all.
  defp depth(nil, _chain), do: -1
  defp depth(folder_id, chain), do: Enum.find_index(chain, &(&1 == folder_id))

  defp ancestry(%{parent_id: nil} = page, _by_id, acc), do: {page, acc}

  defp ancestry(page, by_id, acc) do
    case by_id[page.parent_id] do
      nil -> {page, acc}
      # A loop cannot be saved, but a broken chain must not hang a render.
      parent when length(acc) > 64 -> {parent, acc}
      parent -> ancestry(parent, by_id, [parent | acc])
    end
  end

  # Folder ids from the top of the tree down to `folder_id`.
  defp folder_chain(nil, _folders, acc), do: acc

  defp folder_chain(folder_id, folders, acc) do
    case folders[folder_id] do
      {parent_id, _name} when length(acc) < 64 ->
        folder_chain(parent_id, folders, [folder_id | acc])

      _ ->
        acc
    end
  end

  defp folder_name(id, folders), do: folders |> Map.fetch!(id) |> elem(1)

  defp split(""), do: []
  defp split(path), do: String.split(path, "/")

  defp entry(page, segments) do
    %{
      id: page.id,
      board_id: page.board_id,
      segments: segments,
      path: Enum.join(segments, "/"),
      names:
        [page.title, page.slug, page.file_name | page.aliases || []]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&norm/1)
        |> Enum.uniq(),
      dirs: segments |> Enum.drop(-1) |> Enum.map(&norm/1)
    }
  end

  @doc """
  The entries a link's words match, best first: `"Note"` by name anywhere,
  `"Folder/Note"` by name under a path ending in `Folder`. A trailing `.md`
  is ignored, as Obsidian ignores it.
  """
  @spec match([entry], String.t()) :: [entry]
  def match(index, link) do
    parts =
      link
      |> String.replace_suffix(".md", "")
      |> String.split("/", trim: true)
      |> Enum.map(&norm/1)

    case parts do
      [] ->
        []

      _ ->
        {dirs, [name]} = Enum.split(parts, -1)

        Enum.filter(index, fn entry ->
          name in entry.names and ends_with?(entry.dirs, dirs)
        end)
    end
  end

  defp ends_with?(list, suffix),
    do: length(suffix) <= length(list) and Enum.take(list, -length(suffix)) == suffix

  # Names compared as their files are named, case aside: `Retry: why` is the
  # file `Retry- why`, and a link may be written either way.
  defp norm(name), do: name |> to_string() |> Archive.safe_name() |> String.downcase()

  @doc "A vault's index, built once for the length of `fun` however often it is asked for."
  def cached(fun) do
    case Process.get(__MODULE__) do
      nil ->
        Process.put(__MODULE__, %{})

        try do
          fun.()
        after
          Process.delete(__MODULE__)
        end

      _active ->
        fun.()
    end
  end

  @doc "The vault's index: from the cache inside `cached/1`, built afresh outside it."
  def for_vault(%Vault{id: id} = vault) do
    case Process.get(__MODULE__) do
      %{^id => index} ->
        index

      %{} = cache ->
        index = build(vault)
        Process.put(__MODULE__, Map.put(cache, id, index))
        index

      nil ->
        build(vault)
    end
  end
end
