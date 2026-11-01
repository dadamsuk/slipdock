defmodule Slipdock.Vaults.Layout do
  @moduledoc """
  A vault laid out as files: where on disk a sync writes every page, and
  which folder or parent page a path on disk names (W-103 R2.10, R2.11).

  It is derived from the boards and kept nowhere (W-2201): every root board
  the vault's owner has, archived too, is a folder off the root, and a
  sub-board is its epic's folder, `<Board>/Cards/<Epic>`, at any depth. So a
  new, renamed or archived board needs no bookkeeping. The rules below turn
  that into file names:

    * every segment is a disk name (`Slipdock.Wiki.DiskName`), bounded and
      safe on any machine; the titles stay whole in the listing;
    * a page is `Title.md`, or `Title/index.md` when it has children, which
      sit beside that index as they do in an export;
    * a card's write-up, a page in its folder titled like the card, is named
      as the folder is (`CardFolders.own_page_name/2`);
    * two things wanting one name — two pages titled alike in one folder, a
      page with children and a folder of the same name — are told apart by
      the later one taking a number (`Title (2).md`), compared case aside,
      since half the machines a vault is synced to cannot tell `Note.md`
      from `note.md`. Folders come first, then pages, then files, each oldest
      first, so the oldest keeps the plain name.

  Built from narrow queries with no bodies in them, so a write can ask where
  everything is without reading every page.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Vaults.Vault
  alias Slipdock.Wiki.{CardFolders, DiskName, Folder, Page}

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
          boards: %{pos_integer => String.t()},
          folder_boards: %{pos_integer => pos_integer},
          virtual: %{String.t() => map}
        }

  @typedoc """
  Where the vault's containers are: `boards` and `folders` as disk paths,
  `full_boards` and `full_folders` as segments of whole names (what a link
  matches), `virtual` the directories that are neither (a `Cards` folder or
  an epic's folder nobody has made yet), `virtual_details` whose board and
  epic each of those is, and `folder_boards` whose each folder is.
  """
  @type dirs :: %{
          boards: %{pos_integer => String.t()},
          folders: %{pos_integer => String.t()},
          full_boards: %{pos_integer => [String.t()]},
          full_folders: %{pos_integer => [String.t()]},
          folder_boards: %{pos_integer => pos_integer},
          virtual: [String.t()],
          virtual_details: %{String.t() => map}
        }

  @doc "Where every live page and folder of the vault sits on disk."
  @spec build(Vault.t()) :: t
  def build(%Vault{} = vault) do
    found = dirs(vault)
    roots = found.boards
    board_ids = Map.keys(roots)
    folder_dirs = found.folders

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
    own_pages = CardFolders.own_pages(board_ids)

    parents =
      for p <- pages, p.parent_id && by_id[p.parent_id], into: MapSet.new(), do: p.parent_id

    # A page with children is a directory too, and must not be one a folder
    # or a board already is.
    taken =
      folder_dirs
      |> Map.values()
      |> Kernel.++(Map.values(roots))
      |> Kernel.++(found.virtual)
      |> Enum.flat_map(&prefixes/1)
      |> Map.new(&{String.downcase(&1), :folder})

    {placed, taken, _dirs} =
      pages
      |> Enum.map(&{&1, depth(&1, by_id, 0)})
      |> Enum.sort_by(fn {page, depth} -> {depth, page.id} end)
      |> Enum.reduce({[], taken, %{}}, fn {page, _depth}, {acc, taken, dirs} ->
        case base_dir(page, by_id, dirs, folder_dirs, roots) do
          nil ->
            {acc, taken, dirs}

          dir ->
            children? = MapSet.member?(parents, page.id)
            {stem, path} = name(page, dir, children?, taken, own_pages)

            dirs = if children?, do: Map.put(dirs, page.id, join(dir, stem)), else: dirs

            taken =
              taken
              |> Map.put(String.downcase(path), page.id)
              |> Map.put(String.downcase(join(dir, stem)), page.id)

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

    files = place_files(board_ids, folder_dirs, roots, taken)

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
      boards: roots,
      folder_boards: found.folder_boards,
      virtual: found.virtual_details
    }
  end

  # A vault's other files (W-103 R2.9): each in its folder's directory, or
  # at its board's root, under its own name, numbered when something
  # placed earlier has that name already.
  defp place_files(board_ids, folder_dirs, roots, taken) do
    from(f in Slipdock.Wiki.WikiFile,
      where: f.board_id in ^board_ids and is_nil(f.archived_at),
      order_by: [asc: f.id],
      select: %{id: f.id, board_id: f.board_id, folder_id: f.folder_id, name: f.name}
    )
    |> Repo.all()
    |> Enum.reduce({[], taken}, fn file, {acc, taken} ->
      dir =
        case file.folder_id do
          nil -> roots[file.board_id]
          id -> folder_dirs[id]
        end

      if is_nil(dir) do
        {acc, taken}
      else
        path = free_file_path(file.name, dir, taken)

        entry = Map.merge(file, %{path: path, dir: dir})
        {[entry | acc], Map.put(taken, String.downcase(path), {:file, file.id})}
      end
    end)
    |> elem(0)
  end

  # The first of a file's numbered names nothing in the directory has.
  defp free_file_path(name, dir, taken) do
    ext = Path.extname(name)
    base = name |> Path.basename(ext) |> DiskName.disk_name()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&join(dir, DiskName.numbered(base, &1) <> ext))
    |> Enum.find(&(not Map.has_key?(taken, String.downcase(&1))))
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
  # the top of the tree, its folder's or its board's.
  defp base_dir(page, by_id, dirs, folder_dirs, roots) do
    case page.parent_id && by_id[page.parent_id] do
      nil ->
        case page.folder_id do
          nil -> roots[page.board_id]
          folder_id -> folder_dirs[folder_id]
        end

      parent ->
        # Placed already, being shallower; nil when the parent is in no vault path.
        dirs[parent.id]
    end
  end

  @doc """
  The vault's boards in order of depth, roots first: every root board its
  owner has, archived too, then the sub-boards under them. Id, name and the
  card a sub-board belongs to.
  """
  def boards(%Vault{user_id: user_id}) do
    roots =
      from(b in Board,
        where: b.owner_id == ^user_id and is_nil(b.parent_card_id),
        order_by: [asc: b.id],
        select: %{id: b.id, name: b.name, parent_card_id: b.parent_card_id}
      )
      |> Repo.all()

    subs =
      from(b in Board,
        where: b.root_id in ^Enum.map(roots, & &1.id) and not is_nil(b.parent_card_id),
        order_by: [asc: b.id],
        select: %{id: b.id, name: b.name, parent_card_id: b.parent_card_id}
      )
      |> Repo.all()

    roots ++ subs
  end

  @doc """
  Where the vault's boards and folders are. One narrow query each, so a
  caller can ask without placing every page.
  """
  @spec dirs(Vault.t()) :: dirs
  def dirs(%Vault{} = vault) do
    boards = boards(vault)
    {roots, subs} = Enum.split_with(boards, &is_nil(&1.parent_card_id))
    board_ids = Enum.map(boards, & &1.id)

    folders =
      from(f in Folder,
        where: f.board_id in ^board_ids,
        order_by: [asc: f.id],
        select: %{
          id: f.id,
          board_id: f.board_id,
          parent_id: f.parent_id,
          name: f.name,
          card_id: f.card_id
        }
      )
      |> Repo.all()

    epics =
      from(c in Card,
        where: c.id in ^Enum.map(subs, & &1.parent_card_id),
        order_by: [asc: c.id],
        select: %{
          id: c.id,
          board_id: c.board_id,
          short_name: c.short_name,
          title: c.title,
          archived_at: c.archived_at
        }
      )
      |> Repo.all()

    world = %{
      children: Enum.group_by(folders, &{&1.board_id, &1.parent_id}),
      card_folders: for(f <- folders, f.card_id, into: %{}, do: {f.card_id, f}),
      epics: Enum.group_by(epics, & &1.board_id),
      subs: Map.new(subs, &{&1.parent_card_id, &1}),
      sources: CardFolders.sources(board_ids)
    }

    state = %{
      boards: %{},
      folders: %{},
      full_boards: %{},
      full_folders: %{},
      folder_boards: Map.new(folders, &{&1.id, &1.board_id}),
      virtual: [],
      virtual_details: %{},
      used: %{}
    }

    names = roots |> Enum.map(&{&1.id, {&1.name, "Board #{&1.id}"}}) |> DiskName.assign()

    roots
    |> Enum.reduce(state, fn board, state ->
      lay_board(board, names[board.id], [board.name], world, state)
    end)
    |> Map.drop([:used])
  end

  # A board's top level, in the directory it has been given.
  defp lay_board(board, dir, full, world, state) do
    state = %{
      state
      | boards: Map.put(state.boards, board.id, dir),
        full_boards: Map.put(state.full_boards, board.id, full)
    }

    top = Map.get(world.children, {board.id, nil}, [])
    waiting = homeless_epics(board.id, world)
    cards = Enum.find(top, &cards_folder?/1)

    items =
      Enum.map(top, &{:folder, &1}) ++
        if(waiting != [] and is_nil(cards), do: [{:cards, waiting}], else: [])

    lay(items, dir, full, Map.put(world, :cards_folder, cards && cards.id), waiting, state)
  end

  # Epics of this board whose folder nobody has made yet: they have their
  # place all the same, or their sub-boards would have none.
  defp homeless_epics(board_id, world) do
    world.epics
    |> Map.get(board_id, [])
    |> Enum.reject(&Map.has_key?(world.card_folders, &1.id))
  end

  defp cards_folder?(%{parent_id: nil, name: name}),
    do: String.downcase(name) == String.downcase(CardFolders.root_name())

  # One directory's children: named together, then each laid out in turn.
  defp lay(items, dir, full, world, waiting, state) do
    named = items |> Enum.map(&{item_key(&1), item_source(&1, world)})
    names = DiskName.assign(named, Map.get(state.used, dir, []))

    state = %{
      state
      | used: Map.update(state.used, dir, Map.values(names), &(Map.values(names) ++ &1))
    }

    Enum.reduce(items, state, fn item, state ->
      lay_item(item, join(dir, names[item_key(item)]), full, world, waiting, state)
    end)
  end

  defp item_key({:folder, folder}), do: {:folder, folder.id}
  defp item_key({:cards, _epics}), do: :cards
  defp item_key({:epic, epic}), do: {:epic, epic.id}

  defp item_source({:folder, folder}, world), do: Map.get(world.sources, folder.id, folder.name)
  defp item_source({:cards, _epics}, _world), do: CardFolders.root_name()
  defp item_source({:epic, epic}, _world), do: {epic.short_name || epic.title, "Card #{epic.id}"}

  defp lay_item({:folder, folder}, dir, full, world, waiting, state) do
    full = full ++ [folder.name]

    state = %{
      state
      | folders: Map.put(state.folders, folder.id, dir),
        full_folders: Map.put(state.full_folders, folder.id, full)
    }

    below = Map.get(world.children, {folder.board_id, folder.id}, [])
    epics = if world.cards_folder == folder.id, do: waiting, else: []
    items = Enum.map(below, &{:folder, &1}) ++ Enum.map(epics, &{:epic, &1})
    state = lay(items, dir, full, world, [], state)

    case folder.card_id && world.subs[folder.card_id] do
      nil -> state
      sub -> lay_board(sub, dir, full, world, state)
    end
  end

  defp lay_item({:cards, [first | _] = epics}, dir, full, world, _waiting, state) do
    full = full ++ [CardFolders.root_name()]
    state = virtual(state, dir, %{board_id: first.board_id, card: nil})
    lay(Enum.map(epics, &{:epic, &1}), dir, full, world, [], state)
  end

  defp lay_item({:epic, epic}, dir, full, world, _waiting, state) do
    full = full ++ [epic.title]
    state = virtual(state, dir, %{board_id: epic.board_id, card: epic})

    case world.subs[epic.id] do
      nil -> state
      sub -> lay_board(sub, dir, full, world, state)
    end
  end

  defp virtual(state, dir, details) do
    %{
      state
      | virtual: [dir | state.virtual],
        virtual_details: Map.put(state.virtual_details, dir, details)
    }
  end

  # The page's file name, numbered past everything placed before it.
  defp name(page, dir, children?, taken, own_pages) do
    base = page |> file_name(own_pages) |> DiskName.disk_name()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn n ->
      stem = DiskName.numbered(base, n)
      {stem, file_path(dir, stem, children?)}
    end)
    |> Enum.find(fn {stem, path} ->
      not Map.has_key?(taken, String.downcase(path)) and
        not Map.has_key?(taken, String.downcase(join(dir, stem)))
    end)
  end

  defp file_path(dir, stem, true), do: join(join(dir, stem), "index.md")
  defp file_path(dir, stem, false), do: join(dir, stem <> ".md")

  # The name the page's own file had, kept; otherwise what its card calls
  # it, if it is the card's write-up; otherwise its title.
  defp file_name(%{file_name: name}, _own_pages) when is_binary(name) and name != "", do: name
  defp file_name(page, own_pages), do: CardFolders.own_page_name(page, own_pages) || page.title

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
    * `{:folder, %{board_id:, folder_id:}, segments}` — in the deepest folder
      already at that path (`folder_id` nil for a board's root), then the
      folders named by `segments` below it (made as needed);
    * `{:error, reason}` — in no board, or a folder inside a page.
  """
  def place(layout, path) do
    place_dir(layout, path |> Path.dirname() |> then(&if(&1 == ".", do: "", else: &1)))
  end

  @doc "`place/2` for a directory rather than a file in it."
  def place_dir(layout, dir) do
    key = String.downcase(dir)

    cond do
      id = layout.page_dirs[key] ->
        {:parent, id}

      Enum.any?(Map.keys(layout.page_dirs), &String.starts_with?(key, &1 <> "/")) ->
        {:error, "#{dir} is inside a page, and a page holds pages, not folders"}

      dir == "" ->
        {:error, "the vault's root holds boards: put it in a board's folder"}

      true ->
        deepest(layout, String.split(dir, "/", trim: true))
    end
  end

  # A folder's disk name can be shortened or numbered, so the path is matched
  # against where things are rather than by their names: a folder first, as
  # an epic's folder and its sub-board share a directory.
  defp deepest(layout, segments) do
    boards = Map.new(layout.boards, fn {id, dir} -> {String.downcase(dir), id} end)

    length(segments)..1//-1
    |> Enum.find_value(fn n ->
      key = segments |> Enum.take(n) |> Enum.join("/") |> String.downcase()
      rest = Enum.drop(segments, n)

      cond do
        id = layout.folder_dirs[key] ->
          {:folder, %{board_id: layout.folder_boards[id], folder_id: id}, rest}

        id = boards[key] ->
          {:folder, %{board_id: id, folder_id: nil}, rest}

        true ->
          nil
      end
    end)
    |> case do
      nil -> {:error, "no board in the vault is called #{hd(segments)}"}
      found -> found
    end
  end
end
