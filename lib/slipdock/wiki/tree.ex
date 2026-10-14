defmodule Slipdock.Wiki.Tree do
  @moduledoc """
  The wiki tree the way a browser draws it: one container's direct children
  at a time, as light rows, never a page's body (W-103 R11.1).

  A container is named by a ref:

    * `:root` — the top of the board's wiki: its top-level folders, then the
      pages and files filed in no folder;
    * `{:folder, id}` — a folder: the folders inside it, then the pages and
      files filed in it;
    * `{:page, id}` — a page: the pages that are part of it.

  The two axes are drawn the way the old, load-everything tree drew them (see
  `Slipdock.Wiki.Folder`): a page sits in the folder it is filed in, under
  its parent page when the parent is filed in the same folder, and at the
  top of its folder when its parent is filed elsewhere or is not shown (a
  draft the reader cannot see, an archived page while archived pages are
  hidden). So every page shows up exactly once, however the two disagree.

  Folders are few, so they are read whole, once a call; pages are read by
  container, and only the columns a row draws. Each row carries `count`, how
  many rows opening it would show, so a chevron is drawn only where there is
  something under it; a folder's row also carries `pages`, every page beneath
  it at any depth, for the number beside its name.

  Options, as `Slipdock.Wiki.list_pages/2` takes them:

    * `:status` — `"published"` to leave drafts out (a reader who cannot write
      never sees one); both by default
    * `:template` — `false` to leave template pages out; listed by default
    * `:archived` — `false` (the default) or `:all`
    * `:only` — a set of page ids, when a filter has already decided which
      pages are shown; anything else is left out
    * `:folders` — the board's folders, when the caller already has them
    * `:limit`, `:offset` — a page of a big container's pages at a time. When
      more are left, the last row is `%{kind: "more", offset: n}`, which is
      where to ask from next; files come with the last page
    * `:as` — the reader: a folder's rows include the pages also filed in it
      (W-103 R12.2), marked `also: true`, for the pages whose home board the
      reader can open. Without a reader, only pages of the folder's own board
    * `:through` — a page id: the first page of rows reaches at least as far
      as that page, so the page being read can be shown however far down a
      big folder it is
  """

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Boards.Board
  alias Slipdock.Filters
  alias Slipdock.Vaults.{Mapping, Vault}
  alias Slipdock.Wiki.{Folder, Folders, Page, Placement, WikiFile}

  @type ref :: :root | {:folder, pos_integer} | {:page, pos_integer}

  @page_fields [
    :id,
    :board_id,
    :title,
    :slug,
    :code,
    :status,
    :template,
    :encrypted,
    :archived_at,
    :parent_id,
    :folder_id,
    :position,
    :priority,
    :flags,
    :due_date,
    :completed,
    :inserted_at,
    :updated_at
  ]

  @doc """
  Reads a ref as a URL or an event carries it: `"root"` (or blank),
  `"folder:12"`, `"page:7"`. Anything else is `:error`.
  """
  def parse_ref(ref) when ref in [nil, "", "root", "folder:"], do: {:ok, :root}

  def parse_ref("folder:" <> id), do: parse_id(:folder, id)
  def parse_ref("page:" <> id), do: parse_id(:page, id)
  def parse_ref(_), do: :error

  defp parse_id(kind, id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, {kind, n}}
      _ -> :error
    end
  end

  @doc "A ref written back the way `parse_ref/1` reads it."
  def ref_key(:root), do: "root"
  def ref_key({kind, id}), do: "#{kind}:#{id}"

  @doc """
  The rows directly inside `ref` on `board`, in the order the tree draws
  them: folders first, then pages, then files.

  `{:error, :not_found}` for a folder or page that is not on this board, so a
  ref from one board's tree can never read another's.
  """
  def children(%Board{} = board, ref, opts \\ []) do
    folders = Keyword.get_lazy(opts, :folders, fn -> Folders.list(board) end)

    case container(board, ref, folders) do
      {:ok, {:folder, folder_id}} ->
        sort = sort_of(board, folders, folder_id)
        {pages, more} = paged(top_pages(board, folder_id, sort, opts), opts)

        # A later page of a big folder is its pages alone: the folders came
        # with the first.
        folder_rows =
          if Keyword.get(opts, :offset, 0) == 0,
            do:
              folder_rows(
                folders,
                folder_id,
                Keyword.get_lazy(opts, :stats, fn -> stats(board, folders, opts) end),
                sort
              ),
            else: []

        files = if more, do: [], else: file_rows(board, folder_id, opts)
        also = if more, do: [], else: also_rows(board, folder_id, Enum.map(pages, & &1.id), opts)
        {:ok, folder_rows ++ page_rows(pages, opts) ++ also ++ files ++ more_row(more)}

      {:ok, {:page, page}} ->
        {pages, more} = paged(child_pages(page, opts), opts)
        {:ok, page_rows(pages, opts) ++ more_row(more)}

      error ->
        error
    end
  end

  # What a ref names, checked against the board. The root is the folder
  # nobody made, and is read as `{:folder, nil}` from here on.
  defp container(_board, :root, _folders), do: {:ok, {:folder, nil}}

  defp container(_board, {:folder, id}, folders) do
    if Enum.any?(folders, &(&1.id == id)),
      do: {:ok, {:folder, id}},
      else: {:error, :not_found}
  end

  defp container(%Board{id: board_id}, {:page, id}, _folders) do
    case Repo.one(from(p in Page, where: p.id == ^id and p.board_id == ^board_id, select: p)) do
      nil -> {:error, :not_found}
      page -> {:ok, {:page, page}}
    end
  end

  defp container(_board, _ref, _folders), do: {:error, :not_found}

  @doc """
  The options with the board's folders and their counts read into them, for
  a caller about to ask for several containers at once: each asks the
  database for its own rows and nothing else.
  """
  def prepare(%Board{} = board, opts) do
    folders = Keyword.get_lazy(opts, :folders, fn -> Folders.list(board) end)
    opts = Keyword.put(opts, :folders, folders)
    Keyword.put_new_lazy(opts, :stats, fn -> stats(board, folders, opts) end)
  end

  @doc """
  The `n` pages changed most lately, as rows, for the wiki's index. Takes
  the same options as `children/3`.
  """
  def recent(%Board{id: board_id}, opts, n) do
    from(p in Page,
      as: :page,
      where: p.board_id == ^board_id,
      order_by: [desc: p.updated_at, desc: p.id],
      limit: ^n,
      select: struct(p, ^@page_fields)
    )
    |> where(^visible(opts, :page))
    |> Repo.all()
    |> Enum.map(&page_row(&1, 0))
  end

  @doc """
  What a listing shows under each of these pages' titles, and no more: the
  summary, and the first 400 characters of the body for when there is none.
  `%{page_id => %{summary: text, body: text}}`.
  """
  def excerpts([]), do: %{}

  def excerpts(ids) do
    from(p in Page,
      where: p.id in ^ids,
      select: {p.id, %{summary: p.summary, body: fragment("substr(?, 1, 400)", p.body)}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  What a preview of one page in the tree shows (#760): the page, with its
  summary, tags, who changed it last and how many pages are under it, and
  the start of its body (the first 2,000 characters) — or nil when it is
  not on `board`, or these options (the tree's own) would not show it.
  """
  def preview(%Board{id: board_id}, page_id, opts \\ []) when is_integer(page_id) do
    from(p in Page,
      as: :page,
      where: p.id == ^page_id and p.board_id == ^board_id,
      left_join: u in assoc(p, :updated_by),
      select: %{
        page: struct(p, ^[:summary, :note_tags | @page_fields]),
        body: fragment("substr(?, 1, 2000)", p.body),
        updated_by: u
      }
    )
    |> where(^visible(opts, :page))
    |> Repo.one()
    |> case do
      nil ->
        nil

      found ->
        children =
          from(p in Page, as: :page, where: p.parent_id == ^page_id)
          |> where(^visible(opts, :page))
          |> Repo.aggregate(:count)

        Map.put(found, :children, children)
    end
  end

  @doc """
  How many pages are shown on `board` under these options: what the count in
  the wiki's toolbar says.
  """
  def count(%Board{id: board_id}, opts \\ []) do
    from(p in Page, as: :page, where: p.board_id == ^board_id)
    |> where(^visible(opts, :page))
    |> Repo.aggregate(:count)
  end

  @doc """
  The containers to open to show `page`, outermost first: the folders it is
  filed under, then the pages above it in its own folder. What revealing a
  page in the tree opens (R11.7).
  """
  def path_to(%Page{} = page, folders \\ nil) do
    folders = folders || Folders.list(page.board_id)

    folder_path =
      case page.folder_id && Enum.find(folders, &(&1.id == page.folder_id)) do
        nil -> []
        folder -> folder_chain(folder, folders)
      end

    folder_path ++ Enum.map(page_chain(page), &{:page, &1})
  end

  @doc "The containers to open to show `folder`, itself included."
  def path_to_folder(%Folder{} = folder, folders \\ nil),
    do: folder_chain(folder, folders || Folders.list(folder.board_id))

  defp folder_chain(%Folder{} = folder, folders) do
    by_id = Map.new(folders, &{&1.id, &1})

    Stream.iterate(folder, &(&1.parent_id && by_id[&1.parent_id]))
    |> Enum.take_while(& &1)
    |> Enum.reverse()
    |> Enum.map(&{:folder, &1.id})
  end

  # The page's parents for as long as they are filed where it is: past that
  # the tree draws it at the top of its own folder.
  defp page_chain(%Page{parent_id: nil}), do: []

  defp page_chain(%Page{} = page) do
    page.parent_id
    |> Stream.unfold(fn
      nil ->
        nil

      id ->
        case Repo.one(
               from(p in Page, where: p.id == ^id, select: map(p, [:id, :parent_id, :folder_id]))
             ) do
          %{folder_id: folder_id} = up when folder_id == page.folder_id -> {up.id, up.parent_id}
          _ -> nil
        end
    end)
    |> Enum.take(50)
    |> Enum.reverse()
  end

  # The query asked for one row more than the page holds: if it came, there
  # is more to come.
  defp paged(query, opts) do
    case opts[:limit] do
      nil ->
        {Repo.all(query), nil}

      limit ->
        offset = Keyword.get(opts, :offset, 0)
        rows = query |> limit(^(limit + 1)) |> offset(^offset) |> Repo.all()
        through = opts[:through]

        cond do
          length(rows) <= limit ->
            {rows, nil}

          through && offset == 0 && not Enum.any?(Enum.take(rows, limit), &(&1.id == through)) ->
            through_page(query, through, limit)

          true ->
            {Enum.take(rows, limit), offset + limit}
        end
    end
  end

  # The rows up to the page asked for and a little past it, read as ids
  # first so a page that is not in the container costs one narrow query.
  defp through_page(query, through, limit) do
    ids = query |> exclude(:select) |> select([page: p], p.id) |> Repo.all()

    case Enum.find_index(ids, &(&1 == through)) do
      nil ->
        rows = query |> limit(^(limit + 1)) |> Repo.all()
        {Enum.take(rows, limit), limit}

      index ->
        take = max(limit, index + div(limit, 5))
        rows = query |> limit(^(take + 1)) |> Repo.all()

        if length(rows) > take,
          do: {Enum.take(rows, take), take},
          else: {rows, nil}
    end
  end

  defp more_row(nil), do: []
  defp more_row(offset), do: [%{kind: "more", id: offset, offset: offset, count: 0}]

  ## A vault's tree -------------------------------------------------------------

  @doc """
  One level of a vault's tree (R11.3): every board of the vault in one tree,
  laid out by the vault's paths.

  A mapped path is a folder of the tree holding what it maps to — a board's
  whole wiki, or one folder of it. A path that only leads to deeper mappings
  (`Projects` when `Projects/X` is mapped) is a folder of its own, keyed
  `dir:Projects`, unless a folder of a board already sits at that path, when
  the deeper mappings show inside that folder. What is mapped at the vault's
  root is its top level. Below the mappings, every key is a board's own
  (`folder:12`, `page:7`), so the rows are the ones `children/3` gives for
  that board, with whatever is mounted below that place in the vault among
  its folders, in their order (#758).

  `boards` is `%{board_id => {board, opts}}`: the vault's boards this reader
  may open, each with the options its tree is read with (drafts only where
  they can write). Anything on another board is not found, and a mapping of
  one is left out.

  `extra` is passed on to `children/3`, but for `:layout`: what
  `vault_prepare/2` read, for a caller asking for several keys at once.
  """
  def vault_children(%Vault{} = vault, key, boards, extra \\ []) do
    {layout, extra} = Keyword.pop_lazy(extra, :layout, fn -> vault_layout(vault, boards) end)

    case key do
      "vault" ->
        {:ok, level(layout, key, "", [], boards, extra)}

      "dir:" <> path ->
        if Enum.any?(layout.mappings, &under?(&1.path, path)),
          do: {:ok, level(layout, key, path, [], boards, extra)},
          else: {:error, :not_found}

      "board:" <> id ->
        with {:ok, {board, opts}} <- board_in(boards, id),
             {:ok, rows} <- children(board, :root, opts ++ extra),
             do: {:ok, level(layout, key, container_path(layout, key), rows, boards, extra)}

      other ->
        with {:ok, ref} <- parse_ref(other),
             {:ok, board_id} <- board_of(ref),
             {:ok, {board, opts}} <- board_in(boards, board_id),
             {:ok, rows} <- children(board, ref, opts ++ extra),
             do: {:ok, level(layout, other, container_path(layout, other), rows, boards, extra)}
    end
  end

  @doc """
  The vault's mappings and where its folders sit, read once for a caller
  about to ask `vault_children/4` for several keys (pass it as `layout:`).
  """
  def vault_prepare(%Vault{} = vault, boards), do: vault_layout(vault, boards)

  @doc """
  The vault path a board's own wiki starts at, when it is in a vault: where
  its whole wiki is mapped, the shallowest of them when it is mapped twice.
  Nil when only a folder of it is mapped (its wiki is then shown whole, as
  ever, with what is mounted below that folder inside it).
  """
  def vault_root(%Vault{} = vault, board_id, boards) do
    vault |> vault_layout(boards) |> whole_path(board_id)
  end

  @doc """
  The keys to open in a vault's tree to show a page or folder, outermost
  first: the vault's own folders down to the mapping it is under, then the
  board's folders and parent pages below that.

  With `root:` (a vault path), only the keys below it: the way from a
  board's wiki mounted there.
  """
  def vault_path_to(%Vault{} = vault, %{board_id: board_id} = item, boards, opts \\ []) do
    layout = vault_layout(vault, boards)
    root = Keyword.get(opts, :root, "")
    folders = Folders.list(board_id)

    board_path =
      case item do
        %Page{} = page -> path_to(page, folders)
        %Folder{} = folder -> path_to_folder(folder, folders)
      end

    folder_ids = for {:folder, id} <- board_path, do: id

    # The deepest mapping the item is under: one on a folder on its way, or
    # one on its board's whole wiki.
    mapping =
      layout.mappings
      |> Enum.filter(
        &(&1.board_id == board_id and (is_nil(&1.folder_id) or &1.folder_id in folder_ids))
      )
      |> Enum.max_by(&depth_in(&1.folder_id, folder_ids), fn -> nil end)

    case mapping do
      nil ->
        []

      m ->
        below =
          case m.folder_id do
            nil -> board_path
            id -> Enum.drop_while(board_path, &(&1 != {:folder, id})) |> Enum.drop(1)
          end

        above =
          m.path
          |> prefixes()
          |> Enum.filter(&(root == "" or (&1 != root and under?(&1, root))))
          |> Enum.map(&row_key(layout, &1))

        Enum.uniq(above ++ Enum.map(below, &ref_key/1))
    end
  end

  @doc """
  Every container in a vault's tree that holds folders: the vault's own
  folders, the mapped boards and folders, and every folder on the vault's
  boards. What "open all" opens.
  """
  def vault_folder_keys(%Vault{} = vault, boards) do
    layout = vault_layout(vault, boards)

    vault_rows =
      layout.mappings
      |> Enum.flat_map(&prefixes(&1.path))
      |> Enum.uniq()
      |> Enum.map(&row_key(layout, &1))

    folders =
      from(f in Folder, where: f.board_id in ^Map.keys(boards), select: f.id)
      |> Repo.all()
      |> Enum.map(&"folder:#{&1}")

    Enum.uniq(vault_rows ++ folders)
  end

  defp depth_in(nil, _ids), do: -1
  defp depth_in(id, ids), do: Enum.find_index(ids, &(&1 == id))

  defp prefixes(""), do: []

  defp prefixes(path) do
    segments = String.split(path, "/", trim: true)
    for n <- 1..length(segments), do: segments |> Enum.take(n) |> Enum.join("/")
  end

  # The vault as its tree needs it: the mappings this reader may open, where
  # each mapped board's folders sit in it, and which of those paths are a
  # folder in its board's own place (`native`), rather than a folder mounted
  # there by a mapping of its own.
  defp vault_layout(%Vault{} = vault, boards) do
    mappings = vault_mappings(vault, boards)
    dirs = Slipdock.Vaults.Layout.folder_dirs(mappings)
    mounted = for %{folder_id: id} <- mappings, id, into: MapSet.new(), do: id

    native =
      for {id, dir} <- dirs,
          not MapSet.member?(mounted, id),
          into: %{},
          do: {String.downcase(dir), id}

    %{mappings: mappings, dirs: dirs, native: native}
  end

  defp vault_mappings(%Vault{id: vault_id}, boards) do
    from(m in Mapping,
      where: m.vault_id == ^vault_id,
      order_by: [asc: m.path],
      select: %{board_id: m.board_id, folder_id: m.folder_id, path: m.path}
    )
    |> Repo.all()
    |> Enum.filter(&Map.has_key?(boards, &1.board_id))
  end

  # Where a container sits in the vault, or nil for one in no mapped part of
  # it (a page, which holds pages and nothing mounted).
  defp container_path(_layout, "vault"), do: ""
  defp container_path(_layout, "dir:" <> path), do: path

  defp container_path(layout, "board:" <> id) do
    case Integer.parse(id) do
      {n, ""} -> whole_path(layout, n)
      _ -> nil
    end
  end

  defp container_path(layout, "folder:" <> id) do
    case Integer.parse(id) do
      {n, ""} -> layout.dirs[n]
      _ -> nil
    end
  end

  defp container_path(_layout, _key), do: nil

  defp whole_path(layout, board_id) do
    layout.mappings
    |> Enum.filter(&(&1.board_id == board_id and is_nil(&1.folder_id)))
    |> Enum.map(& &1.path)
    |> Enum.min_by(&{length(String.split(&1, "/", trim: true)), &1}, fn -> nil end)
  end

  defp board_in(boards, id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> board_in(boards, n)
      _ -> {:error, :not_found}
    end
  end

  defp board_in(boards, id) do
    case Map.fetch(boards, id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_found}
    end
  end

  defp board_of({:folder, id}),
    do: one_board(from(f in Folder, where: f.id == ^id, select: f.board_id))

  defp board_of({:page, id}),
    do: one_board(from(p in Page, where: p.id == ^id, select: p.board_id))

  defp board_of(:root), do: {:error, :not_found}

  defp one_board(query) do
    case Repo.one(query) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  defp under?(path, ""), do: path != nil
  defp under?(path, dir), do: String.starts_with?(path, dir <> "/") or path == dir

  defp same_path?(a, b), do: String.downcase(a) == String.downcase(b)

  # A path's row: a board's folder that sits there in its own place; the
  # mapping itself when it is the only thing mapped there; or a `dir:` row
  # holding what is mapped there and below.
  defp row_key(layout, path) do
    exact = Enum.filter(layout.mappings, &same_path?(&1.path, path))

    cond do
      id = layout.native[String.downcase(path)] ->
        "folder:#{id}"

      match?([_], exact) and container_path(layout, mount_key(hd(exact))) == path ->
        mount_key(hd(exact))

      true ->
        "dir:" <> path
    end
  end

  defp mount_key(%{folder_id: nil, board_id: id}), do: "board:#{id}"
  defp mount_key(%{folder_id: id}), do: "folder:#{id}"

  defp mount_ref(%{folder_id: nil}), do: :root
  defp mount_ref(%{folder_id: id}), do: {:folder, id}

  # A container's rows with the vault around it: what else is mapped right
  # where it sits, and a row for each path mounted below it, sorted in among
  # its folders. Mounts come with the first page of rows, as folders do.
  defp level(_layout, _key, nil, rows, _boards, _extra), do: rows

  defp level(layout, key, path, rows, boards, extra) do
    here =
      layout.mappings
      |> Enum.filter(&(same_path?(&1.path, path) and mount_key(&1) != key))
      |> Enum.flat_map(fn m ->
        {board, opts} = boards[m.board_id]

        case children(board, mount_ref(m), opts ++ extra) do
          {:ok, rows} -> rows
          _ -> []
        end
      end)

    mounts =
      if Keyword.get(extra, :offset, 0) == 0,
        do: layout |> mounted_below(path) |> Enum.map(&mount_row(layout, &1, boards)),
        else: []

    (rows ++ here)
    |> Enum.map(&holding_mounts(&1, layout))
    |> arrange(mounts)
  end

  # A board's folder with nothing of its own in it can still hold what is
  # mounted below it: it opens.
  defp holding_mounts(%{kind: "folder", id: id, count: 0} = row, layout) when is_integer(id) do
    case layout.dirs[id] do
      nil -> row
      dir -> if mounted_below(layout, dir) == [], do: row, else: %{row | count: 1}
    end
  end

  defp holding_mounts(row, _layout), do: row

  # The paths one step below `path` that something is mounted at or under,
  # and that are no board's folder in its own place (those are rows of
  # their board already, and what is mounted below them shows inside them).
  defp mounted_below(layout, path) do
    prefix = if path == "", do: "", else: path <> "/"

    layout.mappings
    |> Enum.filter(&(not same_path?(&1.path, path) and under?(&1.path, path)))
    |> Enum.map(fn m ->
      rest = String.slice(m.path, String.length(prefix)..-1//1)
      prefix <> hd(String.split(rest, "/"))
    end)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.reject(&Map.has_key?(layout.native, String.downcase(&1)))
  end

  # Folders (the board's and the mounted ones together) in their order, then
  # pages and files, then where to ask for more. Mounts go in among the
  # folders by name: before the first folder whose name sorts after theirs,
  # so a tree sorted by name stays sorted and a hand-ordered one keeps its
  # order.
  defp arrange(rows, mounts) do
    {folders, rest} = Enum.split_with(rows, &(&1.kind in ["folder", "dir"]))
    {more, rest} = Enum.split_with(rest, &(&1.kind == "more"))
    merge(folders, Enum.sort_by(mounts, &String.downcase(&1.title))) ++ rest ++ more
  end

  defp merge(folders, []), do: folders
  defp merge([], mounts), do: mounts

  defp merge([f | fs] = folders, [m | ms] = mounts) do
    if String.downcase(m.title) < String.downcase(to_string(f.title)),
      do: [m | merge(folders, ms)],
      else: [f | merge(fs, mounts)]
  end

  defp mount_row(layout, path, boards, pages \\ nil) do
    key = row_key(layout, path)

    {board_id, count} =
      case Enum.filter(layout.mappings, &same_path?(&1.path, path)) do
        [m] ->
          {m.board_id, if(pages, do: pages.(m), else: mount_pages(m, boards))}

        _ ->
          {nil, nil}
      end

    %{
      kind: if(String.starts_with?(key, "dir:"), do: "dir", else: "folder"),
      key: key,
      id: key,
      board_id: board_id,
      title: path |> String.split("/") |> List.last(),
      mount: true,
      count: 1,
      pages: count
    }
  end

  defp mount_pages(m, boards) do
    {board, opts} = boards[m.board_id]

    case m.folder_id do
      nil ->
        count(board, opts)

      id ->
        opts
        |> Keyword.get_lazy(:stats, fn -> stats(board, Folders.list(board), opts) end)
        |> get_in([:totals, id])
    end
  end

  @doc """
  `filter/3` over a whole vault: each board's pages filtered as its own tree
  would be, laid out under the vault's paths, with only the mapped folders
  and vault folders that hold something shown. Keys as `vault_children/4`
  gives them; `shown` counts every board's matches.

  With `root:` (a vault path), only what is at or below it: a board's wiki
  mounted there filters what it shows, and no more. `top` is the key the
  top of it is under: `vault`, or the board's (`board:<id>`) mounted there.
  """
  def vault_filter(%Vault{} = vault, boards, filters, extra \\ []) do
    {root, extra} = Keyword.pop(extra, :root)
    layout = vault_layout(vault, boards)

    layout =
      if root,
        do: %{layout | mappings: Enum.filter(layout.mappings, &under?(&1.path, root))},
        else: layout

    in_scope = layout.mappings |> Enum.map(& &1.board_id) |> MapSet.new()

    per_board =
      for {id, {board, opts}} <- boards, MapSet.member?(in_scope, id), into: %{} do
        result = filter(board, filters, opts ++ extra)

        nodes =
          Map.new(result.nodes, fn {k, v} -> {if(k == "root", do: "board:#{id}", else: k), v} end)

        {id, %{result | nodes: nodes}}
      end

    nodes = per_board |> Map.values() |> Enum.map(& &1.nodes) |> Enum.reduce(%{}, &Map.merge/2)
    kept = Enum.filter(layout.mappings, &Map.has_key?(nodes, mount_key(&1)))

    folder_pages =
      for {_k, rows} <- nodes, %{kind: "folder", id: id, pages: n} <- rows, into: %{}, do: {id, n}

    pages_of = fn
      %{folder_id: nil, board_id: id} -> per_board[id].shown
      %{folder_id: id} -> Map.get(folder_pages, id)
    end

    kept_layout = %{layout | mappings: kept}
    root = root || ""
    top = top_key(layout, root)

    # Every place in the vault that holds a match below it: the paths down
    # to each kept mapping, below the root.
    paths =
      kept
      |> Enum.flat_map(&prefixes(&1.path))
      |> Enum.filter(&(root == "" or (&1 != root and under?(&1, root))))
      |> Enum.uniq_by(&String.downcase/1)

    # Each such path is a row of the place above it: a mount, a vault
    # folder, or a board's folder that only holds a match through what is
    # mounted inside it.
    containers = [root | paths]

    vault_nodes =
      for path <- containers, into: %{} do
        key = if path == root, do: top, else: row_key(kept_layout, path)

        here =
          kept
          |> Enum.filter(&(same_path?(&1.path, path) and mount_key(&1) != key))
          |> Enum.flat_map(&Map.get(nodes, mount_key(&1), []))

        own = Map.get(nodes, key, [])
        listed = MapSet.new(own ++ here, &"#{&1.kind}:#{&1[:key] || &1.id}")

        mounts =
          paths
          |> Enum.filter(&(parent_path(&1) |> same_path?(path)))
          |> Enum.map(&row_for(kept_layout, &1, boards, pages_of))
          |> Enum.reject(&MapSet.member?(listed, "#{&1.kind}:#{&1[:key] || &1.id}"))

        {key, arrange(own ++ here, mounts)}
      end

    %{
      nodes: nodes |> Map.merge(vault_nodes) |> Map.reject(fn {_k, rows} -> rows == [] end),
      top: top,
      shown: per_board |> Map.values() |> Enum.map(& &1.shown) |> Enum.sum(),
      only:
        per_board
        |> Map.values()
        |> Enum.map(& &1.only)
        |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    }
  end

  # The key of the top of a filtered tree: the vault's, or the board's
  # mounted at the root asked for.
  defp top_key(_layout, ""), do: "vault"

  defp top_key(layout, root) do
    case Enum.find(layout.mappings, &(is_nil(&1.folder_id) and same_path?(&1.path, root))) do
      nil -> row_key(layout, root)
      m -> mount_key(m)
    end
  end

  defp parent_path(path) do
    case String.split(path, "/") |> Enum.drop(-1) do
      [] -> ""
      segments -> Enum.join(segments, "/")
    end
  end

  # A filtered tree's row for a path: its board's folder when one sits
  # there (holding a match only through what is mounted in it, so it is
  # context), or the mount or vault folder.
  defp row_for(layout, path, boards, pages_of) do
    case layout.native[String.downcase(path)] do
      nil ->
        mount_row(layout, path, boards, pages_of)

      id ->
        %{
          kind: "folder",
          id: id,
          board_id: board_id_of(layout, id),
          title: path |> String.split("/") |> List.last(),
          count: 1,
          pages: nil,
          context: true
        }
    end
  end

  defp board_id_of(_layout, folder_id) do
    case board_of({:folder, folder_id}) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  ## Filtering -----------------------------------------------------------------

  @doc """
  The tree a filter leaves, every level of it at once (a hit three folders
  down is no use behind a shut one): `%{nodes: %{ref_key => rows}, shown: n,
  only: ids}`, `only` being the matches themselves.

  A page is shown when the filter bar lets it through (`Slipdock.Filters`),
  or when it is filed under a folder whose name matches the search, with
  everything else in that folder. The pages it is part of and the folders it
  is filed under come with it, so a match is always seen where it lives;
  those that are only there for that are marked `context: true`. Folders with
  nothing shown in them are left out. Files answer no filter and are left
  out too.

  One query of the board's pages, without their bodies, and the rest in
  memory. `shown` counts the matches, not the context.
  """
  def filter(%Board{} = board, filters, opts \\ []) do
    folders = Keyword.get_lazy(opts, :folders, fn -> Folders.list(board) end)
    {text, tags} = split_query(filters.q)
    pages = candidates(board, filters, opts)
    hit_folders = matching_folders(folders, text)

    # The search box's words, on their own; the rest of the bar applies to
    # every page, folder hits included.
    facets = %{filters | q: ""}
    words = %{Filters.empty() | q: text}

    in_body =
      if opts[:contents] && text != "",
        do: body_matches(board, text, opts),
        else: MapSet.new()

    matched =
      pages
      |> Enum.filter(fn page ->
        Filters.matches?(page, facets) and tagged?(page, tags) and
          (text == "" or Filters.matches?(page, words) or
             MapSet.member?(in_body, page.id) or MapSet.member?(hit_folders, page.folder_id))
      end)
      |> MapSet.new(& &1.id)

    by_id = Map.new(pages, &{&1.id, &1})

    shown_ids =
      Enum.reduce(matched, matched, fn id, acc -> up_chain(by_id[id], by_id, acc) end)

    shown = Enum.filter(pages, &MapSet.member?(shown_ids, &1.id))

    # A page's container in what is shown: under its parent when that is
    # shown and filed alongside it, otherwise at the top of its folder.
    container = fn page ->
      case page.parent_id && by_id[page.parent_id] do
        %{folder_id: f} = up when f == page.folder_id ->
          if MapSet.member?(shown_ids, up.id), do: "page:#{up.id}", else: folder_key(f)

        _ ->
          folder_key(page.folder_id)
      end
    end

    pages_in = Enum.group_by(shown, container)

    direct = shown |> Enum.reject(&is_nil(&1.folder_id)) |> Enum.frequencies_by(& &1.folder_id)
    totals = roll_up(folders, direct)

    folder_ids =
      folders
      |> Enum.filter(&(Map.get(totals, &1.id, 0) > 0 or MapSet.member?(hit_folders, &1.id)))
      |> MapSet.new(& &1.id)

    kept_folders = Enum.filter(folders, &MapSet.member?(folder_ids, &1.id))
    subfolders = Enum.group_by(kept_folders, & &1.parent_id)

    page_row = fn page ->
      kids = length(Map.get(pages_in, "page:#{page.id}", []))
      row = page_row(page, kids)
      if MapSet.member?(matched, page.id), do: row, else: Map.put(row, :context, true)
    end

    folder_row = fn folder ->
      key = folder_key(folder.id)

      %{
        kind: "folder",
        id: folder.id,
        board_id: folder.board_id,
        title: folder.name,
        slug: folder.slug,
        parent_id: folder.parent_id,
        count: length(Map.get(subfolders, folder.id, [])) + length(Map.get(pages_in, key, [])),
        pages: Map.get(totals, folder.id, 0)
      }
    end

    folder_nodes =
      for parent <- [nil | Enum.map(kept_folders, & &1.id)], into: %{} do
        sort = sort_of(board, folders, parent)

        rows =
          subfolders
          |> Map.get(parent, [])
          |> sort_folders(sort)
          |> Enum.map(folder_row)

        pages =
          pages_in |> Map.get(folder_key(parent), []) |> sort_pages(sort) |> Enum.map(page_row)

        {folder_key(parent), rows ++ pages}
      end

    page_nodes =
      for {"page:" <> _ = key, kids} <- pages_in, into: %{} do
        {key, kids |> sort_pages("manual") |> Enum.map(page_row)}
      end

    %{
      nodes: folder_nodes |> Map.merge(page_nodes) |> Map.reject(fn {_k, rows} -> rows == [] end),
      shown: MapSet.size(matched),
      only: matched
    }
  end

  defp folder_key(nil), do: "root"
  defp folder_key(id), do: "folder:#{id}"

  defp sort_pages(pages, "name"), do: Enum.sort_by(pages, &{String.downcase(&1.title), &1.id})

  defp sort_pages(pages, "modified"),
    do:
      Enum.sort_by(pages, &{&1.updated_at, &1.id}, fn {a, i}, {b, j} ->
        DateTime.compare(a, b) == :gt or (a == b and i >= j)
      end)

  defp sort_pages(pages, "created"),
    do:
      Enum.sort_by(pages, &{&1.inserted_at, &1.id}, fn {a, i}, {b, j} ->
        DateTime.compare(a, b) == :gt or (a == b and i >= j)
      end)

  defp sort_pages(pages, _manual),
    do: Enum.sort_by(pages, &{&1.position, String.downcase(&1.title), &1.id})

  defp up_chain(%{parent_id: nil}, _by_id, acc), do: acc

  defp up_chain(page, by_id, acc) do
    case by_id[page.parent_id] do
      %{folder_id: f} = up when f == page.folder_id ->
        if MapSet.member?(acc, up.id), do: acc, else: up_chain(up, by_id, MapSet.put(acc, up.id))

      _ ->
        acc
    end
  end

  @doc """
  The search box's words and its `#tags`, apart: `"retry #ops/oncall"` is
  `{"retry", ["ops/oncall"]}`.
  """
  def split_query(q) do
    {tags, words} =
      (q || "")
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.split_with(&(String.starts_with?(&1, "#") and String.length(&1) > 1))

    {Enum.join(words, " "),
     Enum.map(tags, &(&1 |> String.trim_leading("#") |> String.downcase()))}
  end

  # A `#tag` in the search box: a note tag (or one nested under it,
  # `#area` finding `area/sub`), or one of the board's own tags by name.
  defp tagged?(_page, []), do: true

  defp tagged?(page, tags) do
    note = Enum.map(page.note_tags || [], &String.downcase/1)
    board = for %{name: name} <- tags_of(page), do: String.downcase(name)

    Enum.all?(tags, fn tag ->
      tag in board or Enum.any?(note, &(&1 == tag or String.starts_with?(&1, tag <> "/")))
    end)
  end

  defp tags_of(%{tags: tags}) when is_list(tags), do: tags
  defp tags_of(_), do: []

  # The pages whose text holds the words, worked out by the database: the
  # bodies are matched where they are and never come back.
  defp body_matches(%Board{id: board_id}, text, opts) do
    like = "%" <> String.replace(text, ~r/([\\%_])/, "\\\\\\1") <> "%"

    from(p in Page,
      as: :page,
      where: p.board_id == ^board_id and ilike(p.body, ^like),
      select: p.id
    )
    |> where(^visible(Keyword.delete(opts, :only), :page))
    |> Repo.all()
    |> MapSet.new()
  end

  # What a filter reads of each page: the row's columns, the summary its
  # search box matches, its note tags, and the board's tags when a filter
  # asks about them.
  defp candidates(%Board{id: board_id}, filters, opts) do
    query =
      from(p in Page,
        as: :page,
        where: p.board_id == ^board_id,
        select: struct(p, ^[:summary, :note_tags | @page_fields])
      )
      |> where(^visible(Keyword.delete(opts, :only), :page))

    query =
      if filters.tags != [] or String.trim(filters.q) != "",
        do: preload(query, :tags),
        else: query

    Repo.all(query)
  end

  # Every folder whose name holds the search, and everything beneath it:
  # filing is a path, so matching "Design" means its Decisions are in too.
  defp matching_folders(folders, q) do
    case String.downcase(String.trim(q || "")) do
      "" ->
        MapSet.new()

      term ->
        hits =
          folders
          |> Enum.filter(&String.contains?(String.downcase(&1.name), term))
          |> MapSet.new(& &1.id)

        by_id = Map.new(folders, &{&1.id, &1})

        folders
        |> Enum.filter(fn folder ->
          Stream.iterate(folder, &(&1.parent_id && by_id[&1.parent_id]))
          |> Enum.take_while(& &1)
          |> Enum.any?(&MapSet.member?(hits, &1.id))
        end)
        |> MapSet.new(& &1.id)
    end
  end

  ## Rows ----------------------------------------------------------------------

  # How a container orders its pages: the folder's own choice, or the
  # board's for its top.
  defp sort_of(%Board{} = board, _folders, nil), do: Map.get(board, :wiki_sort) || "manual"

  defp sort_of(_board, folders, folder_id) do
    case Enum.find(folders, &(&1.id == folder_id)) do
      %Folder{sort: sort} when is_binary(sort) -> sort
      _ -> "manual"
    end
  end

  # Folders come first whatever the order: by name when the pages are,
  # otherwise as they were arranged.
  defp sort_folders(folders, "name"),
    do: Enum.sort_by(folders, &{String.downcase(&1.name), &1.id})

  defp sort_folders(folders, _sort),
    do: Enum.sort_by(folders, &{&1.position, String.downcase(&1.name), &1.id})

  defp folder_rows(folders, parent_id, stats, sort) do
    folders
    |> Enum.filter(&(&1.parent_id == parent_id))
    |> sort_folders(sort)
    |> Enum.map(fn folder ->
      %{
        kind: "folder",
        id: folder.id,
        board_id: folder.board_id,
        title: folder.name,
        slug: folder.slug,
        parent_id: folder.parent_id,
        count:
          Enum.count(folders, &(&1.parent_id == folder.id)) +
            Map.get(stats.top, folder.id, 0) + Map.get(stats.files, folder.id, 0),
        pages: Map.get(stats.totals, folder.id, 0),
        sort: folder.sort || "manual"
      }
    end)
  end

  defp page_rows(pages, opts) do
    counts = child_counts(Enum.map(pages, & &1.id), opts)
    Enum.map(pages, &page_row(&1, Map.get(counts, &1.id, 0)))
  end

  @doc false
  def page_row(page, count) do
    %{
      kind: "page",
      id: page.id,
      board_id: page.board_id,
      title: page.title,
      slug: page.slug,
      code: page.code,
      parent_id: page.parent_id,
      folder_id: page.folder_id,
      count: count,
      draft: page.status == "draft",
      template: page.template,
      archived: not is_nil(page.archived_at),
      encrypted: page.encrypted == true,
      priority: page.priority,
      flags: page.flags || [],
      due: page.due_date,
      completed: page.completed,
      inserted_at: page.inserted_at,
      updated_at: page.updated_at
    }
  end

  defp file_rows(%Board{id: board_id}, folder_id, opts) do
    if opts[:only] do
      # A filter is narrowing pages; files answer none of its questions.
      []
    else
      from(f in WikiFile,
        where: f.board_id == ^board_id and is_nil(f.archived_at),
        order_by: [asc: fragment("lower(?)", f.name), asc: f.id],
        select: map(f, [:id, :board_id, :name, :content_type, :folder_id])
      )
      |> in_folder(folder_id)
      |> Repo.all()
      |> Enum.map(fn file ->
        %{
          kind: "file",
          id: file.id,
          board_id: file.board_id,
          title: file.name,
          content_type: file.content_type,
          folder_id: file.folder_id,
          encrypted: Slipdock.Wiki.Meld.note_file?(file.name),
          count: 0
        }
      end)
    end
  end

  # The pages also filed in a folder (W-103 R12.2): after the ones at home
  # there, each marked `also` and with the folder it is placed in, never
  # one that is already listed. The page's home board decides who sees it:
  # a draft only for its writers, the page only for its readers.
  defp also_rows(_board, nil, _listed, _opts), do: []

  defp also_rows(%Board{} = board, folder_id, listed, opts) do
    pages =
      from(p in Page,
        as: :page,
        join: pl in Placement,
        on: pl.page_id == p.id,
        where: pl.folder_id == ^folder_id and p.id not in ^listed,
        order_by: [asc: pl.position, asc: fragment("lower(?)", p.title)],
        select: struct(p, ^@page_fields)
      )
      |> where(^visible(Keyword.drop(opts, [:status, :template]), :page))
      |> Repo.all()
      |> readable_also(board, opts)

    counts = child_counts(Enum.map(pages, & &1.id), opts)

    Enum.map(pages, fn page ->
      page
      |> page_row(Map.get(counts, page.id, 0))
      |> Map.merge(%{also: true, placed_in: folder_id})
    end)
  end

  defp readable_also([], _board, _opts), do: []

  defp readable_also(pages, %Board{id: board_id} = board, opts) do
    reader = opts[:as]

    levels =
      pages
      |> Enum.map(& &1.board_id)
      |> Enum.uniq()
      |> Map.new(fn
        ^board_id when is_nil(reader) ->
          {board_id, {true, opts[:status] != "published"}}

        id when is_nil(reader) ->
          {id, {false, false}}

        id ->
          home = if id == board_id, do: board, else: Repo.get(Board, id)
          perm = home && Slipdock.Access.board_permission(reader, home)

          {id,
           {perm && Slipdock.Access.can_read?(perm), perm && Slipdock.Access.can_write?(perm)}}
      end)

    Enum.filter(pages, fn page ->
      {read, write} = levels[page.board_id]

      read && (page.status != "draft" or write) &&
        (Keyword.get(opts, :template) != false or not page.template)
    end)
  end

  defp in_folder(query, nil), do: where(query, [x], is_nil(x.folder_id))
  defp in_folder(query, id), do: where(query, [x], x.folder_id == ^id)

  ## Queries -------------------------------------------------------------------

  # The pages at the top of a folder: filed there, with no parent drawn above
  # them in it. A parent filed elsewhere, or one the options hide, leaves the
  # page at the top rather than lost.
  defp top_query(board_id, opts) do
    from(p in Page,
      as: :page,
      left_join: up in Page,
      as: :up,
      on:
        up.id == p.parent_id and
          fragment("? IS NOT DISTINCT FROM ?", up.folder_id, p.folder_id),
      where: p.board_id == ^board_id
    )
    |> where(^visible(opts, :page))
    |> where(^hidden_parent(opts))
  end

  # The left join finds the parent when it is filed with the page; the page
  # is at the top when there is none, or the one there is would not be shown.
  defp hidden_parent(opts) do
    dynamic([up: up], is_nil(up.id) or not (^visible(opts, :up)))
  end

  defp top_pages(%Board{id: board_id}, folder_id, sort, opts) do
    top_query(board_id, opts)
    |> in_folder(folder_id)
    |> order_pages(sort)
    |> select([page: p], struct(p, ^@page_fields))
  end

  defp order_pages(query, "name"),
    do: order_by(query, [page: p], asc: fragment("lower(?)", p.title), asc: p.id)

  defp order_pages(query, "modified"),
    do: order_by(query, [page: p], desc: p.updated_at, desc: p.id)

  defp order_pages(query, "created"),
    do: order_by(query, [page: p], desc: p.inserted_at, desc: p.id)

  defp order_pages(query, _manual),
    do: order_by(query, [page: p], asc: p.position, asc: fragment("lower(?)", p.title), asc: p.id)

  defp child_pages(%Page{} = parent, opts) do
    from(p in Page,
      as: :page,
      where: p.parent_id == ^parent.id,
      where: fragment("? IS NOT DISTINCT FROM ?", p.folder_id, ^parent.folder_id),
      order_by: [asc: p.position, asc: fragment("lower(?)", p.title), asc: p.id],
      select: struct(p, ^@page_fields)
    )
    |> where(^visible(opts, :page))
  end

  # How many shown pages are part of each of these, filed alongside it.
  defp child_counts([], _opts), do: %{}

  defp child_counts(ids, opts) do
    from(c in Page,
      as: :page,
      join: p in Page,
      on: p.id == c.parent_id,
      where: p.id in ^ids,
      where: fragment("? IS NOT DISTINCT FROM ?", c.folder_id, p.folder_id),
      group_by: p.id,
      select: {p.id, count(c.id)}
    )
    |> where(^visible(opts, :page))
    |> Repo.all()
    |> Map.new()
  end

  # Per folder, for its row: the pages at its top, its files, and every page
  # beneath it at any depth. Three grouped counts for the whole board.
  defp stats(%Board{id: board_id}, folders, opts) do
    direct =
      from(p in Page,
        as: :page,
        where: p.board_id == ^board_id and not is_nil(p.folder_id),
        group_by: p.folder_id,
        select: {p.folder_id, count(p.id)}
      )
      |> where(^visible(opts, :page))
      |> Repo.all()
      |> Map.new()

    top =
      top_query(board_id, opts)
      |> where([page: p], not is_nil(p.folder_id))
      |> group_by([page: p], p.folder_id)
      |> select([page: p], {p.folder_id, count(p.id)})
      |> Repo.all()
      |> Map.new()

    files =
      if opts[:only] do
        %{}
      else
        from(f in WikiFile,
          where: f.board_id == ^board_id and is_nil(f.archived_at) and not is_nil(f.folder_id),
          group_by: f.folder_id,
          select: {f.folder_id, count(f.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    # Pages also filed in a folder make it something to open, but are
    # counted once, at home, in its page total (R12.7).
    also =
      if opts[:only] do
        %{}
      else
        folder_ids = Enum.map(folders, & &1.id)

        from(pl in Placement,
          join: p in Page,
          on: p.id == pl.page_id,
          where: pl.folder_id in ^folder_ids and is_nil(p.archived_at),
          group_by: pl.folder_id,
          select: {pl.folder_id, count(pl.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    files = Map.merge(files, also, fn _k, a, b -> a + b end)
    %{top: top, files: files, totals: roll_up(folders, direct)}
  end

  # Every folder's pages and its subfolders' pages, from the direct counts.
  defp roll_up(folders, direct) do
    by_parent = Enum.group_by(folders, & &1.parent_id)

    total = fn total, id ->
      Map.get(direct, id, 0) +
        (by_parent |> Map.get(id, []) |> Enum.map(&total.(total, &1.id)) |> Enum.sum())
    end

    Map.new(folders, &{&1.id, total.(total, &1.id)})
  end

  # Which pages the options let through, for the page bound as `binding`.
  defp visible(opts, binding) do
    conditions =
      [
        archived_condition(Keyword.get(opts, :archived, false), binding),
        template_condition(Keyword.get(opts, :template), binding),
        status_condition(Keyword.get(opts, :status), binding),
        only_condition(Keyword.get(opts, :only), binding)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.reduce(conditions, dynamic(true), &dynamic(^&2 and ^&1))
  end

  defp archived_condition(:all, _b), do: nil
  defp archived_condition(true, b), do: dynamic([{^b, p}], not is_nil(p.archived_at))
  defp archived_condition(_false, b), do: dynamic([{^b, p}], is_nil(p.archived_at))

  defp template_condition(true, b), do: dynamic([{^b, p}], p.template)
  defp template_condition(false, b), do: dynamic([{^b, p}], not p.template)
  defp template_condition(_any, _b), do: nil

  defp status_condition(status, b) when status in ["draft", "published"],
    do: dynamic([{^b, p}], p.status == ^status)

  defp status_condition(_any, _b), do: nil

  defp only_condition(nil, _b), do: nil

  defp only_condition(ids, b) do
    ids = Enum.to_list(ids)
    dynamic([{^b, p}], p.id in ^ids)
  end
end
