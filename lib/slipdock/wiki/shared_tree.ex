defmodule Slipdock.Wiki.SharedTree do
  @moduledoc """
  What has been shared with somebody, the way their **Shared with me** tree
  draws it (#817): grouped by whose it is, a shared folder opened to its
  whole subtree, and a page shared on its own as a page.

      [%{owner: %User{}, items: [node]}]

  where a node is

      %{kind: :folder, folder: %Folder{}, level: :read | :write,
        folders: [node], pages: [%Page{}], files: [%WikiFile{}]}
      %{kind: :page, page: %Page{}, level: :read | :write}

  Only what the share reaches is in it: what has its home in a shared
  folder's subtree, and pages granted directly. Nothing is said about the
  board it is on — not its name, not its other pages — because the share
  is not of the board. A folder shared inside another folder that is also
  shared shows once, inside the outer one. Things on the reader's own
  boards are left out: those are theirs, not shared with them.
  """
  import Ecto.Query, warn: false

  alias Slipdock.{Access, Accounts, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Folder, Page, WikiFile}

  @doc "The reader's Shared with me tree; `[]` when nothing is shared."
  @spec for_user(User.t() | nil) :: [%{owner: User.t(), items: [map]}]
  def for_user(nil), do: []

  def for_user(%User{} = user) do
    folder_levels = direct_levels(user, :folder_id)
    page_levels = direct_levels(user, :page_id)
    folder_ids = Access.shared_folder_subtree_ids(user)

    folders =
      from(f in Folder, where: f.id in ^folder_ids, preload: :board)
      |> Repo.all()
      |> Enum.reject(&own?(&1, user))

    by_id = Map.new(folders, &{&1.id, &1})
    levels = folder_levels_down(folders, by_id, folder_levels)
    ids = Map.keys(by_id)

    pages =
      from(p in Page,
        where: p.folder_id in ^ids and is_nil(p.archived_at),
        order_by: [asc: p.title]
      )
      |> Repo.all()
      |> Enum.filter(&Wiki.visible?(&1, best(levels[&1.folder_id], page_levels[&1.id])))

    files =
      from(f in WikiFile,
        where: f.folder_id in ^ids and is_nil(f.archived_at),
        order_by: [asc: f.name]
      )
      |> Repo.all()

    tops =
      folders
      |> Enum.filter(&Map.has_key?(folder_levels, &1.id))
      |> Enum.reject(&inside_another?(&1, by_id, folder_levels))

    folder_nodes =
      Enum.map(tops, &folder_node(&1, folders, pages, files, levels))

    listed = MapSet.new(pages, & &1.id)

    lone_pages =
      from(p in Page,
        where: p.id in ^Map.keys(page_levels) and is_nil(p.archived_at),
        preload: :board,
        order_by: [asc: p.title]
      )
      |> Repo.all()
      |> Enum.reject(&(own?(&1, user) or MapSet.member?(listed, &1.id)))
      |> Enum.filter(&Wiki.visible?(&1, Access.page_permission(user, &1)))
      |> Enum.map(&%{kind: :page, page: &1, level: Access.share_permission(user, &1)})

    (folder_nodes ++ lone_pages)
    |> Enum.group_by(&owner_id/1)
    |> Enum.map(fn {owner_id, items} ->
      %{owner: Repo.get!(User, owner_id), items: sort(items)}
    end)
    |> Enum.sort_by(&String.downcase(User.display_name(&1.owner)))
  end

  @doc "Whether anything at all is shared with the reader."
  def any?(user), do: for_user(user) != []

  # The grants naming the reader, or a group of theirs, on one kind of thing:
  # `%{id => :read | :write}`, the higher of two winning.
  defp direct_levels(%User{} = user, field) do
    group_ids = Accounts.group_ids_for(user)

    from(g in Grant,
      where: not is_nil(field(g, ^field)),
      where: g.user_id == ^user.id or g.group_id in ^group_ids,
      select: {field(g, ^field), g.level}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn
      {id, "write"}, acc -> Map.put(acc, id, :write)
      {id, "read"}, acc -> Map.put_new(acc, id, :read)
    end)
  end

  # Each folder's level: its own grant, or the best of any above it.
  defp folder_levels_down(folders, by_id, direct) do
    Map.new(folders, fn folder ->
      level =
        folder
        |> Stream.iterate(&up(&1, by_id))
        |> Enum.take_while(& &1)
        |> Enum.map(&Map.get(direct, &1.id, :none))
        |> Enum.reduce(:none, &best/2)

      {folder.id, level}
    end)
  end

  defp inside_another?(folder, by_id, direct) do
    folder
    |> Stream.iterate(&up(&1, by_id))
    |> Stream.drop(1)
    |> Enum.take_while(& &1)
    |> Enum.any?(&Map.has_key?(direct, &1.id))
  end

  # One step up a folder's home ancestry, among the shared folders; nil at
  # the top of what is shared (the stream asks one step past the end).
  defp up(nil, _by_id), do: nil
  defp up(%Folder{parent_id: id}, by_id), do: id && by_id[id]

  defp folder_node(folder, folders, pages, files, levels) do
    %{
      kind: :folder,
      folder: folder,
      level: levels[folder.id],
      folders:
        folders
        |> Enum.filter(&(&1.parent_id == folder.id))
        |> Enum.sort_by(&String.downcase(&1.name))
        |> Enum.map(&folder_node(&1, folders, pages, files, levels)),
      pages: Enum.filter(pages, &(&1.folder_id == folder.id)),
      files: Enum.filter(files, &(&1.folder_id == folder.id))
    }
  end

  defp sort(items) do
    {folders, pages} = Enum.split_with(items, &(&1.kind == :folder))

    Enum.sort_by(folders, &String.downcase(&1.folder.name)) ++
      Enum.sort_by(pages, &String.downcase(&1.page.title))
  end

  defp owner_id(%{kind: :folder, folder: %{board: %Board{} = board}}),
    do: Board.root_owner_id(board)

  defp owner_id(%{kind: :page, page: %{board: %Board{} = board}}), do: Board.root_owner_id(board)

  defp own?(%{board: %Board{} = board}, %User{id: id}), do: Board.root_owner_id(board) == id

  defp best(a, b) do
    rank = %{nil: 0, none: 0, read: 1, write: 2}
    if rank[a] >= rank[b], do: a || :none, else: b
  end
end
