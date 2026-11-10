defmodule Slipdock.Vaults.Index do
  @moduledoc """
  Where every page of a vault sits, as a vault path, and finding pages by a
  link's words the way Obsidian does (W-103 R4).

  A page's vault path is its board's place in the vault
  (`Slipdock.Vaults.Layout`), then its folders, then the pages it sits under,
  then its own title. All of it in whole names, cleaned and never shortened:
  a disk name is cut to fit a path, but two pages sharing a long start must
  not answer to one link (W-2201 rule 5).

  Matching compares names cleaned, case aside: the last part of a link
  against a page's title, slug or aliases, any parts before it against the
  end of the page's directory path. Of several matches the shortest path wins
  — fewest segments, then alphabetical — which is the "shortest unique path"
  rule; writing more of the path picks another.

  Built from a few narrow queries over the vault's boards. A caller resolving
  many links at once wraps the work in `cached/1`, so the index is built once
  per render or save rather than once per link.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Vaults.{Layout, Vault}
  alias Slipdock.Wiki.{DiskName, Page}

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
  def build(%Vault{} = vault) do
    dirs = Layout.dirs(vault)
    board_ids = Map.keys(dirs.full_boards)

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

    pages
    |> Enum.reject(& &1.archived)
    |> Enum.flat_map(fn page ->
      case place(page, by_id, dirs) do
        nil -> []
        segments -> [entry(page, segments)]
      end
    end)
    |> Enum.sort_by(&{length(&1.segments), &1.path})
  end

  # The page's vault path as segments. A child page sits wherever its top
  # ancestor is filed, as in an export.
  defp place(page, by_id, dirs) do
    {top, ancestors} = ancestry(page, by_id, [])

    base =
      case top.folder_id do
        nil -> dirs.full_boards[top.board_id]
        id -> dirs.full_folders[id]
      end

    base && base ++ Enum.map(ancestors, & &1.title) ++ [page.title]
  end

  defp ancestry(%{parent_id: nil} = page, _by_id, acc), do: {page, acc}

  defp ancestry(page, by_id, acc) do
    case by_id[page.parent_id] do
      nil -> {page, acc}
      # A loop cannot be saved, but a broken chain must not hang a render.
      parent when length(acc) > 64 -> {parent, acc}
      parent -> ancestry(parent, by_id, [parent | acc])
    end
  end

  @doc "An entry for a page at `segments`: `build/1`'s, for a layout worked out elsewhere."
  def entry(page, segments) do
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
          Enum.member?(entry.names, name) and ends_with?(entry.dirs, dirs)
        end)
    end
  end

  defp ends_with?(list, suffix),
    do: length(suffix) <= length(list) and Enum.take(list, -length(suffix)) == suffix

  # Names compared cleaned, case aside and never shortened: `Retry: why` is
  # the file `Retry- why`, and a link may be written either way, while two
  # titles sharing a long start stay two names.
  defp norm(name), do: name |> DiskName.clean() |> String.downcase()

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

  @doc """
  Runs `fun` with `index` standing in for the vault's own: what `Links` would
  have said of another layout, without changing the live one.
  """
  def with_index(%Vault{id: id}, index, fun) do
    outer = Process.get(__MODULE__)
    Process.put(__MODULE__, Map.put(outer || %{}, id, index))

    try do
      fun.()
    after
      if outer, do: Process.put(__MODULE__, outer), else: Process.delete(__MODULE__)
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
