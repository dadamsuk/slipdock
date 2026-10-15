defmodule Slipdock.Wiki.SharedPlacements do
  @moduledoc """
  "Also file in…" across owners (#818): a page or folder shared with you,
  filed in a folder of your own.

  It is the one exception to the rule that something is only ever filed on
  its own board or in its own vault (`Slipdock.Wiki.Placements`,
  `Slipdock.Wiki.FolderPlacements`): the placer needs to read the item
  through the share and write the folder it goes in. The placement shows
  only to people who can read the item — the trees already ask that of
  every placed row — so nobody else on the placer's board sees anything.

  When the share is taken back the placement goes with it (`cleanup/1`,
  from `Slipdock.Access.revoke/1`): a placement whose folder's owner can no
  longer read the item is deleted, so sharing again later starts clean.
  Taking a placement out never touches the share or the item.
  """
  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo}
  alias Slipdock.Access.Grant
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Folder, FolderPlacement, Page, Placement}

  @doc "Whether two boards belong to different people: a placement between them crosses owners."
  def cross_owner?(board_id, board_id), do: false

  def cross_owner?(a, b), do: owner_of(a) != owner_of(b)

  defp owner_of(board_id) do
    case Repo.get(Board, board_id) do
      nil -> nil
      board -> Board.root_owner_id(board)
    end
  end

  @doc """
  After `grant` has been deleted: the placements of what it covered, in
  folders of other owners, that their folder's owner can no longer read.
  Returns how many went.
  """
  def cleanup(%Grant{page_id: page_id}) when not is_nil(page_id),
    do: cleanup_pages(from(p in Page, where: p.id == ^page_id))

  def cleanup(%Grant{folder_id: folder_id}) when not is_nil(folder_id) do
    case Repo.get(Folder, folder_id) do
      nil ->
        0

      folder ->
        ids = [folder.id | Enum.map(Slipdock.Wiki.Folders.descendants(folder), & &1.id)]
        cleanup_pages(from(p in Page, where: p.folder_id in ^ids)) + cleanup_folders(ids)
    end
  end

  def cleanup(_grant), do: 0

  defp cleanup_pages(pages) do
    from(pl in Placement,
      join: p in subquery(pages),
      on: p.id == pl.page_id,
      join: f in Folder,
      on: f.id == pl.folder_id,
      select: {pl.id, p.id, f.board_id}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, page_id, board_id} ->
      stale?(Repo.get!(Page, page_id), board_id)
    end)
    |> delete(Placement)
  end

  defp cleanup_folders(ids) do
    from(pl in FolderPlacement,
      join: t in Folder,
      on: t.id == pl.in_folder_id,
      where: pl.folder_id in ^ids,
      select: {pl.id, pl.folder_id, t.board_id}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, folder_id, board_id} ->
      stale?(Repo.get!(Folder, folder_id), board_id)
    end)
    |> delete(FolderPlacement)
  end

  # A placement across owners that the folder's owner can't read any more.
  defp stale?(item, board_id) do
    cross_owner?(item.board_id, board_id) and
      case owner_of(board_id) && Repo.get(User, owner_of(board_id)) do
        %User{} = owner -> not Access.can_read?(permission(owner, item))
        nil -> true
      end
  end

  defp permission(user, %Page{} = page), do: Access.page_permission(user, page)
  defp permission(user, %Folder{} = folder), do: Access.folder_permission(user, folder)

  defp delete([], _schema), do: 0

  defp delete(rows, schema) do
    ids = Enum.map(rows, &elem(&1, 0))
    {n, _} = Repo.delete_all(from(pl in schema, where: pl.id in ^ids))
    n
  end
end
