defmodule SlipdockWeb.WikiLive.ItemEvents do
  @moduledoc """
  `WikiLive.Index`'s events on items picked in the tree: renaming,
  archiving and deleting pages and files, moving and filing them, Organise…,
  and bulk actions on a selection.
  """
  use SlipdockWeb.WikiLive.Events

  import SlipdockWeb.WikiLive.Format
  import SlipdockWeb.WikiLive.State
  import SlipdockWeb.WikiLive.TreeRows
  import SlipdockWeb.WikiLive.TreeOps
  alias Slipdock.{Boards, Wiki}
  alias Slipdock.Wiki.{AutoOrganise, Folder, Page, WikiFile}

  # F2 on a page in the tree: its title, in a box. (On a folder, F2 sends
  # rename_folder, as the folder's menu does.)
  def handle_event("rename_page", %{"id" => id}, socket) do
    case tree_page(socket, id) do
      %Page{} = page -> {:noreply, assign(socket, tree_prompt: %{kind: :rename, page: page})}
      nil -> {:noreply, socket}
    end
  end

  # Delete on a page in the tree asks first: archiving can be undone, but a
  # key pressed by mistake should not need undoing.
  def handle_event("ask_archive_page", %{"id" => id}, socket) do
    case tree_page(socket, id) do
      %Page{} = page -> {:noreply, assign(socket, tree_prompt: %{kind: :archive, page: page})}
      nil -> {:noreply, socket}
    end
  end

  # Delete… on a page in the tree (#1098): gone for good, history and all,
  # so asked first, with the warning the page's own menu gives. Only the
  # board's owner may; the prompt says so rather than the menu hiding it.
  def handle_event("ask_delete_page", %{"id" => id}, socket) do
    case tree_page(socket, id) do
      %Page{} = page ->
        {:noreply,
         assign(socket,
           tree_prompt: %{
             kind: :delete_page,
             page: page,
             children: Wiki.children(page),
             owner: board_owner?(socket, page.board_id)
           }
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_from_tree", _params, socket) do
    with %{kind: :delete_page, page: page} <- socket.assigns.tree_prompt,
         %Page{} = page <- tree_page(socket, page.id),
         true <- board_owner?(socket, page.board_id),
         {:ok, _} <- Wiki.delete_page(page) do
      socket =
        socket
        |> assign(tree_prompt: nil)
        |> put_flash(:info, "Deleted “#{page.title}” for good.")
        |> load_tree()

      # The page being read was the one deleted: there is nothing left to show.
      {:noreply,
       if(match?(%Page{id: id} when id == page.id, socket.assigns.page),
         do: push_patch(socket, to: wiki_path(socket.assigns.board)),
         else: socket
       )}
    else
      false -> {:noreply, put_flash(socket, :error, "Only the board's owner can delete a page.")}
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be deleted.")}
    end
  end

  # A file in the tree is archived or deleted for good (#769), each asked
  # first. Deleting gives the storage back, and like a page's, only the
  # board's owner may do it; the prompt says so rather than the menu hiding it.
  def handle_event("ask_archive_file", %{"id" => id}, socket) do
    case tree_file(socket, id) do
      %WikiFile{} = file ->
        {:noreply, assign(socket, tree_prompt: %{kind: :archive_file, file: file})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("ask_delete_file", %{"id" => id}, socket) do
    case tree_file(socket, id) do
      %WikiFile{} = file ->
        {:noreply,
         assign(socket,
           tree_prompt: %{kind: :delete_file, file: file, owner: file_owner?(socket, file)}
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("archive_file", _params, socket) do
    with %{kind: :archive_file, file: file} <- socket.assigns.tree_prompt,
         %WikiFile{} = file <- tree_file(socket, file.id),
         {:ok, _} <- Wiki.Files.archive(file) do
      {:noreply,
       socket
       |> assign(tree_prompt: nil)
       |> put_flash(:info, "Archived #{file.name}.")
       |> load_tree()}
    else
      _ -> {:noreply, put_flash(socket, :error, "That file couldn't be archived.")}
    end
  end

  def handle_event("delete_file", _params, socket) do
    with %{kind: :delete_file, file: file} <- socket.assigns.tree_prompt,
         %WikiFile{} = file <- tree_file(socket, file.id),
         true <- file_owner?(socket, file),
         {:ok, _} <- Wiki.Files.delete(file) do
      {:noreply,
       socket
       |> assign(tree_prompt: nil)
       |> put_flash(:info, "Deleted #{file.name} for good.")
       |> load_tree()}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Only the board's owner can delete a file.")}

      _ ->
        {:noreply, put_flash(socket, :error, "That file couldn't be deleted.")}
    end
  end

  # A name put on a voice in the page's transcript, from the player (#1157).
  def handle_event("rename_speaker", %{"from" => from, "to" => to}, socket)
      when is_binary(from) and is_binary(to) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, saved} <-
           Wiki.rename_speaker(page, from, to,
             user: socket.assigns.current_user,
             via: "web",
             # Whether the voiceprint went comes back as a flash (#1201).
             notify: self()
           ) do
      {:noreply,
       socket
       |> reload(saved)
       |> put_flash(
         :info,
         "“#{String.trim(from)}” is now “#{String.trim(to)}” in the transcript." <>
           if(
             Slipdock.Transcription.Voiceprints.enabled_for?(socket.assigns.current_user) and
               Slipdock.Transcript.person_label?(to),
             do: " Their longest stretch goes to the transcription server as a voiceprint.",
             else: ""
           )
       )}
    else
      {:error, reason} when is_atom(reason) ->
        {:noreply, put_flash(socket, :error, speaker_refusal(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, "That voice couldn't be renamed.")}
    end
  end

  def handle_event("close_tree_prompt", _params, socket),
    do: {:noreply, assign(socket, tree_prompt: nil)}

  def handle_event("save_page_title", %{"title" => title}, socket) do
    with %{kind: :rename, page: page} <- socket.assigns.tree_prompt,
         {:ok, renamed} <-
           Wiki.update_page(page, %{"title" => String.trim(title)},
             user: socket.assigns.current_user,
             via: "web"
           ) do
      socket =
        socket
        |> assign(tree_prompt: nil)
        |> put_flash(:info, "Renamed to “#{renamed.title}”.")
        |> load_tree()

      # The page being read was the one renamed: its slug may have moved.
      {:noreply,
       if(match?(%Page{id: id} when id == renamed.id, socket.assigns.page),
         do: push_patch(socket, to: page_path(socket.assigns.board, renamed)),
         else: socket
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be renamed.")}
    end
  end

  def handle_event("archive_from_tree", _params, socket) do
    with %{kind: :archive, page: page} <- socket.assigns.tree_prompt,
         {:ok, _} <- Wiki.archive_page(page) do
      socket =
        socket
        |> assign(tree_prompt: nil)
        |> put_flash(:info, "Archived “#{page.title}”.")
        |> load_tree()

      {:noreply,
       if(match?(%Page{id: id} when id == page.id, socket.assigns.page),
         do: push_patch(socket, to: wiki_path(socket.assigns.board)),
         else: socket
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be archived.")}
    end
  end

  # The tree's menu and its selection (R11.8, R11.10) ask for one of these
  # with the keys of the rows they act on. Anything the reader cannot change
  # is left out.
  def handle_event("tree_dialog", %{"kind" => kind, "keys" => keys}, socket)
      when kind in ~w(move also archive tag) do
    items = tree_items(socket, keys)
    pages = for %Page{} = page <- items, do: page

    prompt =
      case kind do
        "move" when items != [] ->
          %{kind: :move, items: items, targets: move_targets(socket), q: ""}

        "also" when pages != [] ->
          page = hd(pages)

          %{
            kind: :also,
            items: [page],
            targets:
              Enum.reject(move_targets(socket, false), &(&1.key == "folder:#{page.folder_id}")),
            q: ""
          }

        # A folder (#808): anywhere but itself, its home, and its own subtree.
        "also" when items != [] ->
          folder = hd(items)
          barred = [folder.id, folder.parent_id | Wiki.FolderPlacements.below_ids(folder)]
          barred = MapSet.new(barred, &"folder:#{&1}")

          %{
            kind: :also,
            items: [folder],
            targets: Enum.reject(move_targets(socket, false), &MapSet.member?(barred, &1.key)),
            q: ""
          }

        "archive" when pages != [] ->
          %{kind: :archive_many, items: pages}

        "tag" when pages != [] ->
          %{
            kind: :tag_many,
            items: pages,
            tags: Boards.Tags.list_tags(Slipdock.Boards.Board.root_id(socket.assigns.board))
          }

        _ ->
          nil
      end

    {:noreply,
     if(prompt,
       do: assign(socket, tree_prompt: prompt),
       else: put_flash(socket, :error, "Nothing there you can change.")
     )}
  end

  def handle_event("tree_dialog_filter", %{"q" => q}, socket) do
    case socket.assigns.tree_prompt do
      %{targets: _} = prompt -> {:noreply, assign(socket, tree_prompt: %{prompt | q: q})}
      _ -> {:noreply, socket}
    end
  end

  # "Move to…": what is on the target's board moves there at once; pages and
  # folders bound for another board of the vault wait for the confirmation
  # of what goes with them.
  def handle_event("move_to", %{"target" => target}, socket) do
    with %{kind: :move, items: items} <- socket.assigns.tree_prompt,
         {:folder, board, folder} <- drop_target(socket, target) do
      {here, there} = Enum.split_with(items, &(&1.board_id == board.id))
      user = socket.assigns.current_user

      moved = Enum.count(here, &move_here(&1, folder, user))

      folders_there = for %Folder{} = f <- there, do: f
      pages_there = for %Page{} = p <- there, do: p

      socket =
        socket
        |> assign(tree_prompt: nil)
        |> then(
          &if(moved > 0, do: put_flash(&1, :info, "Moved #{count(moved, "item")}."), else: &1)
        )
        |> load_tree()
        |> assign_current()

      {:noreply,
       if(there != [],
         do: cross_move_prompt(socket, pages_there, board, folder, nil, folders_there),
         else: socket
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "Those couldn't be moved there.")}
    end
  end

  def handle_event("confirm_cross_move", _params, socket) do
    case socket.assigns.tree_prompt do
      %{kind: :cross_move, pages: _, board: _, folder: _, parent: _} = prompt ->
        {:noreply, confirm_cross_move(socket, prompt)}

      _ ->
        {:noreply, socket}
    end
  end

  # A folder's "Organise…" (#791): a way to sort what is filed in it, a
  # preview of where each item would go with a box to untick it, then the
  # ticked ones filed. The AI's suggestions are asked for on a button, since
  # each ask is a call to the reader's model.
  def handle_event("organise_folder", %{"id" => id}, socket) do
    with %Folder{} = folder <- tree_item(socket, "folder:#{id}"),
         %Slipdock.Boards.Board{} = board <- writable_board(socket, folder.board_id) do
      path = Wiki.folder_path(folder)

      prompt =
        organise_plan(%{
          kind: :organise,
          folder: folder,
          board: board,
          mode: "date",
          parent: path,
          granularity: "month",
          source: "auto",
          plan: nil,
          excluded: MapSet.new(),
          error: nil,
          asking: false,
          paths: AutoOrganise.folder_paths(board),
          ai?: Slipdock.AI.configured?(socket.assigns.current_user)
        })

      {:noreply, assign(socket, tree_prompt: prompt)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That folder can't be organised from here.")}
    end
  end

  def handle_event("organise_draft", params, socket) do
    case socket.assigns.tree_prompt do
      %{kind: :organise} = prompt ->
        prompt = %{
          prompt
          | mode: organise_choice(params["mode"], AutoOrganise.modes(), prompt.mode),
            parent: Map.get(params, "parent", prompt.parent),
            granularity:
              organise_choice(
                params["granularity"],
                AutoOrganise.granularities(),
                prompt.granularity
              ),
            source: organise_choice(params["source"], ~w(auto added), prompt.source),
            excluded: MapSet.new()
        }

        {:noreply, assign(socket, tree_prompt: organise_plan(prompt))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("organise_pick", params, socket) do
    case socket.assigns.tree_prompt do
      %{kind: :organise, plan: [_ | _] = plan} = prompt ->
        kept = MapSet.new(List.wrap(params["include"]))
        excluded = for(e <- plan, not Enum.member?(kept, e.key), into: MapSet.new(), do: e.key)
        {:noreply, assign(socket, tree_prompt: %{prompt | excluded: excluded})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("organise_ask", _params, socket) do
    case socket.assigns.tree_prompt do
      %{kind: :organise, mode: "ai", asking: false, folder: folder} = prompt ->
        user = socket.assigns.current_user

        {:noreply,
         socket
         |> assign(tree_prompt: %{prompt | asking: true, error: nil, plan: nil})
         |> start_async(:organise_ai, fn -> AutoOrganise.plan(folder, "ai", user: user) end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm_organise", _params, socket) do
    with %{kind: :organise, plan: [_ | _] = plan, board: board, excluded: excluded} <-
           socket.assigns.tree_prompt,
         entries when entries != [] <- Enum.reject(plan, &MapSet.member?(excluded, &1.key)),
         {:ok, result} <- AutoOrganise.apply_plan(board, entries) do
      made = if result.folders > 0, do: ", making #{count(result.folders, "folder")}", else: ""

      socket =
        socket
        |> assign(tree_prompt: nil)
        |> put_flash(:info, "Organised #{count(result.moved, "item")}#{made}.")
        |> put_skipped_flash(result.skipped)
        |> load_tree()
        |> assign_current()

      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, "Nothing was picked to organise.")}
    end
  end

  # "Also file in…": a placement beside the page's home (W-103 R12), or
  # the folder's (#808).
  def handle_event("also_file_in", %{"target" => target}, socket) do
    with %{kind: :also, items: [item]} <- socket.assigns.tree_prompt,
         {:folder, _board, %Folder{} = folder} <- drop_target(socket, target),
         {:ok, _} <- also_file(item, folder, socket.assigns.current_user) do
      {:noreply,
       socket
       |> assign(tree_prompt: nil)
       |> put_flash(:info, "“#{item_name(item)}” is also filed in #{Wiki.folder_path(folder)}.")
       |> load_tree()}
    else
      {:error, _status, message} -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, put_flash(socket, :error, "That couldn't be filed there.")}
    end
  end

  def handle_event("bulk_archive", _params, socket) do
    case socket.assigns.tree_prompt do
      %{kind: :archive_many, items: pages} ->
        done = Enum.count(pages, &match?({:ok, _}, Wiki.archive_page(&1)))

        {:noreply,
         socket
         |> assign(tree_prompt: nil)
         |> put_flash(:info, "Archived #{count(done, "page")}.")
         |> load_tree()
         |> then(fn socket ->
           if socket.assigns.page && Enum.any?(pages, &(&1.id == socket.assigns.page.id)),
             do: push_patch(socket, to: wiki_path(socket.assigns.board)),
             else: socket
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  # A tag for every page picked: the board's own tags, which a page on
  # another board of the vault does not share, so those are left as they are.
  def handle_event("bulk_tag", %{"tag" => tag_id}, socket) do
    with %{kind: :tag_many, items: pages, tags: tags} <- socket.assigns.tree_prompt,
         %{} = tag <- Enum.find(tags, &(to_string(&1.id) == to_string(tag_id))) do
      root = Slipdock.Boards.Board.root_id(socket.assigns.board)

      {mine, others} =
        Enum.split_with(pages, fn page ->
          Slipdock.Boards.Board.root_id(Boards.get_board!(page.board_id)) == root
        end)

      Enum.each(mine, fn page ->
        Wiki.set_tags(page, Enum.uniq_by(Wiki.tags(page) ++ [tag], & &1.id))
      end)

      note =
        if others == [],
          do: "Tagged #{count(length(mine), "page")} “#{tag.name}”.",
          else:
            "Tagged #{count(length(mine), "page")} “#{tag.name}”; #{count(length(others), "page")} on other boards left as they were."

      {:noreply, socket |> assign(tree_prompt: nil) |> put_flash(:info, note) |> load_tree()}
    else
      _ -> {:noreply, socket}
    end
  end

  # "Take out of this folder", on a folder's extra placement (#808): the
  # folder and all in it stay where they are.
  def handle_event(
        "remove_placement",
        %{"kind" => "folder", "id" => id, "folder" => folder_id},
        socket
      ) do
    # Another owner's folder, shared with the reader and filed here, comes
    # out too: the placement's rules decide (#818).
    with %Folder{} = placed <- tree_item(socket, "folder:#{id}") || Wiki.get_folder(id),
         {:folder, _board, %Folder{} = folder} <- drop_target(socket, "folder:#{folder_id}"),
         {:ok, _} <-
           Wiki.FolderPlacements.remove(placed, folder, socket.assigns.current_user) do
      {:noreply,
       socket
       |> put_flash(:info, "“#{placed.name}” is no longer filed in #{folder.name}.")
       |> load_tree()}
    else
      {:error, _status, message} -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, put_flash(socket, :error, "That folder couldn't be taken out.")}
    end
  end

  # "Take out of this folder", on a page's extra placement (R12.4: the page
  # itself stays where it is).
  def handle_event("remove_placement", %{"id" => id, "folder" => folder_id}, socket) do
    with %Page{} = page <- tree_item(socket, "page:#{id}") || Wiki.get_page(id),
         {:folder, _board, %Folder{} = folder} <- drop_target(socket, "folder:#{folder_id}"),
         {:ok, _} <- Slipdock.Wiki.Placements.remove(page, folder, socket.assigns.current_user) do
      {:noreply,
       socket
       |> put_flash(:info, "“#{page.title}” is no longer filed in #{folder.name}.")
       |> load_tree()}
    else
      {:error, _status, message} -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be taken out of the folder.")}
    end
  end

  # Moves one item picked for "Move to…" within its own board; true if it moved.
  defp move_here(%Page{} = page, folder, user) do
    with {:ok, page} <- Wiki.file_page(page, folder),
         {:ok, _} <- Wiki.move_page(page, nil, :bottom, user: user, via: "web"),
         do: true,
         else: (_ -> false)
  end

  defp move_here(%Folder{} = moving, folder, _user),
    do: match?({:ok, _}, Wiki.move_folder(moving, folder, nil))

  # The cross-board move, once confirmed: folders first, with everything in
  # them; then the pages, each looked at again so one that went with a
  # folder is not moved twice.
  defp confirm_cross_move(socket, prompt) do
    %{pages: pages, board: board, folder: folder, parent: parent} = prompt
    user = socket.assigns.current_user

    {folders_moved, errors} =
      Enum.reduce(Map.get(prompt, :folders, []), {0, []}, fn f, {n, errors} ->
        case move_folder_across(f, board, folder, user) do
          :moved -> {n + 1, errors}
          {:error, message} -> {n, [message | errors]}
          :skipped -> {n, errors}
        end
      end)

    results =
      for page <- pages,
          %Page{} = page <- [Wiki.get_page(page.id)],
          page.board_id != board.id,
          do: move_page_across(page, board, folder, parent, user)

    moved = for {:ok, page} <- results, do: page

    socket
    |> assign(tree_prompt: nil)
    |> put_moved_flash(moved_what(folders_moved, moved), board)
    |> put_errors_flash(errors)
    |> load_tree()
    |> follow_moved_page(board)
  end

  defp moved_what(folders_moved, moved) do
    [
      folders_moved > 0 && count(folders_moved, "folder"),
      moved != [] && count(length(moved), "page")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" and ")
  end

  defp put_moved_flash(socket, "", _board), do: socket

  defp put_moved_flash(socket, what, board),
    do: put_flash(socket, :info, "Moved #{what} to #{board.name}.")

  defp put_errors_flash(socket, []), do: socket

  defp put_errors_flash(socket, errors),
    do: put_flash(socket, :error, Enum.join(Enum.reverse(errors), " "))

  # The page being read went with them: follow it to its new board.
  defp follow_moved_page(socket, board) do
    current = socket.assigns.page && Wiki.get_page(socket.assigns.page.id)

    case current do
      %Page{board_id: id} = page when id == board.id ->
        push_navigate(socket, to: ~p"/boards/#{board}/wiki/#{page.slug}")

      _ ->
        assign_current(socket)
    end
  end

  defp move_folder_across(f, board, folder, user) do
    with %Folder{} = f <- Wiki.get_folder(f.id),
         false <- f.board_id == board.id,
         {:ok, _} <-
           Slipdock.Wiki.FolderMove.to_board(f, board, user, parent: folder, via: "web") do
      :moved
    else
      {:error, _status, message} -> {:error, message}
      _ -> :skipped
    end
  end

  defp move_page_across(page, board, folder, parent, user) do
    with {:ok, moved} <- Slipdock.Wiki.Move.to_board(page, board, folder, user, via: "web") do
      if parent, do: Wiki.move_page(moved, parent, :bottom, user: user, via: "web")
      {:ok, moved}
    end
  end

  defp put_skipped_flash(socket, []), do: socket

  defp put_skipped_flash(socket, skipped) do
    put_flash(
      socket,
      :error,
      "Left where they were: " <>
        Enum.map_join(skipped, "; ", fn {title, why} -> "“#{title}” (#{why})" end) <>
        "."
    )
  end
end
