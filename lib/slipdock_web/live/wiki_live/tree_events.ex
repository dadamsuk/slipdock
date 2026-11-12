defmodule SlipdockWeb.WikiLive.TreeEvents do
  @moduledoc """
  `WikiLive.Index`'s events from the tree and the bar above it: loading
  rows, previews, the view's toggles, folders made and renamed, sharing, the
  filter bar and the tree's sort.
  """
  use SlipdockWeb.WikiLive.Events

  import SlipdockWeb.WikiLive.State
  import SlipdockWeb.WikiLive.TreeRows
  import SlipdockWeb.WikiLive.TreeOps
  alias Slipdock.{Accounts, Wiki}
  alias Slipdock.Wiki.{Folder, Page, Tree, TreeStates}
  alias SlipdockWeb.Params

  # How much the tree asks for at once: a page of a big folder's rows, and
  # at most this many open containers in one go.
  @tree_page 500
  @tree_max_keys 300

  ## Events: folders ---------------------------------------------------------
  #
  # Filing, not writing. Every one of these is refused without write access,
  # and none of them can lose a page: see `Slipdock.Wiki.Folders`.

  # The WikiTree hook asking for rows (see `assets/js/wiki_tree.js`). With no
  # `keys`, the containers this reader had open in this tree last time are
  # loaded — kept on the server per reader and per tree (`TreeStates`), so
  # the tree comes back as they left it, on any machine — and sent back as
  # `open`. `keys` loads those instead, with the root unless `only` says it
  # is just those. `all` opens every folder. The way to what is being looked
  # at is always loaded and sent back as `reveal`, so it is never behind a
  # lid.
  #
  # While the filter bar is on, every level holding a match is sent and
  # opened: a hit three folders down is no use behind a shut one.
  def handle_event("tree_load", params, socket) do
    scope = socket.assigns.tree_scope
    root = socket.assigns.tree_root
    filter = scope_filter(socket, scope)

    kept =
      if is_list(params["keys"]),
        do: nil,
        else: TreeStates.get(socket.assigns.current_user, tree_state_scope(socket))

    {nodes, reveal} =
      if filter,
        do: {filter.nodes, []},
        else: {tree_load_nodes(socket, params, kept), socket.assigns.tree_reveal}

    access = row_access(socket)

    {:reply,
     %{
       scope: scope,
       root: root,
       filtering: filter != false and filter != nil,
       nodes: Map.new(nodes, fn {key, rows} -> {key, client_rows(rows, socket, access)} end),
       reveal: reveal,
       # How the top of this board's tree is sorted, for its menu.
       sort: Wiki.tree_sort(socket.assigns.board, nil),
       # What was kept of this tree's open folders: the hook's open set, or
       # nil the first time, when a small wiki opens whole.
       open: kept && Enum.filter(kept, &Map.has_key?(nodes_map(nodes), &1)),
       small: tree_small?(socket)
     }, socket}
  end

  # The hook saying what is open now, after a folder is opened or shut.
  def handle_event("tree_open", %{"keys" => keys}, socket) when is_list(keys) do
    TreeStates.put(socket.assigns.current_user, tree_state_scope(socket), keys)
    {:noreply, socket}
  end

  def handle_event("tree_open", _params, socket), do: {:noreply, socket}

  # The next page of a big container's rows, from the "more" row the hook
  # scrolled into view.
  def handle_event("tree_children", %{"key" => key} = params, socket) when is_binary(key) do
    offset = max(Params.id(to_string(params["offset"] || 0)) || 0, 0)

    rows =
      case container_rows(socket, socket.assigns.tree_scope, key,
             limit: @tree_page,
             offset: offset
           ) do
        {:ok, rows} -> rows
        _ -> []
      end

    {:reply, %{key: key, rows: client_rows(rows, socket)}, socket}
  end

  # A page row rested on (#760): what the hook's preview card shows. Only a
  # page this tree would show this reader: one of this board's, or of a
  # vault board they can read, under the same filters as its rows. Anything
  # else answers `found: false`, which draws nothing.
  def handle_event("tree_preview", %{"key" => "page:" <> ref}, socket) do
    with id when is_integer(id) <- Params.id(ref),
         %Page{board_id: board_id} <- Wiki.get_page(id),
         {board, opts} <- preview_board(socket, board_id),
         %{} = found <- Tree.preview(board, id, opts) do
      {:reply, preview_reply(found, board, socket.assigns.board), socket}
    else
      _ -> {:reply, %{found: false}, socket}
    end
  end

  def handle_event("tree_preview", _params, socket), do: {:reply, %{found: false}, socket}

  # The preview beside the editor, on or off. The choice is the writer's,
  # kept by their browser (the EditorPrefs hook) so every page opens the
  # same way.
  def handle_event("toggle_preview", _params, socket) do
    on = not socket.assigns.show_preview

    {:noreply,
     socket
     |> assign(show_preview: on)
     |> push_event("wiki-editor:preview", %{on: on})}
  end

  def handle_event("restore_preview", %{"on" => on}, socket) when is_boolean(on),
    do: {:noreply, assign(socket, show_preview: on)}

  def handle_event("restore_preview", _params, socket), do: {:noreply, socket}

  # Organise mode puts a handle on every row the reader can move. A shut
  # folder opens when a drag rests on it, so nothing has to be opened first.
  # In a vault's tree a page can be dragged to another board of the vault,
  # which asks first (R11.8).
  # The tree pane's Tree / Recent switch (#738). The hook keeps the choice in
  # this browser and asks for it again on the next visit; organising is a
  # tree thing, so Recent ends it.
  def handle_event("tree_view", %{"view" => view}, socket) when view in ["tree", "recent"] do
    socket =
      socket
      |> assign(tree_view: view, organising: socket.assigns.organising and view == "tree")
      |> assign_tree_recent()

    {:noreply, push_event(socket, "wiki-tree:view", %{view: view})}
  end

  def handle_event("tree_view", _params, socket), do: {:noreply, socket}

  # Full titles or short names, from the tree's own header: the same
  # setting as in account settings, so it follows the person, not the browser.
  def handle_event("toggle_tree_names", _params, socket) do
    choice = if tree_names(socket) == "short", do: "full", else: "short"

    case Accounts.update_display(socket.assigns.current_user, %{tree_names: choice}) do
      {:ok, user} -> {:noreply, socket |> assign(current_user: user) |> reload_names()}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "Couldn't save that.")}
    end
  end

  def handle_event("toggle_organise", _params, socket) do
    if socket.assigns.can_write do
      {:noreply, assign(socket, organising: not socket.assigns.organising)}
    else
      {:noreply, socket}
    end
  end

  @doc false
  # A drag finished in the tree. `into` names the container it was dropped in
  # — `folder:4`, `folder:` for the top of the wiki, or `page:7` for a page's
  # children — and `before` is what it was dropped above, or nil for last.
  #
  # The two axes stay apart even here: dropping a page in a folder files it
  # and takes it out of whatever page it was part of; dropping it on a page
  # makes it part of that page and files it where that page is filed.
  def handle_event("tree_move", params, socket) do
    %{"kind" => kind, "id" => id, "into" => into} = params
    before = blank_to_nil(params["before"])

    if socket.assigns.can_write do
      {:noreply,
       socket
       |> tree_move(kind, id, into, before)
       |> sorted_drop_note(kind, into, before)
       |> load_tree()
       |> assign_current()}
    else
      {:noreply, put_flash(socket, :error, "You can't write on this board.")}
    end
  end

  def handle_event("new_folder", params, socket) do
    if socket.assigns.can_write do
      parent = folder_from(socket.assigns.board, params["parent"])
      {:noreply, assign(socket, folder_modal: %{folder: nil, parent: parent, name: ""})}
    else
      {:noreply, socket}
    end
  end

  # A folder is only ever acted on where the reader can write: this board,
  # or another board of its vault (`tree_item/2`), never one named by an id
  # alone.
  def handle_event("rename_folder", %{"id" => id}, socket) do
    case tree_item(socket, "folder:#{id}") do
      %Folder{} = folder ->
        {:noreply,
         assign(socket,
           folder_modal: %{
             folder: folder,
             parent: folder.parent_id && Wiki.get_folder(folder.parent_id),
             name: folder.name
           }
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_folder_modal", _params, socket),
    do: {:noreply, assign(socket, folder_modal: nil)}

  ## Events: sharing a page (#813) ---------------------------------------------
  #
  # Only a writer on the item's board shares it. Somebody whose access is a
  # grant on the page itself reads, or edits, what they were given, and does
  # not hand it on: the menus leave Share… out for them, and every event
  # checks again rather than trusting that.

  def handle_event("share_item", %{"kind" => kind, "id" => id}, socket) do
    case share_item(socket, kind, id) do
      {:ok, item} ->
        groups = Slipdock.Accounts.list_groups(socket.assigns.current_user)
        {:noreply, assign(socket, share_modal: share_state(kind, item, groups, 0))}

      :error ->
        {:noreply, put_flash(socket, :error, "You can't share that.")}
    end
  end

  def handle_event("share", %{"resource" => kind, "level" => _} = params, socket) do
    with %{kind: ^kind, item: item, groups: groups, key: key} <- socket.assigns.share_modal,
         {:ok, item} <- share_item(socket, kind, item.id),
         {:ok, _} <-
           SlipdockWeb.BoardLive.Sharing.share(item, params, groups, socket.assigns.current_user) do
      {:noreply,
       socket
       |> assign(share_modal: share_state(kind, item, groups, key + 1))
       |> after_share()}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, put_flash(socket, :error, "You can't share that.")}
    end
  end

  def handle_event("revoke_grant", %{"id" => id, "resource" => kind}, socket) do
    with %{kind: ^kind, item: item, groups: groups, key: key} <- socket.assigns.share_modal,
         {:ok, item} <- share_item(socket, kind, item.id),
         {:ok, _} <- SlipdockWeb.BoardLive.Sharing.revoke(id, item) do
      {:noreply,
       socket
       |> assign(share_modal: share_state(kind, item, groups, key))
       |> after_share()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't remove that access.")}
    end
  end

  def handle_event("close_share", _params, socket),
    do: {:noreply, assign(socket, share_modal: nil)}

  def handle_event("save_folder", %{"name" => name} = params, socket) do
    modal = socket.assigns.folder_modal
    parent_id = blank_to_nil(params["parent_id"])
    # A folder being renamed was checked when its dialog opened; a new one
    # goes on this board, which takes a writer.
    board_id = if modal && modal.folder, do: modal.folder.board_id, else: socket.assigns.board.id

    result =
      folder_refusal(modal, parent_id, board_id, socket.assigns.can_write) ||
        write_folder(socket.assigns.board, modal, name, parent_id, params)

    case result do
      {:ok, folder} ->
        {:noreply,
         socket
         |> assign(folder_modal: nil)
         |> put_flash(:info, "Folder “#{folder.name}” saved.")
         |> load_tree()}

      {:error, status, message} when status in [:unprocessable_entity, :forbidden] ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "That folder couldn't be saved.")}
    end
  end

  # Deleting a folder asks what to do with what is in it rather than guessing,
  # because the two answers are not close: one loses nothing, the other loses
  # pages. An empty folder is not worth a question and goes at once.
  def handle_event("ask_delete_folder", %{"id" => id}, socket) do
    case tree_item(socket, "folder:#{id}") do
      %Folder{} = folder -> {:noreply, ask_delete_folder(socket, folder)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_folder_delete", _params, socket),
    do: {:noreply, assign(socket, folder_delete: nil)}

  def handle_event("delete_folder", params, socket) do
    strategy = if params["how"] == "purge", do: :purge, else: :keep

    folder = folder_to_delete(socket, params["id"])

    # Everything in it, history and all, is the owner's purge (#733), as it
    # is over the API and as deleting a single page for good is.
    cond do
      strategy == :purge and not socket.assigns.can_manage ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Only the board's owner can delete a folder with everything in it."
         )}

      socket.assigns.can_write and folder ->
        {:noreply, delete_folder(socket, folder, strategy)}

      true ->
        {:noreply, put_flash(socket, :error, "That folder couldn't be deleted.")}
    end
  end

  # Filing the page that is open, from its own header.
  def handle_event("file_page", params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, filed} <- Wiki.file_page(page, folder_from(socket.assigns.board, params["folder"])) do
      note =
        case filed.folder_id && Wiki.get_folder(filed.folder_id) do
          nil -> "Taken out of its folder."
          folder -> "Filed in #{Wiki.folder_path(folder)}."
        end

      {:noreply, socket |> put_flash(:info, note) |> reload(filed)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be filed.")}
    end
  end

  # How a folder, or the top of a board, orders its pages (R11.9).
  def handle_event("set_tree_sort", %{"key" => key, "sort" => sort}, socket) do
    target =
      case key do
        "root" -> drop_target(socket, "folder:")
        other -> drop_target(socket, other)
      end

    with {:folder, board, folder} <- target,
         {:ok, result} <- Wiki.set_tree_sort(board, folder, sort) do
      socket =
        if is_nil(folder) and board.id == socket.assigns.board.id,
          do: assign(socket, board: result),
          else: socket

      {:noreply, load_tree(socket)}
    else
      {:error, _status, message} -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, put_flash(socket, :error, "That can't be sorted.")}
    end
  end

  # "New drawing" (R11.10): an Excalidraw drawing, as Obsidian's plugin
  # writes one, in the folder the menu was opened on.
  def handle_event("new_drawing", %{"key" => key}, socket) do
    with {:folder, board, folder} <-
           drop_target(socket, if(key == "root", do: "folder:", else: key)),
         {:ok, page} <-
           Slipdock.Wiki.Drawings.create(board, folder,
             user: socket.assigns.current_user,
             via: "web"
           ) do
      # Straight into the editor: an empty drawing is there to be drawn on.
      {:noreply, push_navigate(socket, to: ~p"/drawings/page/#{page.id}")}
    else
      _ -> {:noreply, put_flash(socket, :error, "A drawing couldn't be made there.")}
    end
  end

  # The tree as a drawer, on a screen too narrow to keep it beside the page.
  def handle_event("toggle_tree_drawer", _params, socket),
    do: {:noreply, update(socket, :tree_drawer, &(not &1))}

  def handle_event("close_tree_drawer", _params, socket),
    do: {:noreply, assign(socket, tree_drawer: false)}

  # A file clicked in the tree or in a page opens in the page's place, beside
  # the tree (#768, #773); X or Escape brings the page back. The WikiFileOpen
  # hook sends it; the link itself still goes to `/files/:id` for a new tab.
  def handle_event("open_file", %{"id" => id}, socket) do
    case SlipdockWeb.FileViewer.load(socket.assigns.current_user, id) do
      {:ok, shown} ->
        {:noreply, assign(socket, file_shown: shown)}

      :error ->
        {:noreply, put_flash(socket, :error, "That file isn't there, or isn't yours to see.")}
    end
  end

  def handle_event("close_file", _params, socket),
    do: {:noreply, assign(socket, file_shown: nil)}

  # The search box reads names; this has it read the pages' words too.
  def handle_event("toggle_tree_contents", _params, socket),
    do: {:noreply, socket |> update(:tree_contents, &(not &1)) |> load_tree()}

  ## Events: the filter bar ---------------------------------------------------
  #
  # The same events the board's toolbar sends, because it is the same
  # toolbar: a page answers every one of these filters (see `Slipdock.Filters`).

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, put_filter(socket, :q, q)}

  def handle_event("filter_tag", %{"id" => id}, socket) do
    case Params.id(id) do
      nil ->
        {:noreply, socket}

      id ->
        tags = socket.assigns.filters.tags

        {:noreply,
         put_filter(
           socket,
           :tags,
           if(Enum.member?(tags, id), do: tags -- [id], else: [id | tags])
         )}
    end
  end

  def handle_event("filter_priority", %{"priority" => p}, socket),
    do: {:noreply, toggle_filter(socket, :priority, p)}

  def handle_event("filter_flag", %{"flag" => f}, socket),
    do: {:noreply, toggle_filter(socket, :flag, f)}

  def handle_event("filter_due", %{"due" => d}, socket),
    do: {:noreply, toggle_filter(socket, :due, d)}

  def handle_event("toggle_hide_completed", _params, socket),
    do: {:noreply, put_filter(socket, :hide_completed, not socket.assigns.filters.hide_completed)}

  def handle_event("clear_filters", _params, socket),
    do: {:noreply, socket |> assign(filters: Slipdock.Filters.empty()) |> load_tree()}

  # Whether the tree wears folders' and pages' icons and colours (#792).
  def handle_event("toggle_tree_icons", _params, socket) do
    if socket.assigns.can_write do
      {:ok, board} =
        Wiki.set_tree_icons(socket.assigns.board, not socket.assigns.board.wiki_tree_icons)

      {:noreply, socket |> assign(board: board) |> load_tree()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_show", %{"what" => what}, socket)
      when what in ~w(drafts templates archived) do
    key = String.to_existing_atom(what)
    show = Map.update!(socket.assigns.show, key, &(not &1))
    {:noreply, socket |> assign(show: show) |> load_tree()}
  end

  # Why the folder dialog's save is refused, or nil when it may go ahead.
  defp folder_refusal(modal, parent_id, board_id, can_write) do
    cond do
      is_nil(modal) or (is_nil(modal.folder) and not can_write) ->
        {:error, :forbidden, "You can't write on this board."}

      not (is_nil(parent_id) or match?(%Folder{board_id: ^board_id}, Wiki.get_folder(parent_id))) ->
        {:error, :unprocessable_entity, "A folder can only go inside a folder on its own board."}

      true ->
        nil
    end
  end

  defp write_folder(board, %{folder: nil} = modal, name, parent_id, params) do
    Wiki.create_folder(board, %{
      "name" => name,
      "parent_id" => parent_id || (modal.parent && modal.parent.id),
      "icon" => params["icon"],
      "color" => params["color"]
    })
  end

  defp write_folder(_board, modal, name, parent_id, params) do
    Wiki.update_folder(
      modal.folder,
      Map.merge(
        %{"name" => name, "parent_id" => parent_id},
        Map.take(params, ["icon", "color"])
      )
    )
  end

  # The folder Delete acts on: the one its dialog asked about, or one named.
  defp folder_to_delete(socket, nil),
    do: socket.assigns.folder_delete && socket.assigns.folder_delete.folder

  defp folder_to_delete(socket, id), do: tree_item(socket, "folder:#{id}")

  # An empty folder is not worth a question and goes at once.
  defp ask_delete_folder(socket, folder) do
    case Wiki.folder_contents_count(folder) do
      %{folders: 0, pages: 0} ->
        delete_folder(socket, folder, :keep)

      counts ->
        assign(socket,
          folder_modal: nil,
          folder_delete: %{folder: folder, counts: counts, path: Wiki.folder_path(folder)}
        )
    end
  end

  # What "tree_load" sends when no filter is on: the levels asked for (every
  # one, just those, or those with the root and the way to what is being
  # looked at), the ones reached through a placement apart.
  defp tree_load_nodes(socket, params, kept) do
    scope = socket.assigns.tree_scope
    root = socket.assigns.tree_root

    keys =
      cond do
        params["all"] == true -> [root | all_container_keys(socket, scope)]
        params["only"] == true -> keys_param(params["keys"])
        true -> [root | keys_param(params["keys"] || kept) ++ socket.assigns.tree_reveal]
      end

    {via, plain} =
      keys
      |> Enum.uniq()
      |> Enum.take(@tree_max_keys)
      |> Enum.split_with(&match?({:ok, _, _}, Tree.split_via(&1)))

    load_nodes(socket, scope, plain, through(socket, params, root)) ++ via_nodes(socket, via)
  end
end
