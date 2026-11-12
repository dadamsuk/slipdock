defmodule SlipdockWeb.WikiLive.TreeOps do
  @moduledoc """
  What the tree's dialogs act on (`WikiLive.Index`): drop targets and
  whether the reader may write there, moving and filing pages and folders,
  within a board and across boards, sharing, and deleting a folder.
  """
  use SlipdockWeb, :html
  import Phoenix.LiveView

  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Wiki.{Folder, Page, Tree, WikiFile}
  alias SlipdockWeb.Params
  alias SlipdockWeb.WikiLive.State

  # Where a drop landed, on whichever board the tree shows: "folder:" is the
  # top of this board's wiki, "board:4" the top of that board's (in a vault's
  # tree), "folder:9" a folder, and "page:7" inside a page, which is the
  # other axis (see `Slipdock.Wiki.Folder`). Only boards the reader can write.
  def drop_target(socket, "folder:") do
    case writable_board(socket, socket.assigns.board.id) do
      nil -> :none
      board -> {:folder, board, nil}
    end
  end

  def drop_target(socket, "folder:" <> ref) do
    with id when is_integer(id) <- Params.id(ref),
         %Folder{} = folder <- Wiki.get_folder(id),
         %Slipdock.Boards.Board{} = board <- writable_board(socket, folder.board_id) do
      {:folder, board, folder}
    else
      _ -> :none
    end
  end

  def drop_target(socket, "board:" <> ref) do
    case Params.id(ref) && writable_board(socket, Params.id(ref)) do
      nil -> :none
      board -> {:folder, board, nil}
    end
  end

  def drop_target(socket, "page:" <> ref) do
    with id when is_integer(id) <- Params.id(ref),
         %Page{} = page <- Wiki.get_page(id),
         %Slipdock.Boards.Board{} = board <- writable_board(socket, page.board_id) do
      {:page, board, page}
    else
      _ -> :none
    end
  end

  def drop_target(_socket, _into), do: :none

  # The board `board_id` as one the reader can write to from here: this one,
  # or another board of its vault.
  # What the Share dialog is about, if this reader may share it: a writer
  # on its board, never someone it was only shared with.
  def share_item(socket, "page", id) do
    with %Page{} = page <- Params.id(to_string(id)) && Wiki.get_page(id),
         %{} <- writable_board(socket, page.board_id) do
      {:ok, page}
    else
      _ -> :error
    end
  end

  def share_item(socket, "folder", id) do
    with %Folder{} = folder <- Params.id(to_string(id)) && Wiki.get_folder(id),
         %{} <- writable_board(socket, folder.board_id) do
      {:ok, folder}
    else
      _ -> :error
    end
  end

  def share_item(_socket, _kind, _id), do: :error

  def share_state(kind, item, groups, key),
    do: %{kind: kind, item: item, grants: Access.list_grants(item), groups: groups, key: key}

  # The tree's "shared" marks and the page's own line follow a change.
  def after_share(%{assigns: %{page: %Page{} = page}} = socket),
    do: socket |> State.assign_page(Wiki.get_page!(page.id)) |> State.load_tree_state()

  def after_share(socket), do: State.load_tree_state(socket)

  def writable_board(%{assigns: %{board: %{id: id} = board, can_write: true}}, id), do: board
  def writable_board(%{assigns: %{board: %{id: id}}}, id), do: nil
  def writable_board(%{assigns: %{vault: nil}}, _id), do: nil

  def writable_board(socket, id) do
    with true <- Enum.member?(Slipdock.Vaults.board_ids(socket.assigns.vault), id),
         %Slipdock.Boards.Board{} = board <- Boards.get_board(id),
         true <- Access.can_write?(Access.board_permission(socket.assigns.current_user, board)) do
      board
    else
      _ -> nil
    end
  end

  # A row of the tree the reader can change: a page or a folder on a board
  # they can write to.
  def tree_item(socket, "page:" <> ref) do
    with id when is_integer(id) <- Params.id(ref),
         %Page{} = page <- Wiki.get_page(id),
         %{} <- writable_board(socket, page.board_id),
         do: page,
         else: (_ -> nil)
  end

  def tree_item(socket, "folder:" <> ref) do
    with id when is_integer(id) <- Params.id(ref),
         %Folder{} = folder <- Wiki.get_folder(id),
         %{} <- writable_board(socket, folder.board_id),
         do: folder,
         else: (_ -> nil)
  end

  # A row seen through a placed folder (#808) is the row itself.
  def tree_item(socket, "at:" <> _ = key) do
    case Tree.split_via(key) do
      {:ok, _chain, inner} -> tree_item(socket, inner)
      _ -> nil
    end
  end

  def tree_item(_socket, _key), do: nil

  def also_file(%Page{} = page, folder, user), do: Wiki.Placements.add(page, folder, user)

  def also_file(%Folder{} = placed, folder, user),
    do: Wiki.FolderPlacements.add(placed, folder, user)

  def tree_items(socket, keys) when is_list(keys) do
    keys
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(500)
    |> Enum.map(&tree_item(socket, &1))
    |> Enum.reject(&is_nil/1)
  end

  def tree_items(_socket, _keys), do: []

  def tree_move(socket, "page", id, into, before) do
    with %Page{} = page <- tree_item(socket, "page:#{id}"),
         target when target != :none <- drop_target(socket, into) do
      {board, parent, folder} =
        case target do
          # Filed in a folder, and part of nothing: the two axes are set
          # together because the tree draws them together.
          {:folder, board, folder} ->
            {board, nil, folder}

          {:page, board, parent} ->
            {board, parent, parent.folder_id && Wiki.get_folder(parent.folder_id)}
        end

      if board.id == page.board_id,
        do: move_within(socket, page, board, parent, folder, before),
        else: cross_move_prompt(socket, [page], board, folder, parent)
    else
      _ -> put_flash(socket, :error, "That page couldn't be moved.")
    end
  end

  # Dropped on another board of the vault, a folder waits, as a page does,
  # for the reader to see what goes with it (#746).
  def tree_move(socket, "folder", id, into, before) do
    with %Folder{} = folder <- tree_item(socket, "folder:#{id}"),
         {:folder, board, parent} <- drop_target(socket, into) do
      if board.id == folder.board_id,
        do: move_folder_within(socket, folder, parent, before),
        else: cross_move_prompt(socket, [], board, parent, nil, [folder])
    else
      _ -> put_flash(socket, :error, "That folder couldn't be moved.")
    end
  end

  # A file (an image, a PDF, a drawing) is filed in a folder of its own
  # board, the way a vault keeps it on disk: it is never part of a page,
  # and it doesn't cross boards (#749).
  def tree_move(socket, "file", id, into, _before) do
    with %WikiFile{} = file <- tree_file(socket, id),
         target when target != :none <- drop_target(socket, into) do
      {board, folder} = file_target(target)
      move_file(socket, file, board, folder)
    else
      _ -> put_flash(socket, :error, "That file couldn't be moved.")
    end
  end

  def tree_move(socket, _kind, _id, _into, _before), do: socket

  def tree_file(socket, ref) do
    with id when is_integer(id) <- Params.id(ref),
         %WikiFile{archived_at: nil} = file <- Wiki.Files.get(id),
         %{} <- writable_board(socket, file.board_id),
         do: file,
         else: (_ -> nil)
  end

  def file_owner?(socket, %WikiFile{board_id: board_id}), do: board_owner?(socket, board_id)

  # Whether the reader owns the board a tree row lives on, which may not be
  # this one in a vault: only the owner purges (#733).
  def board_owner?(socket, board_id) do
    case Boards.get_board(board_id) do
      %Slipdock.Boards.Board{} = board ->
        Access.board_permission(socket.assigns.current_user, board) == :owner

      nil ->
        false
    end
  end

  # Dropped between two rows of a folder that is sorted by name (or by date),
  # a page or folder is filed there but takes its place in that order, not
  # the one it was dropped in (#789). Say so, and how to order by hand, rather
  # than let it jump without a word. An error from the move itself wins.
  def sorted_drop_note(socket, kind, into, before)
      when kind in ["page", "folder"] and not is_nil(before) do
    with nil <- Phoenix.Flash.get(socket.assigns.flash, :error),
         {:folder, board, folder} <- drop_target(socket, into),
         sort when sort != "manual" <- Wiki.tree_sort(board, folder) do
      put_flash(
        socket,
        :info,
        "#{folder_label(folder)} is sorted #{sort_label(sort)}, so that is where it goes. " <>
          "Choose Sort: As arranged to put things in your own order."
      )
    else
      _ -> socket
    end
  end

  def sorted_drop_note(socket, _kind, _into, _before), do: socket

  defp sort_label("name"), do: "by name"
  defp sort_label("modified"), do: "last changed first"
  defp sort_label("created"), do: "newest first"
  defp sort_label(other), do: other

  defp folder_label(nil), do: "The top of the wiki"
  defp folder_label(%Folder{name: name}), do: name

  defp move_within(socket, page, board, parent, folder, before) do
    with {:ok, page} <- Wiki.file_page(page, folder),
         index <- sibling_index(board, page, parent, before),
         {:ok, _} <-
           Wiki.move_page(page, parent, index, user: socket.assigns.current_user, via: "web") do
      socket
    else
      _ -> put_flash(socket, :error, "That page couldn't be moved.")
    end
  end

  # Pages and folders bound for another board of the vault wait for the
  # reader to see what goes with them and what cannot (R11.8, #746): see
  # `Slipdock.Wiki.Move` and `Slipdock.Wiki.FolderMove`. A page or folder
  # inside a folder that is moving goes with it, and is counted once.
  def cross_move_prompt(socket, pages, board, folder, parent, folders \\ []) do
    user = socket.assigns.current_user
    folders = outermost(folders)
    pages = outside(pages, folders)

    page_reports =
      for page <- pages, do: Slipdock.Wiki.Move.preview(page, board, user)

    folder_reports =
      for f <- folders,
          do: Slipdock.Wiki.FolderMove.preview(f, board, user, parent: folder)

    case Enum.find(page_reports ++ folder_reports, &(not match?({:ok, _}, &1))) do
      nil ->
        moving = %{pages: pages, folders: folders, board: board, folder: folder, parent: parent}
        assign(socket, tree_prompt: cross_move(moving, page_reports, folder_reports))

      {:error, _status, message} when is_binary(message) ->
        put_flash(socket, :error, "That can't move to #{board.name}: #{message}")

      _ ->
        put_flash(socket, :error, "Those can't move to #{board.name}.")
    end
  end

  # The pages not inside one of the folders that are moving.
  defp outside(pages, folders) do
    inside =
      folders
      |> Enum.flat_map(&[&1 | Slipdock.Wiki.Folders.descendants(&1)])
      |> MapSet.new(& &1.id)

    Enum.reject(pages, &MapSet.member?(inside, &1.folder_id))
  end

  # The prompt, once every preview has come back `{:ok, report}`.
  defp cross_move(moving, page_reports, folder_reports) do
    pages_r = for {:ok, r} <- page_reports, do: r
    folders_r = for {:ok, r} <- folder_reports, do: r

    Map.merge(moving, %{kind: :cross_move, report: merge_reports(pages_r, folders_r)})
  end

  # The selected folders not inside another selected folder.
  defp outermost(folders) do
    ids = MapSet.new(folders, & &1.id)

    Enum.reject(folders, fn f ->
      f |> Slipdock.Wiki.Folders.ancestors() |> Enum.any?(&MapSet.member?(ids, &1.id))
    end)
  end

  defp merge_reports(reports, folder_reports) do
    all = reports ++ folder_reports

    %{
      pages: report_sum(all, :pages),
      folders: report_sum(folder_reports, :folders),
      files: report_sum(folder_reports, :files),
      tags: carried_and_dropped(all, :tags),
      fields: carried_and_dropped(all, :fields),
      pins: carried_and_dropped(all, :pins),
      assignees: dropped_assignees(reports, folder_reports),
      lists: report_values(reports, :list),
      parents: report_values(reports, :parent),
      left_behind: Enum.flat_map(folder_reports, &Map.fetch!(&1, :left_behind)),
      filing_dropped: report_sum(folder_reports, :filing_dropped),
      title_clashes:
        folder_reports |> Enum.flat_map(&Map.fetch!(&1, :title_clashes)) |> Enum.uniq()
    }
  end

  defp report_sum(reports, key), do: reports |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()

  defp report_values(reports, key),
    do: reports |> Enum.map(&Map.fetch!(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp carried_and_dropped(reports, key) do
    part = fn part ->
      reports |> Enum.flat_map(&(&1[key][part] || [])) |> Enum.uniq() |> Enum.sort()
    end

    %{carried: part.(:carried), dropped: part.(:dropped)}
  end

  defp dropped_assignees(reports, folder_reports) do
    (Enum.map(reports, & &1.assignee.dropped) ++
       Enum.flat_map(folder_reports, & &1.assignees.dropped))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Where "Move to…" and "Also file in…" offer to put things: the top of
  # each board the reader can write to, then its folders by path. Every
  # board of the vault, or this board alone outside one.
  def move_targets(socket, roots? \\ true) do
    boards =
      case socket.assigns.vault do
        nil ->
          if socket.assigns.can_write, do: [socket.assigns.board], else: []

        vault ->
          vault
          |> Slipdock.Vaults.board_ids()
          |> Enum.map(&writable_board(socket, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(&{&1.id != socket.assigns.board.id, String.downcase(&1.name)})
      end

    many? = length(boards) > 1

    Enum.flat_map(boards, fn board ->
      top = %{
        key: "board:#{board.id}",
        label: if(many?, do: "#{board.name} — the top", else: "The top of the wiki"),
        depth: 0
      }

      folders =
        for o <- Slipdock.Wiki.Folders.outline(Wiki.folders(board)),
            do: %{
              key: "folder:#{o.folder.id}",
              label: if(many?, do: "#{board.name} / #{o.path}", else: o.path),
              depth: o.depth + 1
            }

      if roots?, do: [top | folders], else: folders
    end)
  end

  # Where in its new parent's children the page lands. The page tree's order
  # is per parent rather than per folder, so the answer is the index of what
  # it was dropped above in *that* list, not in the list on the screen.
  defp sibling_index(board, %Page{} = page, parent, before) do
    siblings = Wiki.sibling_ids(board.id, parent && parent.id, page.id)

    case before && Enum.find_index(siblings, &(to_string(&1) == to_string(before))) do
      nil -> length(siblings)
      n -> n
    end
  end

  def delete_folder(socket, folder, strategy) do
    note =
      case strategy do
        :purge -> "Deleted the folder “#{folder.name}” and everything in it."
        :keep -> "Deleted the folder “#{folder.name}”. Nothing in it was deleted."
      end

    case Wiki.delete_folder(folder, strategy) do
      {:ok, _} ->
        socket
        |> assign(folder_delete: nil, folder: nil)
        |> put_flash(:info, note)
        |> State.load_tree()
        |> leave_gone_folder()

      _ ->
        assign(socket, folder_delete: nil)
        |> put_flash(:error, "That folder couldn't be deleted.")
    end
  end

  defp move_folder_within(socket, folder, parent, before) do
    case Wiki.move_folder(folder, parent, State.blank_to_integer(before)) do
      {:ok, _} -> socket
      {:error, :unprocessable_entity, message} -> put_flash(socket, :error, message)
      _ -> put_flash(socket, :error, "That folder couldn't be moved.")
    end
  end

  # Where a file dropped on a folder or a page goes: a page's folder.
  defp file_target({:folder, board, folder}), do: {board, folder}

  defp file_target({:page, board, page}),
    do: {board, page.folder_id && Wiki.get_folder(page.folder_id)}

  defp move_file(socket, file, board, folder) do
    folder_id = folder && folder.id

    cond do
      board.id != file.board_id ->
        put_flash(socket, :error, "A file can only move within its own board.")

      folder_id == file.folder_id ->
        socket

      Wiki.Files.taken?(board.id, folder_id, file.name, file.id) ->
        put_flash(
          socket,
          :error,
          "#{folder_label(folder)} already has a file called #{file.name}."
        )

      true ->
        refile(socket, file, folder_id)
    end
  end

  defp refile(socket, file, folder_id) do
    case Wiki.Files.move(file, %{folder_id: folder_id}) do
      {:ok, _} -> socket
      _ -> put_flash(socket, :error, "That file couldn't be moved.")
    end
  end

  # Looking at the folder that has just gone: the wiki is where to be.
  defp leave_gone_folder(%{assigns: %{live_action: :index}} = socket),
    do: push_patch(socket, to: ~p"/boards/#{socket.assigns.board}/wiki")

  defp leave_gone_folder(socket), do: socket
end
