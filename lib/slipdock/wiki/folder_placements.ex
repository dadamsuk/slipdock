defmodule Slipdock.Wiki.FolderPlacements do
  @moduledoc """
  Filing a folder in several folders (#808), as `Slipdock.Wiki.Placements`
  files a page in several.

  A folder has exactly one **home** — `parent_id`, as it always had — and any
  number of folders it is **also filed in**. They are placements, like
  symbolic links: every one shows the same folder with its whole subtree,
  pages, files, drawings and subfolders. On disk (when the vault is synced)
  the folder is written once, at its home.

  The rules, the pages' own:

    * A placement is in a folder on the folder's own board, or — when that
      board is in a vault — on any board of the same vault.
    * Placing needs write on both boards: it changes what the target holds.
    * The home parent is not a placement. Filing a folder where it is at
      home is refused, and moving it home to where it was also filed drops
      the placement, so a listing shows it once.
    * No cycles: a folder is never placed inside its own subtree, whether
      the way down runs through home parents or through other placements.
    * Taking a placement away never touches the folder. Deleting either
      folder takes its placements (by cascade).
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Vaults, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Changes, Folder, FolderPlacement}

  @doc "The folders `folder` is also filed in, with their boards, in the order they were added."
  def folders(%Folder{id: id}), do: Map.get(by_folder([id]), id, [])

  @doc "`folders/1` for many folders at once: folder id → the folders it is also filed in."
  def by_folder([]), do: %{}

  def by_folder(ids) when is_list(ids) do
    from(pl in FolderPlacement,
      join: f in assoc(pl, :in_folder),
      where: pl.folder_id in ^ids,
      order_by: [asc: pl.inserted_at, asc: pl.id],
      select: {pl.folder_id, f}
    )
    |> Repo.all()
    |> then(fn rows ->
      boards = rows |> Enum.map(&elem(&1, 1)) |> Repo.preload(:board)
      Enum.zip_with(rows, boards, fn {id, _}, f -> {id, f} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Files `folder` in `target` as well as its home. `user` needs write on
  both boards. Filing it twice in one place is filing it once.
  """
  def add(%Folder{} = folder, %Folder{} = target, %User{} = user) do
    cond do
      target.id == folder.id ->
        {:error, :unprocessable_entity, "a folder cannot be filed inside itself"}

      target.id == folder.parent_id ->
        {:error, :unprocessable_entity, "that is the folder's home already"}

      # A folder shared with `user`, filed in a folder of their own (#818):
      # reading it through the share is enough, if they write where it goes.
      Slipdock.Wiki.SharedPlacements.cross_owner?(folder.board_id, target.board_id) and
        Access.can_read?(Access.share_permission(user, folder)) and
          writer?(user, target.board_id) ->
        insert(folder, target)

      Slipdock.Wiki.SharedPlacements.cross_owner?(folder.board_id, target.board_id) and
          Access.can_read?(Access.share_permission(user, folder)) ->
        {:error, :forbidden, "you can only file it in a folder you can edit"}

      not reachable?(folder, target) ->
        {:error, :unprocessable_entity,
         "a folder can only be filed in folders on its own board, or on boards in the same vault"}

      not writer?(user, folder.board_id) or not writer?(user, target.board_id) ->
        {:error, :forbidden,
         "you need to be able to edit both the folder's board and the one it is filed in"}

      target.id in below_ids(folder) ->
        how =
          if target.id in Enum.map(Wiki.Folders.descendants(folder), & &1.id),
            do: "it is inside “#{folder.name}”",
            else: "it is inside “#{folder.name}” through another placement"

        {:error, :unprocessable_entity,
         "“#{folder.name}” cannot be filed in #{Wiki.folder_path(target)}: #{how}"}

      true ->
        insert(folder, target)
    end
  end

  defp insert(folder, target) do
    position =
      Repo.one(
        from(pl in FolderPlacement,
          where: pl.in_folder_id == ^target.id,
          select: max(pl.position)
        )
      )

    %FolderPlacement{}
    |> FolderPlacement.changeset(%{
      folder_id: folder.id,
      in_folder_id: target.id,
      position: (position || -1) + 1
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:folder_id, :in_folder_id])
    |> case do
      {:ok, _} ->
        touched(folder, target)
        {:ok, folders(folder)}

      error ->
        error
    end
  end

  @doc "Takes `folder` out of a folder it was also filed in. The folder itself is untouched."
  def remove(%Folder{} = folder, %Folder{} = target, %User{} = user) do
    if writer?(user, folder.board_id) or writer?(user, target.board_id) do
      case Repo.delete_all(
             from(pl in FolderPlacement,
               where: pl.folder_id == ^folder.id and pl.in_folder_id == ^target.id
             )
           ) do
        {0, _} ->
          {:error, :not_found, "placement of “#{folder.name}” in #{Wiki.folder_path(target)}"}

        _ ->
          touched(folder, target)
          {:ok, folders(folder)}
      end
    else
      {:error, :forbidden, "you don't edit this folder"}
    end
  end

  @doc """
  Every folder id under `folder`, however deep, through home parents and
  through placements alike: where it may not be filed, nor moved.
  """
  def below_ids(%Folder{id: id}), do: walk([id], MapSet.new()) |> MapSet.to_list()

  defp walk([], seen), do: seen

  defp walk(frontier, seen) do
    homes = from(f in Folder, where: f.parent_id in ^frontier, select: f.id)

    placed =
      from(pl in FolderPlacement, where: pl.in_folder_id in ^frontier, select: pl.folder_id)

    next =
      (Repo.all(homes) ++ Repo.all(placed))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(seen, &1))

    walk(next, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
  end

  @doc "Drops the placement in a folder that has just become `folder`'s home."
  def drop_home(%Folder{parent_id: nil}), do: :ok

  def drop_home(%Folder{id: id, parent_id: parent_id}) do
    Repo.delete_all(
      from(pl in FolderPlacement, where: pl.folder_id == ^id and pl.in_folder_id == ^parent_id)
    )

    :ok
  end

  @doc """
  The folders also filed in `in_folder` that `reader` may open (with no
  reader, only those on its own board), in the order they were filed.
  """
  def placed_in(%Folder{id: id, board_id: board_id}, reader \\ nil) do
    Map.get(placed_by_folder([id], board_id, reader), id, [])
  end

  @doc "`placed_in/2` for many folders at once: folder id → the folders also filed in it."
  def placed_by_folder(ids, board_id, reader \\ nil)
  def placed_by_folder([], _board_id, _reader), do: %{}

  def placed_by_folder(ids, board_id, reader) do
    rows =
      from(f in Folder,
        join: pl in FolderPlacement,
        on: pl.folder_id == f.id,
        where: pl.in_folder_id in ^ids,
        order_by: [asc: pl.position, asc: fragment("lower(?)", f.name)],
        select: {pl.in_folder_id, f}
      )
      |> Repo.all()

    readable = readable_boards(rows |> Enum.map(&elem(&1, 1).board_id) |> Enum.uniq(), reader)

    rows
    |> Enum.filter(fn {_in, f} ->
      f.board_id == board_id or f.board_id in readable or shared_with?(f, reader)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  The pages anywhere under the folders also filed in `in_folder`, marked
  `also: true`, that `reader` may open (with no reader, only those on its
  own board): what a listing of `in_folder` adds for them. Archived pages
  only with `archived: true` or `:all`.
  """
  def pages_in(%Folder{board_id: board_id} = in_folder, reader \\ nil, opts \\ []) do
    ids =
      in_folder
      |> placed_in(reader)
      |> Enum.flat_map(&[&1.id | Enum.map(Wiki.Folders.descendants(&1), fn f -> f.id end)])
      |> Enum.uniq()

    from(p in Wiki.Page,
      where: p.folder_id in ^ids,
      order_by: [asc: p.position, asc: fragment("lower(?)", p.title)],
      preload: ^Wiki.board_preloads()
    )
    |> archived(Keyword.get(opts, :archived, false))
    |> Repo.all()
    |> Enum.filter(&readable_page?(&1, reader, board_id))
    |> Enum.map(&%{&1 | also: true})
  end

  defp archived(query, :all), do: query
  defp archived(query, true), do: where(query, [p], not is_nil(p.archived_at))
  defp archived(query, _), do: where(query, [p], is_nil(p.archived_at))

  defp readable_page?(page, nil, board_id), do: page.board_id == board_id

  defp readable_page?(page, reader, _board_id),
    do: Wiki.visible?(page, Access.page_permission(reader, page))

  # A folder shared with the reader shows wherever they filed it (#818).
  defp shared_with?(_folder, nil), do: false

  defp shared_with?(folder, reader),
    do: Access.can_read?(Access.share_permission(reader, folder))

  defp readable_boards(_ids, nil), do: []

  defp readable_boards(ids, reader) do
    from(b in Board, where: b.id in ^ids)
    |> Repo.all()
    |> Enum.filter(&Access.can_read?(Access.board_permission(reader, &1)))
    |> Enum.map(& &1.id)
  end

  @doc """
  The placements a move of the folders `moving_ids` to `target_board_id`
  would leave between boards that are neither one board nor one vault:
  `[%{id:, folder:, in:}]`, the two ends by path as they stand before it.
  """
  def stranded_by_move(moving_ids, target_board_id) do
    target_vault = vault_id(target_board_id)

    from(pl in FolderPlacement,
      join: f in Folder,
      on: f.id == pl.folder_id,
      join: t in Folder,
      on: t.id == pl.in_folder_id,
      where: pl.folder_id in ^moving_ids or pl.in_folder_id in ^moving_ids,
      select: {pl.id, f, t}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, f, t} ->
      fb = if f.id in moving_ids, do: target_board_id, else: f.board_id
      tb = if t.id in moving_ids, do: target_board_id, else: t.board_id

      not (fb == tb or
             (not is_nil(target_vault) and vault_id(fb) == target_vault and
                vault_id(tb) == target_vault))
    end)
    |> Enum.map(fn {id, f, t} ->
      %{id: id, folder: Wiki.folder_path(f), in: Wiki.folder_path(t)}
    end)
  end

  @doc "Deletes placements by id."
  def delete_ids([]), do: :ok

  def delete_ids(ids) do
    Repo.delete_all(from(pl in FolderPlacement, where: pl.id in ^ids))
    :ok
  end

  defp writer?(user, board_id) do
    case Repo.get(Board, board_id) do
      nil -> false
      board -> Access.can_write?(Access.board_permission(user, board))
    end
  end

  defp reachable?(%Folder{board_id: id}, %Folder{board_id: id}), do: true

  defp reachable?(%Folder{board_id: home}, %Folder{board_id: there}) do
    case Vaults.for_board(home) do
      nil -> false
      vault -> there in Vaults.board_ids(vault)
    end
  end

  defp vault_id(board_id) do
    case Vaults.for_board(board_id) do
      nil -> nil
      vault -> vault.id
    end
  end

  defp touched(folder, target) do
    Changes.record(folder.board_id, "folder", folder.id)
    Wiki.broadcast_board(folder.board_id)
    if target.board_id != folder.board_id, do: Wiki.broadcast_board(target.board_id)
  end
end
