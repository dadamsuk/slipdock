defmodule Slipdock.Wiki.Folders do
  @moduledoc """
  Folders on a board's wiki: making them, naming them, nesting them to any
  depth, and filing pages in them.

  The rule that runs through this module is that **filing never destroys
  writing**. Deleting a folder moves its subfolders up to its parent and its
  pages to the board root; moving a folder cannot be made to contain itself;
  and a page with no folder is not a page in limbo, it is a page at the root,
  which is where every page starts.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Folder, Page}

  ## Reading ------------------------------------------------------------------

  @doc "Every folder on a board, in tree-reading order (position, then name)."
  def list(%Board{id: board_id}), do: list(board_id)

  def list(board_id) when is_integer(board_id) do
    Repo.all(
      from(f in Folder,
        where: f.board_id == ^board_id,
        order_by: [asc: f.position, asc: f.name]
      )
    )
  end

  @doc """
  The board's folders as a tree, with the pages filed in each.

  `pages` is the list of pages to file — whatever the caller has already
  narrowed down, so the wiki's filters and the "show archived" toggle reach
  folders without this module knowing about either. Each node is

      %{folder: folder, children: [node], pages: [%{page:, children:}]}

  and `root/2` gives the pages filed nowhere.
  """
  def tree(%Board{} = board, pages) when is_list(pages), do: tree_from(list(board), pages)

  def tree_from(folders, pages) do
    by_parent = Enum.group_by(folders, & &1.parent_id)
    build(by_parent, pages, nil)
  end

  defp build(by_parent, pages, parent_id) do
    by_parent
    |> Map.get(parent_id, [])
    |> Enum.map(fn folder ->
      %{
        folder: folder,
        children: build(by_parent, pages, folder.id),
        pages: Slipdock.Wiki.tree_from(Enum.filter(pages, &(&1.folder_id == folder.id)))
      }
    end)
  end

  @doc "The pages filed in no folder — the wiki's root, as a page tree."
  def root(pages) when is_list(pages),
    do: Slipdock.Wiki.tree_from(Enum.filter(pages, &is_nil(&1.folder_id)))

  @doc "How many pages a folder holds, itself and below."
  def page_count(node) do
    length(flatten_pages(node.pages)) + Enum.sum(Enum.map(node.children, &page_count/1))
  end

  defp flatten_pages(nodes),
    do: Enum.flat_map(nodes, fn %{page: page, children: kids} -> [page | flatten_pages(kids)] end)

  @doc """
  Every folder on a board flattened back into reading order, each with the
  path it is addressed by and how deep it sits:

      [%{folder: folder, path: "Design/Decisions", depth: 1}, ...]

  One pass over a list already in memory, which is the point: a picker that
  lists forty folders should not ask the database forty times what each one
  is called (compare `path/1`, which walks the parents it is given).
  """
  def outline(folders) when is_list(folders), do: folders |> tree_from([]) |> walk(nil, 0)

  defp walk(nodes, prefix, depth) do
    Enum.flat_map(nodes, fn %{folder: folder, children: children} ->
      path = if prefix, do: prefix <> "/" <> folder.name, else: folder.name
      [%{folder: folder, path: path, depth: depth} | walk(children, path, depth + 1)]
    end)
  end

  @doc """
  What deleting a folder *with* its contents would take with it:
  `%{folders: n, pages: n}`, counting itself out and every depth in.

  Archived pages count: they are still pages, and somebody about to purge a
  folder is owed the true number rather than the visible one.
  """
  def contents_count(%Folder{} = folder) do
    ids = [folder.id | Enum.map(descendants(folder), & &1.id)]

    %{
      folders: length(ids) - 1,
      pages: Repo.aggregate(from(p in Page, where: p.folder_id in ^ids), :count)
    }
  end

  def get(nil), do: nil
  def get(id), do: Repo.get(Folder, id)
  def get!(id), do: Repo.get!(Folder, id)

  @doc """
  Finds a folder on a board by id, slug, name (case-insensitively), or a
  path of names — `"Design/Decisions"` — so a person and an agent can both
  write what they would say.

  An id sent as a string counts as an id: it is what a select in a form and a
  `phx-value` send, and a folder named "12" is not worth the ambiguity.
  """
  def find(%Board{} = board, ref) when is_integer(ref) do
    case Repo.get_by(Folder, id: ref, board_id: board.id) do
      nil -> {:error, :not_found, "folder #{ref}"}
      folder -> {:ok, folder}
    end
  end

  def find(%Board{} = board, ref) when is_binary(ref) do
    ref = String.trim(ref)

    cond do
      ref == "" ->
        {:error, :not_found, "folder \"\""}

      String.contains?(ref, "/") ->
        follow_path(board, String.split(ref, "/", trim: true))

      match?({_, ""}, Integer.parse(ref)) ->
        find(board, ref |> Integer.parse() |> elem(0))

      true ->
        case by_name_or_slug(board, nil, ref) || by_name_or_slug(board, :anywhere, ref) do
          nil -> {:error, :not_found, "folder #{inspect(ref)}"}
          folder -> {:ok, folder}
        end
    end
  end

  def find(_board, _ref), do: {:error, :not_found, "folder"}

  # A path names folders relative to the root, one segment per level.
  defp follow_path(board, segments) do
    Enum.reduce_while(segments, {:ok, nil}, fn segment, {:ok, parent} ->
      case by_name_or_slug(board, parent && parent.id, segment) do
        nil -> {:halt, {:error, :not_found, "folder #{inspect(segment)}"}}
        folder -> {:cont, {:ok, folder}}
      end
    end)
    |> case do
      {:ok, nil} -> {:error, :not_found, "folder"}
      other -> other
    end
  end

  # `:anywhere` ignores the parent, which is what a bare name means: slugs
  # are unique per board, so one name can only mean one folder.
  defp by_name_or_slug(board, scope, ref) do
    query =
      from(f in Folder,
        where: f.board_id == ^board.id,
        where:
          f.slug == ^Folder.sanitize_slug(ref) or fragment("lower(?) = lower(?)", f.name, ^ref),
        order_by: [asc: f.id],
        limit: 1
      )

    query
    |> then(fn q ->
      case scope do
        :anywhere -> q
        nil -> where(q, [f], is_nil(f.parent_id))
        id -> where(q, [f], f.parent_id == ^id)
      end
    end)
    |> Repo.one()
  end

  @doc "A folder's ancestors, outermost first — the breadcrumb."
  def ancestors(%Folder{parent_id: nil}), do: []

  def ancestors(%Folder{parent_id: parent_id}) do
    case Repo.get(Folder, parent_id) do
      nil -> []
      parent -> ancestors(parent) ++ [parent]
    end
  end

  @doc ~S'A folder written the way it is addressed: "Design/Decisions".'
  def path(%Folder{} = folder),
    do: (ancestors(folder) ++ [folder]) |> Enum.map_join("/", & &1.name)

  @doc "Every folder beneath this one, however deep."
  def descendants(%Folder{} = folder) do
    children =
      Repo.all(from(f in Folder, where: f.parent_id == ^folder.id, order_by: [asc: f.position]))

    children ++ Enum.flat_map(children, &descendants/1)
  end

  ## Writing ------------------------------------------------------------------

  @doc """
  Makes a folder on a board. `attrs` takes `name` (required), an optional
  `parent_id` and an optional `position`; the slug comes off the name.

  A name given as a path — `"Design/Decisions"` — makes every folder along
  it that does not exist yet, which is what somebody typing a path means.
  """
  def create(%Board{} = board, attrs) do
    attrs = stringify(attrs)

    case String.split(to_string(attrs["name"] || ""), "/", trim: true) do
      [] ->
        {:error, Folder.changeset(%Folder{board_id: board.id}, attrs)}

      [_single] ->
        insert(board, attrs)

      segments ->
        Enum.reduce_while(segments, {:ok, parent_of(attrs)}, fn segment, {:ok, parent_id} ->
          case ensure(board, parent_id, segment) do
            {:ok, folder} -> {:cont, {:ok, folder.id}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, id} -> {:ok, get!(id)}
          error -> error
        end
    end
  end

  defp parent_of(%{"parent_id" => id}) when is_integer(id), do: id

  defp parent_of(%{"parent_id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parent_of(_), do: nil

  defp ensure(board, parent_id, name) do
    case by_name_or_slug(board, parent_id, name) do
      %Folder{} = folder -> {:ok, folder}
      nil -> insert(board, %{"name" => name, "parent_id" => parent_id})
    end
  end

  defp insert(board, attrs) do
    name = String.trim(to_string(attrs["name"] || ""))
    slug = attrs["slug"] || Folder.slug_from_name(name, &slug_taken?(board.id, &1))

    result =
      %Folder{board_id: board.id, position: attrs["position"] || next_position(board, attrs)}
      |> Folder.changeset(attrs |> Map.put("name", name) |> Map.put("slug", slug))
      |> Repo.insert()

    with {:ok, folder} <- result do
      broadcast(board.id)
      {:ok, folder}
    end
  end

  defp slug_taken?(board_id, slug),
    do: Repo.exists?(from(f in Folder, where: f.board_id == ^board_id and f.slug == ^slug))

  defp next_position(board, attrs) do
    parent_id = parent_of(attrs)

    from(f in Folder, where: f.board_id == ^board.id, select: max(f.position))
    |> then(fn q ->
      if parent_id,
        do: where(q, [f], f.parent_id == ^parent_id),
        else: where(q, [f], is_nil(f.parent_id))
    end)
    |> Repo.one()
    |> case do
      nil -> 0
      n -> n + 1
    end
  end

  @doc """
  Renames a folder, moves it under another, or reorders it.

  `attrs` takes `name`, `parent_id` and `position`. A move that would put a
  folder inside itself is refused rather than quietly dropped.
  """
  def update(%Folder{} = folder, attrs) do
    attrs = stringify(attrs)

    with :ok <- check_cycle(folder, attrs) do
      attrs =
        if attrs["name"] && Folder.sanitize_slug(attrs["name"]) != folder.slug do
          Map.put_new_lazy(attrs, "slug", fn ->
            Folder.slug_from_name(
              attrs["name"],
              &(&1 != folder.slug and slug_taken?(folder.board_id, &1))
            )
          end)
        else
          attrs
        end

      with {:ok, folder} <- folder |> Folder.changeset(attrs) |> Repo.update() do
        # A position asked for by name — over the API or from the CLI — is
        # packed the same way a dragged one is, so the two never disagree.
        if attrs["position"], do: repack(folder, {:index, folder.position})
        broadcast(folder.board_id)
        {:ok, get!(folder.id)}
      end
    end
  end

  defp check_cycle(folder, %{"parent_id" => parent_id}) when not is_nil(parent_id) do
    parent_id =
      if is_binary(parent_id), do: parent_of(%{"parent_id" => parent_id}), else: parent_id

    cond do
      is_nil(parent_id) ->
        :ok

      parent_id == folder.id ->
        {:error, :unprocessable_entity, "a folder cannot hold itself"}

      parent_id in Enum.map(descendants(folder), & &1.id) ->
        {:error, :unprocessable_entity, "a folder cannot be moved inside itself"}

      true ->
        :ok
    end
  end

  defp check_cycle(_folder, _attrs), do: :ok

  @doc """
  Moves a folder under `parent` — a folder, an id, or nil for the top — and
  puts it just before `before` among its new siblings, or last with `nil`.

  Positions are packed 0, 1, 2… across the whole new sibling list afterwards,
  so an order dragged into place is the order that comes back, and a folder
  made later never has to out-number one made before it.
  """
  def move(%Folder{} = folder, parent, before \\ nil) do
    parent_id =
      case parent do
        %Folder{id: id} -> id
        id when is_integer(id) -> id
        id when is_binary(id) -> parent_of(%{"parent_id" => id})
        _ -> nil
      end

    with :ok <- check_cycle(folder, %{"parent_id" => parent_id}),
         {:ok, moved} <- folder |> Folder.changeset(%{"parent_id" => parent_id}) |> Repo.update() do
      repack(moved, {:before, before})
      broadcast(moved.board_id)
      {:ok, get!(moved.id)}
    end
  end

  # Where the folder goes among its siblings: above a named one, or at an
  # index. Either way every sibling is renumbered 0, 1, 2… afterwards, so
  # "position 1" means second whatever the numbers happened to be before.
  defp repack(%Folder{} = folder, placement) do
    siblings =
      from(f in Folder,
        where: f.board_id == ^folder.board_id,
        where: ^parent_clause(folder.parent_id),
        where: f.id != ^folder.id,
        order_by: [asc: f.position, asc: f.name],
        select: f.id
      )
      |> Repo.all()

    index =
      case placement do
        {:before, nil} ->
          length(siblings)

        {:before, id} ->
          Enum.find_index(siblings, &(&1 == id)) || length(siblings)

        {:index, n} ->
          n |> max(0) |> min(length(siblings))
      end

    {above, below} = Enum.split(siblings, index)

    (above ++ [folder.id] ++ below)
    |> Enum.with_index()
    |> Enum.each(fn {id, position} ->
      Repo.update_all(from(f in Folder, where: f.id == ^id), set: [position: position])
    end)
  end

  defp parent_clause(nil), do: dynamic([f], is_nil(f.parent_id))
  defp parent_clause(id), do: dynamic([f], f.parent_id == ^id)

  @doc """
  Deletes a folder. How much goes with it is the caller's choice, and the
  default is the cautious one:

    * `:keep` (the default) deletes the folder only — its subfolders move up
      to its parent, and its pages go back to the board root. Nothing written
      is lost, which is the rule this module is built on.
    * `:purge` deletes the folders beneath it and every page filed in any of
      them, history and all. This is the owner's "and all of it", so it goes
      through `Slipdock.Wiki.delete_page/1` page by page: each one leaves the
      search index and the board's activity log properly behind it.

  `:purge` leaves a purged page's child pages behind at the top of the tree
  rather than deleting them unasked, exactly as deleting one page does.
  """
  def delete(folder, strategy \\ :keep)

  def delete(%Folder{} = folder, :purge) do
    ids = [folder.id | Enum.map(descendants(folder), & &1.id)]

    from(p in Page, where: p.folder_id in ^ids)
    |> Repo.all()
    |> Enum.each(&Slipdock.Wiki.delete_page/1)

    Repo.delete_all(from(f in Folder, where: f.id in ^ids))
    broadcast(folder.board_id)
    {:ok, folder}
  end

  def delete(%Folder{} = folder, :keep) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(f in Folder, where: f.parent_id == ^folder.id),
        set: [parent_id: folder.parent_id]
      )

      Repo.update_all(from(p in Page, where: p.folder_id == ^folder.id), set: [folder_id: nil])
      Repo.delete!(folder)
    end)
    |> case do
      {:ok, folder} ->
        broadcast(folder.board_id)
        {:ok, folder}

      other ->
        other
    end
  end

  @doc """
  Files a page in a folder, or takes it out of one with `nil`.

  A page is filed where it is filed whatever else is true of it: it keeps its
  parent page, its place in a list on the board, and its history.
  """
  def put_page(%Page{} = page, folder) do
    folder_id =
      case folder do
        %Folder{id: id} -> id
        id when is_integer(id) -> id
        _ -> nil
      end

    with {:ok, page} <-
           page |> Ecto.Changeset.change(folder_id: folder_id) |> Repo.update() do
      broadcast(page.board_id)
      {:ok, page}
    end
  end

  defp broadcast(board_id), do: Slipdock.Wiki.broadcast_board(board_id)

  defp stringify(attrs) when is_map(attrs),
    do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
