defmodule Slipdock.Wiki.FolderMove do
  @moduledoc """
  Moving a folder, with everything under it, to another board (#745).

  What moves:

    * the folder and every folder beneath it, keeping their names and order
      under the target parent — or, with `contents: true`, only what is *in*
      the folder, landing straight in the target parent, and the emptied
      folder is deleted (how a folder is given a board of its own, where its
      notes should sit at the top);
    * every page at home in any of those folders, and the pages under those
      pages wherever they are filed, keeping their codes, history, comments,
      checklists, attachments and links exactly as a single page move does
      (`Slipdock.Wiki.Move`): tags and field values carry by name, pins while
      the card is on the target's tree, an assignee who can open it;
    * the wiki files (synced images, PDFs) kept in those folders.

  What stays:

    * a page filed in one of the folders under a parent page that is *not*
      moving stays with its parent, taken out of the folder;
    * filing in other folders (W-103 R12), of pages and of folders (#808),
      survives when both ends are on the target board or in one vault with
      it, and is taken away otherwise — the report names the folder
      placements that went.

  Refused, with nothing changed: the target is the folder's own board, the
  user can't write to both, the target parent is not on the target, a moving
  folder is a vault mapping's target (take that mapping out first), or a
  folder of the same name already sits where one would land.

  `preview/4` reports all of that; `to_board/4` does it in one transaction,
  and records a change for every page, folder and file on both boards, so a
  synced vault sees each as the same thing at a new path — or at the same
  path, when the vault's mappings put it there.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Vaults, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Vaults.Mapping
  alias Slipdock.Wiki.{Changes, Folder, Move, Page, Placement, WikiFile}

  @doc """
  What moving `folder` to `target` would do, for `user`:

      %{folders: 3, pages: 201, files: 4,
        per_folder: [%{path: "Projects", pages: 180}, %{path: "Projects/Acme", pages: 21}],
        tags:, fields:, pins:  (carried / dropped names, as a page move reports),
        assignees: %{carried: [...], dropped: [...]},
        left_behind: ["Child filed here under a page that stays"],
        filing_dropped: 2, title_clashes: ["Readme"], into: "Project Work"}

  `opts`: `parent` (a folder on `target`, default its top) and `contents`.
  """
  def preview(%Folder{} = folder, %Board{} = target, %User{} = user, opts \\ []) do
    with {:ok, plan} <- plan(folder, target, user, opts), do: {:ok, report(plan)}
  end

  @doc """
  Moves `folder` (or, with `contents: true`, what is in it) to `target`, as
  `preview/4` describes. `{:ok, %{folder: moved_or_nil, report: report}}`.
  """
  def to_board(%Folder{} = folder, %Board{} = target, %User{} = user, opts \\ []) do
    with {:ok, plan} <- plan(folder, target, user, opts) do
      report = report(plan)

      # All of it or none of it: a failure part-way rolls every row back.
      Repo.transaction(fn ->
        try do
          apply_plan(plan)
        rescue
          error -> Repo.rollback(Exception.message(error))
        end
      end)
      |> case do
        {:ok, moved} ->
          after_move(plan)
          {:ok, %{folder: moved, report: report}}

        {:error, reason} ->
          {:error, :unprocessable_entity, "nothing moved: #{reason}"}
      end
    end
  end

  ## Planning -------------------------------------------------------------------

  defp plan(folder, target, user, opts) do
    parent = opts[:parent]
    contents? = opts[:contents] == true
    source = Repo.get!(Board, folder.board_id)

    # Somebody it was only shared with never takes it to another board (#816).
    with :ok <- Slipdock.Wiki.Sharing.check(user, {:move, {:board, target.id}}, folder),
         :ok <- check_boards(source, target, user),
         :ok <- check_parent(parent, target),
         subtree = [folder | Wiki.Folders.descendants(folder)],
         subtree_ids = Enum.map(subtree, & &1.id),
         :ok <- check_mapped(subtree_ids),
         # The folders that move as folders: all of them, or all but the one
         # emptied into the target parent.
         moving_folders = if(contents?, do: tl(subtree), else: subtree),
         landing = if(contents?, do: children(folder, subtree), else: [folder]),
         moving_folder_ids = Enum.map(moving_folders, & &1.id),
         :ok <- check_names(landing, target, parent) do
      pages = from(p in Page, where: p.board_id == ^source.id) |> Repo.all()
      by_id = Map.new(pages, &{&1.id, &1})
      in_subtree = MapSet.new(subtree_ids)

      tops =
        Enum.filter(pages, &(is_nil(&1.parent_id) and MapSet.member?(in_subtree, &1.folder_id)))

      moving = tops ++ Enum.flat_map(tops, &Wiki.descendants/1)
      moving_ids = MapSet.new(moving, & &1.id)

      left_behind =
        Enum.filter(pages, fn p ->
          MapSet.member?(in_subtree, p.folder_id) and not MapSet.member?(moving_ids, p.id)
        end)

      files =
        from(f in WikiFile, where: f.board_id == ^source.id and f.folder_id in ^subtree_ids)
        |> Repo.all()

      {:ok,
       %{
         folder: folder,
         source: source,
         target: target,
         parent: parent,
         contents?: contents?,
         subtree: subtree,
         subtree_ids: subtree_ids,
         moving_folders: moving_folders,
         landing: landing,
         moving: moving,
         by_id: by_id,
         left_behind: left_behind,
         files: files,
         filing: filing_plan(moving, subtree_ids, target),
         folder_filing: Wiki.FolderPlacements.stranded_by_move(moving_folder_ids, target.id),
         user: user,
         via: opts[:via]
       }}
    end
  end

  defp children(folder, subtree), do: Enum.filter(subtree, &(&1.parent_id == folder.id))

  defp check_boards(%Board{id: id}, %Board{id: id}, _user),
    do:
      {:error, :unprocessable_entity,
       "the folder is on that board already: move it within the board instead"}

  defp check_boards(source, target, user) do
    cond do
      not is_nil(target.archived_at) ->
        {:error, :unprocessable_entity, "#{target.name} is archived"}

      not (writer?(user, source) and writer?(user, target)) ->
        {:error, :forbidden, "you need to be able to edit both boards"}

      true ->
        :ok
    end
  end

  defp check_parent(nil, _target), do: :ok
  defp check_parent(%Folder{board_id: id}, %Board{id: id}), do: :ok

  defp check_parent(_parent, target),
    do: {:error, :unprocessable_entity, "that folder is not on #{target.name}"}

  # A folder a vault maps onto belongs to that mapping's board; moving it
  # would leave the mapping pointing across boards.
  defp check_mapped(ids) do
    case Repo.one(
           from(m in Mapping,
             join: f in Folder,
             on: f.id == m.folder_id,
             where: m.folder_id in ^ids,
             select: {f.name, m.path},
             limit: 1
           )
         ) do
      nil ->
        :ok

      {name, path} ->
        {:error, :unprocessable_entity,
         "#{name} is mapped into a vault at #{Mapping.display_path(path)}: take that mapping out first"}
    end
  end

  # A folder of the same name (case aside) already where one would land.
  defp check_names(landing, target, parent) do
    parent_id = parent && parent.id

    there =
      from(f in Folder, where: f.board_id == ^target.id, select: {f.parent_id, f.name})
      |> Repo.all()
      |> Enum.filter(fn {p, _name} -> p == parent_id end)
      |> MapSet.new(fn {_p, name} -> String.downcase(name) end)

    case Enum.filter(landing, &MapSet.member?(there, String.downcase(&1.name))) do
      [] ->
        :ok

      clashes ->
        names = Enum.map_join(clashes, ", ", & &1.name)
        where = if parent, do: "in #{Wiki.folder_path(parent)}", else: "at its top"

        {:error, :unprocessable_entity,
         "#{target.name} already has a folder named #{names} #{where}: " <>
           "rename one, or pick another parent"}
    end
  end

  # Other filing that touches the move: the moving pages' filing elsewhere,
  # and other pages' filing in the moving folders. Kept when both ends end up
  # on one board or in one vault; otherwise taken away.
  defp filing_plan(moving, subtree_ids, target) do
    moving_ids = Enum.map(moving, & &1.id)
    target_vault = vault_id(target.id)

    rows =
      from(pl in Placement,
        join: f in Folder,
        on: f.id == pl.folder_id,
        join: p in Page,
        on: p.id == pl.page_id,
        where: pl.page_id in ^moving_ids or pl.folder_id in ^subtree_ids,
        select: {pl.id, pl.page_id, pl.folder_id, f.board_id, p.board_id}
      )
      |> Repo.all()

    moving_set = MapSet.new(moving_ids)
    subtree_set = MapSet.new(subtree_ids)

    Enum.filter(rows, fn {_id, page_id, folder_id, folder_board, page_board} ->
      page_board = if MapSet.member?(moving_set, page_id), do: target.id, else: page_board
      folder_board = if MapSet.member?(subtree_set, folder_id), do: target.id, else: folder_board

      not (page_board == folder_board or
             (not is_nil(target_vault) and vault_id(page_board) == target_vault and
                vault_id(folder_board) == target_vault))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp vault_id(board_id) do
    case Vaults.for_board(board_id) do
      nil -> nil
      vault -> vault.id
    end
  end

  defp writer?(user, board), do: Access.can_write?(Access.board_permission(user, board))

  ## Reporting ------------------------------------------------------------------

  defp report(plan) do
    ids = Enum.map(plan.moving, & &1.id)
    {tags, _} = Move.tag_plan(ids, plan.target)
    {fields, _} = Move.field_plan(ids, plan.target)
    pins = Move.pin_plan(ids, plan.target)
    paths = folder_paths(plan.subtree, plan.folder)

    tops =
      plan.moving
      |> Enum.group_by(&top_folder(&1, plan.by_id))
      |> Map.new(fn {folder_id, pages} -> {folder_id, length(pages)} end)

    %{
      into: plan.target.name,
      folders: length(plan.moving_folders),
      pages: length(plan.moving),
      files: length(plan.files),
      per_folder: Enum.map(plan.subtree, &%{path: paths[&1.id], pages: Map.get(tops, &1.id, 0)}),
      tags: tags,
      fields: fields,
      pins: Map.take(pins, [:carried, :dropped]),
      assignees: assignees(plan.moving, plan.target),
      left_behind: Enum.map(plan.left_behind, & &1.title),
      filing_dropped: length(plan.filing),
      # Folders filed elsewhere (#808) that can't stay filed across the move.
      folder_filing_dropped: Enum.map(plan.folder_filing, &Map.take(&1, [:folder, :in])),
      title_clashes: title_clashes(plan)
    }
  end

  # Folder paths as the report names them: from the moving folder down.
  defp folder_paths(subtree, root) do
    Enum.reduce(subtree, %{}, fn f, acc ->
      path = if f.id == root.id, do: f.name, else: acc[f.parent_id] <> "/" <> f.name
      Map.put(acc, f.id, path)
    end)
  end

  defp top_folder(%Page{parent_id: nil} = page, _by_id), do: page.folder_id

  defp top_folder(page, by_id) do
    case by_id[page.parent_id] do
      nil -> page.folder_id
      parent -> top_folder(parent, by_id)
    end
  end

  defp assignees(pages, target) do
    pages
    |> Enum.map(& &1.assignee_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&{Repo.get(User, &1), Move.reader?(&1, target)})
    |> Enum.reject(fn {user, _} -> is_nil(user) end)
    |> Enum.split_with(fn {_user, ok} -> ok end)
    |> then(fn {kept, dropped} ->
      %{
        carried: Enum.map(kept, fn {u, _} -> User.display_name(u) end) |> Enum.sort(),
        dropped: Enum.map(dropped, fn {u, _} -> User.display_name(u) end) |> Enum.sort()
      }
    end)
  end

  # Live pages landing in the target parent beside one of the same title.
  defp title_clashes(plan) do
    landing_folder = if plan.contents?, do: plan.folder.id, else: nil
    parent_id = plan.parent && plan.parent.id

    arriving =
      if plan.contents? do
        plan.moving
        |> Enum.filter(&(is_nil(&1.parent_id) and &1.folder_id == landing_folder))
        |> MapSet.new(&String.downcase(&1.title))
      else
        MapSet.new()
      end

    from(p in Page,
      where: p.board_id == ^plan.target.id and is_nil(p.parent_id) and is_nil(p.archived_at),
      select: {p.folder_id, p.title}
    )
    |> Repo.all()
    |> Enum.filter(fn {folder_id, title} ->
      folder_id == parent_id and MapSet.member?(arriving, String.downcase(title))
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
  end

  ## Doing it -------------------------------------------------------------------

  defp apply_plan(plan) do
    %{target: target, folder: folder} = plan
    parent_id = plan.parent && plan.parent.id
    moving_folder_ids = Enum.map(plan.moving_folders, & &1.id)
    landing_ids = MapSet.new(plan.landing, & &1.id)

    # Folders: onto the target, with a slug free there, the ones that land
    # in the target parent placed after what is already there.
    next = next_position(target.id, parent_id)

    plan.moving_folders
    |> Enum.reduce(next, fn f, position ->
      lands? = MapSet.member?(landing_ids, f.id)

      changes =
        [board_id: target.id, slug: free_folder_slug(f, target)] ++
          if(lands?, do: [parent_id: parent_id, position: position], else: [])

      f |> Ecto.Changeset.change(changes) |> Repo.update!()
      if lands?, do: position + 1, else: position
    end)

    # Pages: each keeps its folder when that folder moves; one at home in
    # the emptied folder lands in the target parent; a page under a moving
    # page that was filed somewhere staying behind is filed nowhere, and sits
    # with its parent as it always did.
    moving_folder_set = MapSet.new(moving_folder_ids)

    Enum.each(plan.moving, fn page ->
      folder_id =
        cond do
          MapSet.member?(moving_folder_set, page.folder_id) -> page.folder_id
          plan.contents? and page.folder_id == folder.id -> parent_id
          is_nil(page.parent_id) -> parent_id
          true -> nil
        end

      page
      |> Ecto.Changeset.change(
        board_id: target.id,
        slug: Move.free_slug(page, target),
        folder_id: folder_id,
        column_id: nil,
        board_position: 0,
        assignee_id: if(Move.reader?(page.assignee_id, target), do: page.assignee_id)
      )
      |> Repo.update!()
    end)

    ids = Enum.map(plan.moving, & &1.id)
    {_report, tag_map} = Move.tag_plan(ids, target)
    Move.retag(ids, tag_map)
    {_report, field_map} = Move.field_plan(ids, target)
    Move.refield(ids, field_map)
    Move.unpin(Move.pin_plan(ids, target).unpin)

    left_ids = Enum.map(plan.left_behind, & &1.id)

    if left_ids != [],
      do: Repo.update_all(from(p in Page, where: p.id in ^left_ids), set: [folder_id: nil])

    if plan.filing != [], do: Repo.delete_all(from(pl in Placement, where: pl.id in ^plan.filing))
    Wiki.FolderPlacements.delete_ids(Enum.map(plan.folder_filing, & &1.id))

    # Files: with their folder, or into the target parent from the emptied one.
    Enum.each(plan.files, fn file ->
      folder_id =
        if plan.contents? and file.folder_id == folder.id, do: parent_id, else: file.folder_id

      file |> Ecto.Changeset.change(board_id: target.id, folder_id: folder_id) |> Repo.update!()
    end)

    # A folder that lands in a parent it was also filed in is at home there.
    for f <- plan.landing, do: Wiki.FolderPlacements.drop_home(Repo.get!(Folder, f.id))

    if plan.contents? do
      # Filing other pages had in the emptied folder can't follow it anywhere.
      Repo.delete_all(from(pl in Placement, where: pl.folder_id == ^folder.id))
      Repo.delete!(folder)
      nil
    else
      Repo.get!(Folder, folder.id)
    end
  end

  defp next_position(board_id, parent_id) do
    query = from(f in Folder, where: f.board_id == ^board_id, select: max(f.position))

    query =
      if parent_id,
        do: where(query, [f], f.parent_id == ^parent_id),
        else: where(query, [f], is_nil(f.parent_id))

    (Repo.one(query) || -1) + 1
  end

  # Folder slugs are unique per board: a taken one gets a number, as a new
  # folder's would.
  defp free_folder_slug(%Folder{} = folder, target) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> folder.slug
      n -> "#{folder.slug}-#{n}"
    end)
    |> Enum.find(fn slug ->
      not Repo.exists?(from(f in Folder, where: f.board_id == ^target.id and f.slug == ^slug))
    end)
  end

  defp after_move(plan) do
    boards = [plan.source.id, plan.target.id]

    for page <- plan.moving, board <- boards, do: Changes.record(board, "page", page.id)
    for page <- plan.left_behind, do: Changes.record(plan.source.id, "page", page.id)
    for f <- plan.moving_folders, board <- boards, do: Changes.record(board, "folder", f.id)
    for file <- plan.files, board <- boards, do: Changes.record(board, "file", file.id)

    if plan.contents?,
      do: Changes.record(plan.source.id, "folder", plan.folder.id, "deleted")

    Wiki.broadcast_board(plan.source.id)
    Wiki.broadcast_board(plan.target.id)

    what =
      if plan.contents?,
        do: "the contents of “#{plan.folder.name}”",
        else: "the folder “#{plan.folder.name}”"

    Repo.insert(%Slipdock.Boards.Activity{
      board_id: plan.target.id,
      kind: "folder_moved",
      message: "moved #{what} here from #{plan.source.name} (#{length(plan.moving)} pages)"
    })
  end
end
