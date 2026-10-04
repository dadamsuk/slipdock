defmodule SlipdockWeb.WikiLive.Index do
  @moduledoc """
  A board's wiki: the tree of pages down the side, one page in the middle.

  One LiveView covers reading, writing and history because they share the
  tree and the breadcrumb, and a document is a thing you flip between those
  three states on without losing your place.

  The editor is raw Markdown with a preview beside it — deliberately, and
  for good: the source has to stay diffable, greppable and identical to what
  an agent reads and writes over the API. A rich-text layer would have to
  round-trip every extension losslessly, which is exactly where editors of
  that kind break.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.ItemComponents
  import SlipdockWeb.FolderPicker
  import SlipdockWeb.SlipdockComponents, only: [view_tabs: 1, filter_menu: 1, modal: 1]

  alias Slipdock.{Access, Boards, Fields, Votes, Wiki}
  alias Slipdock.Boards.Attachment
  alias Slipdock.Palette
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.Wiki.Renderer

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    board = Boards.get_board!(id)
    perm = Access.board_permission(socket.assigns.current_user, board)

    if Access.can_read?(perm) do
      if connected?(socket), do: Wiki.subscribe(board.id)

      {:ok,
       socket
       |> assign(
         board: board,
         perm: perm,
         can_write: Access.can_write?(perm),
         can_manage: perm == :owner,
         page: nil,
         revision: nil,
         form: nil,
         preview: "",
         conflict: nil,
         base_hash: nil,
         new_parent: nil,
         new_column: nil,
         new_folder: nil,
         # Filing (see `Slipdock.Wiki.Folder`): the folder tree down the side,
         # the pages filed nowhere, and which folders the reader has shut.
         folders: [],
         unfiled: [],
         all_folders: [],
         folder_outline: [],
         collapsed: MapSet.new(),
         # Organise mode: the tree becomes drag-and-drop, and only then.
         # Dragging by default would make every mis-aimed click a filing
         # change, in the one place a reader is trying to read.
         organising: false,
         folder_modal: nil,
         # The folder being looked *at*, when the index is scoped to one.
         folder: nil,
         # A folder whose deletion is being decided: keep what is in it, or
         # take it all with it (see `Slipdock.Wiki.Folders.delete/2`).
         folder_delete: nil,
         html: "",
         columns: [],
         backlinks: [],
         children: [],
         # The cards this page is about, and the picker for adding another.
         cards: [],
         card_query: "",
         card_results: [],
         tags: [],
         wanted: [],
         diff: [],
         revisions: [],
         page_jumps: [],
         fields_board: nil,
         # Bumped to clear a form after it submits, as the card panel does.
         form_key: 0,
         # The board's own filter bar. A page answers every one of these now
         # that it carries the card's facets, so the wiki keeps the bar the
         # card views have rather than inventing a second one.
         filters: Slipdock.Filters.empty(),
         filtering: false,
         shown: 0,
         hidden: 0,
         # What the tree lists at all, as opposed to what the filters narrow.
         show: %{drafts: true, templates: true, archived: false},
         marks: Slipdock.Favourites.marks(socket.assigns.current_user)
       )
       |> allow_upload(:page_image,
         accept: ~w(.png .jpg .jpeg .gif .webp image/png image/jpeg image/gif image/webp),
         max_entries: 5,
         max_file_size: 10_000_000,
         auto_upload: true,
         progress: &handle_upload/3
       )
       |> load_tree()}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have access to that board.")
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load_tree(socket) do
    %{board: board, can_write: can_write, filters: filters, show: show} = socket.assigns

    # What the tree is drawn from, before the filter bar narrows it. A draft
    # is only ever listed for someone who could have written it.
    all = Wiki.list_pages(board, list_opts(can_write, show))
    all_folders = Wiki.folders(board)

    # The search box searches the filing as well as what is filed: a folder
    # whose name matches is a hit, and everything in it comes with it, because
    # "where are the design decisions" is the question somebody typing the
    # name of a folder is asking. Everything else is pruned away — a folder
    # with nothing matching in it is noise at that moment.
    hit_folders = matching_folders(all_folders, filters.q)

    shown =
      Enum.filter(all, fn page ->
        Slipdock.Filters.matches?(page, filters) or MapSet.member?(hit_folders, page.folder_id)
      end)

    assign(socket,
      tree: Wiki.tree_from(shown),
      folders:
        all_folders
        |> Wiki.folder_tree_from(shown)
        |> prune_folders(filters.q, hit_folders),
      unfiled: Wiki.unfiled(shown),
      all_folders: all_folders,
      # Paths and depths worked out once, in memory, for every picker on the
      # page (see `SlipdockWeb.FolderPicker`).
      folder_outline: Slipdock.Wiki.Folders.outline(all_folders),
      recent: shown |> Enum.sort_by(& &1.updated_at, {:desc, DateTime}) |> Enum.take(8),
      wanted: Wiki.wanted(board),
      shown: length(shown),
      hidden: length(all) - length(shown),
      filtering: Slipdock.Filters.any?(filters)
    )
  end

  # Every folder whose name matches, and everything beneath it: filing is a
  # path, so matching "Design" means its Decisions are in the answer too.
  defp matching_folders(_folders, ""), do: MapSet.new()

  defp matching_folders(folders, q) do
    term = String.downcase(String.trim(q))

    if term == "" do
      MapSet.new()
    else
      hit =
        folders
        |> Slipdock.Wiki.Folders.outline()
        |> Enum.filter(&String.contains?(String.downcase(&1.folder.name), term))

      prefixes = Enum.map(hit, & &1.path)

      folders
      |> Slipdock.Wiki.Folders.outline()
      |> Enum.filter(fn %{path: path} ->
        Enum.any?(prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/")))
      end)
      |> MapSet.new(& &1.folder.id)
    end
  end

  # While a search is running, a folder stays only if it is a hit itself or
  # has something matching inside it.
  defp prune_folders(nodes, q, hit_folders) do
    if String.trim(q) == "" do
      nodes
    else
      nodes
      |> Enum.map(&%{&1 | children: prune_folders(&1.children, q, hit_folders)})
      |> Enum.reject(fn node ->
        node.pages == [] and node.children == [] and
          not MapSet.member?(hit_folders, node.folder.id)
      end)
    end
  end

  defp list_opts(can_write, show) do
    [
      status: if(can_write and show.drafts, do: nil, else: "published"),
      template: if(show.templates, do: nil, else: false),
      archived: if(can_write and show.archived, do: :all, else: false)
    ]
    |> Enum.reject(&match?({_, nil}, &1))
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # `folder` is the index's own state; every other action clears it rather
    # than inheriting the last one looked at.
    {:noreply, apply_action(assign(socket, folder: nil), socket.assigns.live_action, params)}
  end

  # The index does double duty: the whole wiki, or one folder of it with
  # `?folder=`. A query parameter rather than a path of its own, so a folder
  # named "new" or "edit" can never shadow a page's routes.
  defp apply_action(socket, :index, params) do
    folder = folder_from(socket.assigns.board, params["folder"])

    title =
      if folder,
        do: "#{Wiki.folder_path(folder)} · #{socket.assigns.board.name} wiki",
        else: "#{socket.assigns.board.name} · Wiki"

    assign(socket, page: nil, revision: nil, folder: folder, page_title: title)
  end

  defp apply_action(socket, :new, params) do
    if socket.assigns.can_write do
      parent = parent_from(socket.assigns.board, params["parent"])
      # "Add a page…" at the foot of a list comes straight here with the list
      # it was pressed in, and the page is placed there when it is saved.
      column = column_from(socket.assigns.board, params["column"])
      # "New page" pressed inside a folder files it there without asking.
      folder = folder_from(socket.assigns.board, params["folder"])

      blank = %Page{
        board_id: socket.assigns.board.id,
        parent_id: parent && parent.id,
        folder_id: folder && folder.id,
        title: params["title"] || "",
        # "Write this into a doc" from a board view arrives with the query
        # block already written, which is how anyone authors one of these
        # without learning the syntax.
        body: params["block"] || ""
      }

      socket
      |> assign(
        page: nil,
        revision: nil,
        new_parent: parent,
        new_column: column,
        new_folder: folder
      )
      |> assign(page_title: "New page")
      |> assign_form(blank)
      |> assign(preview: render_body(socket, nil, blank.body))
    else
      refuse(socket, "You can't write on this board.")
    end
  end

  defp apply_action(socket, action, %{"slug" => slug} = params) do
    case Wiki.find_page(socket.assigns.board, slug) do
      {:ok, page} ->
        level = Access.page_permission(socket.assigns.current_user, page)

        if Wiki.visible?(page, level) do
          socket
          |> assign_page(page)
          |> assign(page_title: page.title)
          |> apply_page_action(action, params)
        else
          refuse(socket, "That page doesn't exist.")
        end

      _ ->
        socket
        |> assign(page: nil)
        |> assign(page_title: "Page not found")
    end
  end

  defp apply_page_action(socket, :edit, _params) do
    if socket.assigns.can_write do
      page = socket.assigns.page

      # The hash the editor opened against, held apart from `@page` on
      # purpose: a live update from someone else must not quietly re-base the
      # save it is meant to catch.
      socket
      |> assign_form(page)
      |> assign(
        preview: render_body(socket, page, page.body),
        conflict: nil,
        revision: nil,
        base_hash: page.content_hash
      )
    else
      refuse(socket, "You can't edit this page.")
    end
  end

  defp apply_page_action(socket, :revision, %{"rev" => rev}) do
    case Wiki.get_revision(socket.assigns.page, rev) do
      {:ok, revision} ->
        previous = Wiki.previous_revision(revision)
        before = if previous, do: previous.body, else: ""
        assign(socket, revision: revision, diff: Wiki.diff(before, revision.body))

      _ ->
        socket |> put_flash(:error, "No such revision.") |> assign(revision: nil)
    end
  end

  defp apply_page_action(socket, :history, _params),
    do: assign(socket, revision: nil, revisions: Wiki.list_revisions(socket.assigns.page))

  defp apply_page_action(socket, _action, _params) do
    page = socket.assigns.page

    board = Boards.get_board!(socket.assigns.board.id)

    socket
    |> assign_page(page)
    |> assign(
      revision: nil,
      # The board's lists, for the "put it in a list" menu.
      columns: board.columns,
      # The board's custom fields, which a page carries values for.
      fields_board: board,
      # The card contents this page carries (see `Slipdock.Boards.Owned`).
      html: render_body(socket, page, page.body),
      backlinks: Wiki.backlinks(page, socket.assigns.current_user),
      children: Wiki.children(page),
      cards: card_links(page),
      card_query: "",
      card_results: [],
      tags: Wiki.tags(page)
    )
  end

  # The cards this page is about: pinned first, then by how often the prose
  # mentions them. A page written up from a card is pinned to it, which is
  # what keeps the two findable from each other after the stub text is gone.
  # The folders a page is filed under, outermost first.
  defp folder_crumbs(%Page{} = page) do
    case page.folder_id && Wiki.get_folder(page.folder_id) do
      nil -> []
      folder -> Wiki.folder_ancestors(folder) ++ [folder]
    end
  end

  defp filed_in(%Page{} = page) do
    case folder_crumbs(page) do
      [] -> ""
      crumbs -> Enum.map_join(crumbs, "/", & &1.name)
    end
  end

  defp card_links(%Page{} = page) do
    page
    |> Wiki.outgoing_links()
    |> Enum.filter(&(&1.kind == "card" and not is_nil(&1.target_card)))
  end

  # A page always reaches the view with everything it draws loaded: its
  # assignee, and the card contents it carries (see `Slipdock.Boards.Owned`).
  # An unloaded association here is a crash in a component, not a blank.
  defp assign_page(socket, %Page{} = page),
    do: assign(socket, page: Slipdock.Repo.preload(page, Wiki.board_preloads(), force: true))

  ## Events: the card contents a page carries ---------------------------------
  #
  # A page holds comments, status updates, a checklist, web links, custom
  # field values and votes in the same tables a card does (see
  # `Slipdock.Boards.Owned`), so these are the card panel's events with the
  # page as the subject. Every one is refused without write access, the way
  # everything else on this view is.

  defp contents_event(socket, fun) do
    if socket.assigns.can_write and socket.assigns.page do
      fun.(socket.assigns.page)
      {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload_page()}
    else
      {:noreply, socket}
    end
  end

  defp reload_page(socket) do
    case socket.assigns.page do
      %Page{id: id} ->
        assign_page(socket, Wiki.get_page!(id))

      _ ->
        socket
    end
  end

  defp put_filter(socket, key, value),
    do: socket |> assign(filters: Map.put(socket.assigns.filters, key, value)) |> load_tree()

  # Clicking the filter that is already on turns it off.
  defp toggle_filter(socket, key, value) do
    current = Map.get(socket.assigns.filters, key)
    put_filter(socket, key, if(current == value, do: nil, else: value))
  end

  defp column_from(_board, nil), do: nil
  defp column_from(_board, ""), do: nil

  defp column_from(board, ref),
    do: Enum.find(Boards.get_board!(board.id).columns, &(to_string(&1.id) == to_string(ref)))

  defp parent_from(_board, nil), do: nil
  defp parent_from(_board, ""), do: nil

  defp parent_from(board, ref) do
    case Wiki.find_page(board, ref) do
      {:ok, page} -> page
      _ -> nil
    end
  end

  defp folder_from(_board, ref) when ref in [nil, "", "none"], do: nil

  defp folder_from(board, ref) do
    case Wiki.find_folder(board, ref) do
      {:ok, folder} -> folder
      _ -> nil
    end
  end

  defp refuse(socket, message) do
    socket
    |> put_flash(:error, message)
    |> push_patch(to: ~p"/boards/#{socket.assigns.board}/wiki")
  end

  defp assign_form(socket, %Page{} = page) do
    assign(socket, form: to_form(Wiki.change_page(page, %{})), editing: page)
  end

  # Rendering needs the page (for `[[!toc]]` and friends), the board (to read
  # unqualified references against) and the reader (so a chip for a card they
  # cannot open degrades to plain text).
  defp render_body(socket, page, body) do
    Renderer.to_html(body,
      page: page,
      board: socket.assigns.board,
      as: socket.assigns.current_user
    )
  end

  ## Uploads ------------------------------------------------------------------
  #
  # Pasting an image into the editor is the same flow a card description has:
  # the hook drops a placeholder at the cursor, the file goes up, and the
  # server sends back the Markdown to put in its place.

  defp handle_upload(name, entry, socket) do
    page = socket.assigns.page

    cond do
      not entry.done? ->
        {:noreply, socket}

      is_nil(page) or not socket.assigns.can_write ->
        # A brand-new page has nowhere to hang a file yet; save it first.
        {:noreply,
         socket
         |> cancel_upload(name, entry.ref)
         |> push_event("image_failed", %{upload: "page_image"})
         |> put_flash(:error, "Save the page before adding images to it.")}

      true ->
        meta = %{
          filename: entry.client_name,
          content_type: entry.client_type,
          size: entry.client_size
        }

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, Wiki.add_attachment(page, meta, path)}
          end)

        {:noreply, uploaded(socket, result)}
    end
  end

  defp uploaded(socket, {:ok, %Attachment{} = attachment}) do
    push_event(socket, "image_uploaded", %{
      upload: "page_image",
      markdown: "![#{attachment.filename}](#{Boards.attachment_url(attachment)})"
    })
  end

  defp uploaded(socket, _other) do
    socket
    |> put_flash(:error, "That image could not be stored.")
    |> push_event("image_failed", %{upload: "page_image"})
  end

  @upload_placeholder "![Uploading image…]()"

  # The placeholder is the browser's, not the document's: it must never be saved.
  defp strip_placeholder(nil), do: nil

  defp strip_placeholder(text),
    do:
      text
      |> String.replace(@upload_placeholder <> "\n", "")
      |> String.replace(@upload_placeholder, "")

  ## Events -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"page" => params}, socket) do
    params = Map.update(params, "body", nil, &strip_placeholder/1)
    changeset = Wiki.change_page(socket.assigns.editing, params)

    {:noreply,
     socket
     |> assign(form: to_form(Map.put(changeset, :action, :validate)))
     |> assign(preview: render_body(socket, socket.assigns.page, params["body"] || ""))}
  end

  def handle_event("save", %{"page" => params} = all, socket) do
    params = Map.update(params, "body", nil, &strip_placeholder/1)

    if socket.assigns.can_write do
      {:noreply, save(socket, socket.assigns.page, params, all["message"])}
    else
      {:noreply, put_flash(socket, :error, "You can't write on this board.")}
    end
  end

  def handle_event("archive", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, _} <- Wiki.archive_page(page) do
      {:noreply,
       socket
       |> put_flash(:info, "Archived “#{page.title}”.")
       |> push_navigate(to: ~p"/boards/#{socket.assigns.board}/wiki")}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be archived.")}
    end
  end

  def handle_event("restore", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, page} <- Wiki.unarchive_page(page) do
      {:noreply, socket |> put_flash(:info, "Restored “#{page.title}”.") |> reload(page)}
    else
      {:error, %Ecto.Changeset{} = refused} ->
        {:noreply, put_flash(socket, :error, Slipdock.Quota.refusal_message(refused))}

      _ ->
        {:noreply, put_flash(socket, :error, "That page couldn't be restored.")}
    end
  end

  # The purge, as opposed to archiving: the owner's only, and the one thing on
  # this view that cannot be undone. Children are left behind at the top of
  # the tree rather than going silently with it, which is why the warning says
  # how many there are (see `Slipdock.Wiki.delete_page/1`).
  def handle_event("delete_page", _params, socket) do
    with true <- socket.assigns.can_manage,
         %Page{} = page <- socket.assigns.page,
         {:ok, _} <- Wiki.delete_page(page) do
      {:noreply,
       socket
       |> put_flash(:info, "Deleted “#{page.title}” for good.")
       |> push_navigate(to: ~p"/boards/#{socket.assigns.board}/wiki")}
    else
      false -> {:noreply, put_flash(socket, :error, "Only the board's owner can delete a page.")}
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be deleted.")}
    end
  end

  def handle_event("revert", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         revision when not is_nil(revision) <- socket.assigns.revision,
         {:ok, page} <-
           Wiki.revert_page(page, revision, user: socket.assigns.current_user, via: "web") do
      {:noreply,
       socket
       |> put_flash(:info, "Put “#{page.title}” back to that version.")
       |> push_navigate(to: ~p"/boards/#{socket.assigns.board}/wiki/#{page.slug}")}
    else
      _ -> {:noreply, put_flash(socket, :error, "That version couldn't be restored.")}
    end
  end

  # Publishing answers the page's live queries now and keeps the answers: an
  # anonymous reader has no permissions for a query to run with.
  def handle_event("publish", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, published} <- Wiki.publish(page, user: socket.assigns.current_user) do
      {:noreply,
       socket
       |> put_flash(:info, "Published. Anyone with the link can read it.")
       |> reload(published)}
    else
      {:error, _, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "That page couldn't be published.")}
    end
  end

  def handle_event("unpublish", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, withdrawn} <- Wiki.unpublish(page) do
      {:noreply, socket |> put_flash(:info, "Link withdrawn.") |> reload(withdrawn)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That link couldn't be withdrawn.")}
    end
  end

  # Putting a page on the board is a second, optional axis: it stays exactly
  # where it is in the wiki tree either way.
  ## Events: the filter bar ---------------------------------------------------
  #
  # The same events the board's toolbar sends, because it is the same
  # toolbar: a page answers every one of these filters (see `Slipdock.Filters`).

  ## Events: the cards a page is about ---------------------------------------
  #
  # A page and a card find each other through a pinned link, not through the
  # prose: the stub "Write it up" leaves behind is meant to be replaced, and
  # replacing it must not detach the page (see `Slipdock.Wiki.Links.reconcile/1`).

  def handle_event("card_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(card_query: q) |> assign_card_results()}
  end

  def handle_event("attach_card", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         %{} = card <- Boards.get_card(String.to_integer(id)),
         {:ok, _} <- Wiki.pin(page, {:card, card}) do
      {:noreply,
       socket
       |> put_flash(:info, "This page is now the doc for “#{card.title}”.")
       |> assign(card_query: "", card_results: [])
       |> reload(page)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That card couldn't be attached.")}
    end
  end

  def handle_event("toggle_pin_card", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         %{} = card <- Boards.get_card(String.to_integer(id)),
         link <- Enum.find(socket.assigns.cards, &(&1.target_card_id == card.id)),
         {:ok, _} <- Wiki.pin(page, {:card, card}, not (link && link.pinned)) do
      {:noreply, reload(socket, page)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That pin couldn't be changed.")}
    end
  end

  # Detaching only ever removes a link the prose does not make. A card the
  # body names stays listed, because the page really does talk about it.
  def handle_event("detach_card", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         %{} = card <- Boards.get_card(String.to_integer(id)),
         {:ok, _} <- Wiki.unlink(page, {:card, card}) do
      {:noreply, reload(socket, page)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That card couldn't be detached.")}
    end
  end

  ## Events: folders ---------------------------------------------------------
  #
  # Filing, not writing. Every one of these is refused without write access,
  # and none of them can lose a page: see `Slipdock.Wiki.Folders`.

  def handle_event("toggle_folder", %{"id" => id}, socket) do
    id = String.to_integer(id)
    collapsed = socket.assigns.collapsed

    {:noreply,
     assign(socket,
       collapsed:
         if(MapSet.member?(collapsed, id),
           do: MapSet.delete(collapsed, id),
           else: MapSet.put(collapsed, id)
         )
     )}
  end

  # Organise mode opens every folder: a shut folder is not a place anything
  # can be dropped, and a target you cannot see is not a target.
  def handle_event("toggle_organise", _params, socket) do
    if socket.assigns.can_write do
      organising = not socket.assigns.organising

      {:noreply,
       assign(socket,
         organising: organising,
         collapsed: if(organising, do: MapSet.new(), else: socket.assigns.collapsed)
       )}
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
      {:noreply, socket |> tree_move(kind, id, into, before) |> load_tree()}
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

  def handle_event("rename_folder", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %{} = folder <- Wiki.get_folder(String.to_integer(id)) do
      {:noreply,
       assign(socket,
         folder_modal: %{
           folder: folder,
           parent: folder.parent_id && Wiki.get_folder(folder.parent_id),
           name: folder.name
         }
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_folder_modal", _params, socket),
    do: {:noreply, assign(socket, folder_modal: nil)}

  def handle_event("save_folder", %{"name" => name} = params, socket) do
    modal = socket.assigns.folder_modal
    parent_id = blank_to_nil(params["parent_id"])

    result =
      case modal && modal.folder do
        nil ->
          Wiki.create_folder(socket.assigns.board, %{
            "name" => name,
            "parent_id" => parent_id || (modal && modal.parent && modal.parent.id)
          })

        folder ->
          Wiki.update_folder(folder, %{"name" => name, "parent_id" => parent_id})
      end

    case result do
      {:ok, folder} ->
        {:noreply,
         socket
         |> assign(folder_modal: nil)
         |> put_flash(:info, "Folder “#{folder.name}” saved.")
         |> load_tree()}

      {:error, :unprocessable_entity, message} ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "That folder couldn't be saved.")}
    end
  end

  # Deleting a folder asks what to do with what is in it rather than guessing,
  # because the two answers are not close: one loses nothing, the other loses
  # pages. An empty folder is not worth a question and goes at once.
  def handle_event("ask_delete_folder", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %{} = folder <- Wiki.get_folder(String.to_integer(id)) do
      case Wiki.folder_contents_count(folder) do
        %{folders: 0, pages: 0} ->
          {:noreply, delete_folder(socket, folder, :keep)}

        counts ->
          {:noreply,
           assign(socket,
             folder_modal: nil,
             folder_delete: %{folder: folder, counts: counts, path: Wiki.folder_path(folder)}
           )}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_folder_delete", _params, socket),
    do: {:noreply, assign(socket, folder_delete: nil)}

  def handle_event("delete_folder", params, socket) do
    strategy = if params["how"] == "purge", do: :purge, else: :keep

    folder =
      case params["id"] do
        nil -> socket.assigns.folder_delete && socket.assigns.folder_delete.folder
        id -> Wiki.get_folder(String.to_integer(id))
      end

    if socket.assigns.can_write and folder do
      {:noreply, delete_folder(socket, folder, strategy)}
    else
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

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, put_filter(socket, :q, q)}

  def handle_event("filter_tag", %{"id" => id}, socket) do
    id = String.to_integer(id)
    tags = socket.assigns.filters.tags
    {:noreply, put_filter(socket, :tags, if(id in tags, do: tags -- [id], else: [id | tags]))}
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

  def handle_event("toggle_show", %{"what" => what}, socket)
      when what in ~w(drafts templates archived) do
    key = String.to_existing_atom(what)
    show = Map.update!(socket.assigns.show, key, &(not &1))
    {:noreply, socket |> assign(show: show) |> load_tree()}
  end

  def handle_event("add_check", %{"text" => text}, socket) do
    if String.trim(text) == "",
      do: {:noreply, socket},
      else: contents_event(socket, &Boards.add_checklist_item(&1, String.trim(text)))
  end

  def handle_event("toggle_check", %{"id" => id}, socket),
    do:
      contents_event(socket, fn page ->
        if item = Boards.get_checklist_item(page, id), do: Boards.toggle_checklist_item(item)
      end)

  def handle_event("delete_check", %{"id" => id}, socket),
    do:
      contents_event(socket, fn page ->
        if item = Boards.get_checklist_item(page, id), do: Boards.delete_checklist_item(item)
      end)

  def handle_event("add_comment", %{"body" => body}, socket) do
    if String.trim(body) == "",
      do: {:noreply, socket},
      else: contents_event(socket, &Boards.add_comment(&1, String.trim(body)))
  end

  # The page's own view has no paste-an-image upload on the comment box, so
  # the change event the shared form sends has nothing to do here.
  def handle_event("comment_change", _params, socket), do: {:noreply, socket}

  def handle_event("delete_comment", %{"id" => id}, socket) do
    contents_event(socket, fn page ->
      if Enum.any?(page.comments, &(to_string(&1.id) == id)),
        do: Boards.delete_comment(String.to_integer(id))
    end)
  end

  def handle_event("add_status_update", %{"health" => health} = params, socket) do
    user = socket.assigns.current_user

    contents_event(socket, fn page ->
      Boards.add_status_update(page, user, %{"health" => health, "body" => params["body"]})
    end)
  end

  def handle_event("delete_status_update", %{"id" => id}, socket) do
    contents_event(socket, fn page ->
      if Enum.any?(page.status_updates, &(to_string(&1.id) == id)),
        do: Boards.delete_status_update(String.to_integer(id))
    end)
  end

  def handle_event("add_card_url", params, socket) do
    case socket.assigns do
      %{can_write: true, page: %Page{} = page} ->
        case Boards.add_card_url(page, Map.take(params, ["url", "title"])) do
          {:ok, _} -> {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload_page()}
          {:error, _} -> {:noreply, put_flash(socket, :error, "That isn't an address I can use.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_card_url", %{"id" => id}, socket) do
    contents_event(socket, fn page ->
      url = Boards.get_card_url!(id)
      if url.page_id == page.id, do: Boards.delete_card_url(url)
    end)
  end

  def handle_event("set_field", %{"field_id" => id, "value" => value}, socket) do
    board = socket.assigns.fields_board

    case board && Enum.find(board.fields, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, socket}

      field ->
        case socket.assigns do
          %{can_write: true, page: %Page{} = page} ->
            case Fields.set_value(page, field, value) do
              {:ok, _} -> {:noreply, reload_page(socket)}
              {:error, message} -> {:noreply, put_flash(socket, :error, message)}
            end

          _ ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("vote", %{"count" => count}, socket) do
    case socket.assigns do
      %{page: %Page{} = page, current_user: user} when not is_nil(user) ->
        case Votes.set(page, user, String.to_integer(to_string(count))) do
          {:ok, _} -> {:noreply, reload_page(socket)}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("place", %{"column" => column_id}, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, placed} <- Wiki.place(page, String.to_integer(column_id)) do
      {:noreply,
       socket
       |> put_flash(:info, "Put “#{placed.title}” on the board.")
       |> reload(placed)}
    else
      {:error, _, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "That page couldn't be put on the board.")}
    end
  end

  def handle_event("unplace", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, unplaced} <- Wiki.unplace(page) do
      {:noreply,
       socket
       |> put_flash(:info, "Took it off the board. It is still here.")
       |> reload(unplaced)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be taken off the board.")}
    end
  end

  def handle_event("dismiss_conflict", _params, socket),
    do: {:noreply, assign(socket, conflict: nil)}

  # A passage of a page becomes a card: its first line is the title, the rest
  # the description, and the link is written into both ends so neither side
  # has to remember the other.
  def handle_event("card_from_selection", %{"text" => text}, socket) do
    board = Boards.get_board!(socket.assigns.board.id)

    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         [column | _] <- board.columns,
         {:ok, card} <-
           Wiki.create_card_from_selection(page, column, text,
             user: socket.assigns.current_user,
             via: "web"
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Made ##{card.id} “#{card.title}” in #{column.name}.")
       |> reload(page)}
    else
      [] -> {:noreply, put_flash(socket, :error, "That board has no lists to put a card in.")}
      _ -> {:noreply, put_flash(socket, :error, "That card couldn't be made.")}
    end
  end

  # Where a drop landed. "folder:" is the top of the wiki; "page:7" is inside
  # a page, which is the other axis (see `Slipdock.Wiki.Folder`).
  defp drop_target(socket, "folder:" <> ref),
    do: {:folder, folder_from(socket.assigns.board, ref)}

  defp drop_target(socket, "page:" <> ref) do
    case Wiki.find_page(socket.assigns.board, ref) do
      {:ok, page} -> {:page, page}
      _ -> :none
    end
  end

  defp drop_target(_socket, _into), do: :none

  defp tree_move(socket, "page", id, into, before) do
    with {:ok, page} <- Wiki.find_page(socket.assigns.board, id),
         target when target != :none <- drop_target(socket, into) do
      {parent, folder} =
        case target do
          # Filed in a folder, and part of nothing: the two axes are set
          # together because the tree draws them together.
          {:folder, folder} -> {nil, folder}
          {:page, parent} -> {parent, parent.folder_id && Wiki.get_folder(parent.folder_id)}
        end

      with {:ok, page} <- Wiki.file_page(page, folder),
           index <- sibling_index(socket.assigns.board, page, parent, before),
           {:ok, _} <-
             Wiki.move_page(page, parent, index,
               user: socket.assigns.current_user,
               via: "web"
             ) do
        socket
      else
        _ -> put_flash(socket, :error, "That page couldn't be moved.")
      end
    else
      _ -> put_flash(socket, :error, "That page couldn't be moved.")
    end
  end

  defp tree_move(socket, "folder", id, into, before) do
    with {:ok, folder} <- Wiki.find_folder(socket.assigns.board, id),
         {:folder, parent} <- drop_target(socket, into),
         {:ok, _} <- Wiki.move_folder(folder, parent, blank_to_integer(before)) do
      socket
    else
      {:error, :unprocessable_entity, message} -> put_flash(socket, :error, message)
      _ -> put_flash(socket, :error, "That folder couldn't be moved.")
    end
  end

  defp tree_move(socket, _kind, _id, _into, _before), do: socket

  # Where in its new parent's children the page lands. The page tree's order
  # is per parent rather than per folder, so the answer is the index of what
  # it was dropped above in *that* list, not in the list on the screen.
  defp sibling_index(board, %Page{} = page, parent, before) do
    siblings = siblings_of(board, page, parent)

    case before && Enum.find_index(siblings, &(to_string(&1.id) == to_string(before))) do
      nil -> length(siblings)
      n -> n
    end
  end

  defp siblings_of(board, %Page{} = page, parent) do
    case parent do
      %Page{} = parent -> Wiki.children(parent)
      _ -> Wiki.list_pages(board, parent: :root, archived: :all)
    end
    |> Enum.reject(&(&1.id == page.id))
  end

  defp delete_folder(socket, folder, strategy) do
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
        |> load_tree()
        |> then(fn socket ->
          # Looking at the folder that has just gone: the wiki is where to be.
          if socket.assigns.live_action == :index,
            do: push_patch(socket, to: ~p"/boards/#{socket.assigns.board}/wiki"),
            else: socket
        end)

      _ ->
        assign(socket, folder_delete: nil)
        |> put_flash(:error, "That folder couldn't be deleted.")
    end
  end

  defp assign_card_results(socket) do
    query = String.trim(socket.assigns.card_query || "")
    attached = Enum.map(socket.assigns.cards, & &1.target_card_id)

    results =
      if query == "",
        do: [],
        else: Boards.search_cards(socket.assigns.board.id, query, attached)

    assign(socket, card_results: results)
  end

  defp blank_to_integer(nil), do: nil

  defp blank_to_integer(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp blank_to_nil(value) when value in [nil, "", "none"], do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp blank_to_nil(value), do: value

  defp save(socket, nil, params, message) do
    board = socket.assigns.board
    parent = socket.assigns[:new_parent]
    column = socket.assigns[:new_column]
    folder = socket.assigns[:new_folder]

    params =
      params
      |> Map.put("parent_id", parent && parent.id)
      # The select in the form wins; the folder the link carried is only the
      # default it was rendered with.
      |> Map.put_new("folder_id", folder && folder.id)
      |> Map.update!("folder_id", &blank_to_nil/1)

    case Wiki.create_page(board, params,
           user: socket.assigns.current_user,
           via: "web",
           message: message
         ) do
      {:ok, page} ->
        # Started from the foot of a list: it belongs in that list.
        {page, note} =
          case column && Wiki.place(page, column) do
            {:ok, placed} -> {placed, " It's in #{column.name}."}
            _ -> {page, ""}
          end

        socket
        |> put_flash(:info, "Wrote “#{page.title}”.#{note}")
        |> push_navigate(to: ~p"/boards/#{board}/wiki/#{page.slug}")

      {:error, changeset} ->
        assign(socket, form: to_form(changeset))
    end
  end

  defp save(socket, %Page{} = page, params, message) do
    # "" from the Folder select means the top of the wiki. Ecto reads "" as
    # "not sent", so it has to be said as nil for the page to be unfiled.
    params =
      if Map.has_key?(params, "folder_id"),
        do: Map.update!(params, "folder_id", &blank_to_nil/1),
        else: params

    opts = [
      user: socket.assigns.current_user,
      via: "web",
      message: message,
      base_hash: params["base_hash"]
    ]

    case Wiki.update_page(page, Map.delete(params, "base_hash"), opts) do
      {:ok, saved} ->
        socket
        |> put_flash(:info, "Saved.")
        |> push_navigate(to: ~p"/boards/#{socket.assigns.board}/wiki/#{saved.slug}")

      {:error, :conflict, current} ->
        # Re-base on the version now shown beside the editor, so saving again
        # after merging is a save rather than a second conflict.
        socket
        |> put_flash(:error, "Someone else saved this page while you were writing.")
        |> assign(conflict: current, base_hash: current.content_hash)

      {:error, changeset} ->
        assign(socket, form: to_form(changeset))
    end
  end

  defp reload(socket, %Page{} = page) do
    fresh = Wiki.get_page!(page.id)

    socket
    |> assign_page(fresh)
    |> assign(html: render_body(socket, fresh, fresh.body), cards: card_links(fresh))
    |> assign_card_results()
    |> load_tree()
  end

  @impl true
  def handle_info({:wiki_changed, _board_id}, socket) do
    socket = load_tree(socket)

    {:noreply,
     case socket.assigns.page do
       %Page{} = page ->
         fresh = Wiki.get_page(page.id) || page
         socket |> assign_page(fresh) |> assign(cards: card_links(fresh))

       _ ->
         socket
     end}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Helpers used by the template ---------------------------------------------

  defp wiki_path(board), do: ~p"/boards/#{board}/wiki"
  defp page_path(board, %Page{} = page), do: ~p"/boards/#{board}/wiki/#{page.slug}"

  defp summary_of(%Page{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp summary_of(%Page{body: body}), do: Renderer.excerpt(body, 140)

  # What a page says about where it stands, for the places that only show it.
  defp facets(page) do
    [
      page.priority != "none" && {page.priority, "Priority"},
      page.completed && {"written", "Marked written"},
      assignee_facet(page.assignee),
      page.start_date && {"starts #{page.start_date}", "Start date"},
      page.due_date && {"due #{page.due_date}", "Due date"},
      page.percent_complete && {"#{page.percent_complete}%", "Per cent complete"}
    ]
    |> Enum.filter(&is_tuple/1)
    |> Enum.concat(Enum.map(page.flags, &{&1, "Flag"}))
  end

  # An unloaded association is truthy, so the match has to be on the struct.
  defp assignee_facet(%Slipdock.Accounts.User{} = user),
    do: {"@" <> Slipdock.Accounts.User.display_name(user), "Assignee"}

  defp assignee_facet(_), do: nil

  defp column_name(columns, column_id) do
    case Enum.find(columns, &(&1.id == column_id)) do
      nil -> "a list"
      column -> column.name
    end
  end

  defp stamp(nil), do: ""
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y, %H:%M")

  defp via_label("web"), do: "in the app"
  defp via_label("api"), do: "over the API"
  defp via_label("cli"), do: "from the CLI"
  defp via_label("assistant"), do: "by the assistant"
  defp via_label("automation"), do: "by an automation"
  defp via_label(_), do: ""

  defp author_label(revision) do
    case revision.author do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} -> email
      _ -> "someone"
    end
  end

  ## Render -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:boards}
      page_jumps={@page_jumps}
    >
      <:nav>
        <nav class="flex min-w-0 items-center gap-1 text-sm">
          <.link
            navigate={~p"/boards/#{@board}"}
            class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
          >
            <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
            <span class="truncate font-semibold">{@board.name}</span>
          </.link>
          <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
          <.link
            navigate={wiki_path(@board)}
            class="rounded-lg px-2 py-1 font-semibold hover:bg-base-200"
          >
            Wiki
          </.link>
        </nav>
      </:nav>
      <:actions>
        <.link
          :if={@can_write}
          navigate={~p"/boards/#{@board}/wiki/new"}
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-plus" class="size-4" />
          <span class="hidden sm:inline">New page</span>
        </.link>
      </:actions>

      <%!-- The same bar the card views carry. The wiki is one more way of
            looking at a board, and a page is one more thing that answers a
            filter, so switching view and narrowing down work here too. --%>
      <div class="flex flex-wrap items-center gap-x-2 gap-y-2 border-b border-base-300 bg-base-100/70 px-3 py-2 text-sm">
        <.view_tabs board={@board} mode={:wiki} view={nil} marks={@marks} />
        <span class="hidden h-5 w-px bg-base-300 sm:block"></span>

        <form id="wiki-search" phx-change="search" phx-submit="search" class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
          />
          <input
            type="search"
            name="q"
            value={@filters.q}
            placeholder="Search page/folder titles…"
            phx-debounce="200"
            class="input input-sm w-56 rounded-full pl-8 transition-[width] focus:w-72"
            autocomplete="off"
          />
        </form>

        <%!-- No Kind section: the wiki is pages all the way down. --%>
        <.filter_menu
          board={@board}
          filters={@filters}
          filtering={@filtering}
          kinds={false}
          label="Hide pages marked done"
        />

        <div class="dropdown">
          <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-1" title="Display">
            <.icon name="hero-adjustments-horizontal" class="size-4" />
            <span class="hidden md:inline">Display</span>
          </div>
          <div
            tabindex="0"
            class="dropdown-content z-30 mt-2 w-64 space-y-2 rounded-2xl bg-base-100 p-4 shadow-xl ring-1 ring-base-content/10"
          >
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Show in the tree
            </p>
            <label :if={@can_write} class="flex cursor-pointer items-center gap-2 text-sm">
              <input
                type="checkbox"
                class="toggle toggle-sm"
                checked={@show.drafts}
                phx-click="toggle_show"
                phx-value-what="drafts"
              /> Drafts
            </label>
            <label class="flex cursor-pointer items-center gap-2 text-sm">
              <input
                type="checkbox"
                class="toggle toggle-sm"
                checked={@show.templates}
                phx-click="toggle_show"
                phx-value-what="templates"
              /> Templates
            </label>
            <label :if={@can_write} class="flex cursor-pointer items-center gap-2 text-sm">
              <input
                type="checkbox"
                class="toggle toggle-sm"
                checked={@show.archived}
                phx-click="toggle_show"
                phx-value-what="archived"
              /> Archived pages
            </label>
          </div>
        </div>

        <span class="ml-auto hidden text-xs text-base-content/50 lg:inline" title="Pages shown">
          {@shown} {if @shown == 1, do: "page", else: "pages"}<span :if={@hidden > 0}> · {@hidden} hidden</span>
        </span>
      </div>

      <div class="flex min-h-0 flex-1 overflow-hidden">
        <aside
          id="wiki-tree"
          phx-hook="WikiTree"
          data-organising={to_string(@organising)}
          class="kanban-scroll hidden w-64 shrink-0 overflow-y-auto border-r border-base-300 bg-base-100 p-3 lg:block"
        >
          <div class="mb-2 flex items-center gap-1">
            <.link
              navigate={wiki_path(@board)}
              class={[
                "flex min-w-0 flex-1 items-center gap-2 rounded-lg px-2 py-1.5 text-sm font-semibold hover:bg-base-200",
                @live_action == :index && is_nil(@folder) && "bg-base-200"
              ]}
            >
              <.icon name="hero-book-open" class="size-4" /> All pages
            </.link>
            <%!-- Rearranging is a mode, and it says so: in it the tree is
                  draggable and nothing else about it changes. --%>
            <button
              :if={@can_write}
              type="button"
              phx-click="toggle_organise"
              class={[
                "btn btn-ghost btn-xs btn-square shrink-0",
                @organising && "btn-active text-primary"
              ]}
              title={if @organising, do: "Done organising", else: "Organise the tree"}
              aria-pressed={to_string(@organising)}
            >
              <.icon name={if @organising, do: "hero-check", else: "hero-pencil"} class="size-4" />
            </button>
          </div>
          <p
            :if={@organising}
            class="mb-2 rounded-lg bg-primary/10 px-2 py-1.5 text-xs text-base-content/70"
          >
            Drag to rearrange. A page dropped in a folder is <em>kept</em> there; dropped on a
            page, it becomes part of it.
          </p>
          <%!-- This box matches names — a page's title and summary, a
                folder's. The words *inside* the pages are Search's job, so
                the way there is one click from the search that just missed,
                carrying the query and this board with it. --%>
          <p
            :if={@filters.q != ""}
            class="mb-2 rounded-lg bg-base-200/60 px-2 py-1.5 text-xs text-base-content/60"
          >
            Full text search for:
            <.link
              navigate={~p"/search?#{[q: @filters.q, board: @board.id]}"}
              class="link font-medium text-base-content"
              title="Search the words inside these pages, by meaning"
            >
              {@filters.q}
            </.link>
          </p>
          <p
            :if={@tree == [] and @folders == [] and @filters.q == ""}
            class="px-2 py-4 text-sm text-base-content/50"
          >
            Nothing written yet.
          </p>
          <p
            :if={@folders == [] and @unfiled == [] and @filters.q != ""}
            class="px-2 py-4 text-sm text-base-content/50"
          >
            No page or folder name matches that.
          </p>
          <%!-- Folders first, then the pages filed nowhere. Two axes, drawn
                as one tree: a folder is where a page is kept, a child page is
                part of its parent (see `Slipdock.Wiki.Folder`). --%>
          <%!-- While a search is running every folder is open: a hit three
                folders down is no use behind a shut one. --%>
          <.folder_tree
            nodes={@folders}
            board={@board}
            current={@page}
            collapsed={if @filters.q == "", do: @collapsed, else: MapSet.new()}
            can_write={@can_write}
            organising={@organising}
            open={@folder}
            parent={nil}
            depth={0}
          />
          <%!-- The pages filed nowhere, under a heading of their own once
                there are folders to tell them apart from. --%>
          <p
            :if={@unfiled != [] and @folders != []}
            class="mt-2 px-2 pb-0.5 text-2xs font-semibold uppercase tracking-wide text-base-content/40"
          >
            Not in a folder
          </p>
          <.page_tree
            nodes={@unfiled}
            board={@board}
            current={@page}
            organising={@organising}
            into="folder:"
            depth={0}
          />
          <button
            :if={@can_write}
            type="button"
            phx-click="new_folder"
            class="mt-2 flex w-full items-center gap-1.5 rounded-lg px-2 py-1.5 text-sm text-base-content/60 hover:bg-base-200"
          >
            <.icon name="hero-folder-plus" class="size-4" /> New folder
          </button>
        </aside>

        <main class="kanban-scroll min-w-0 flex-1 overflow-y-auto">
          <div class="mx-auto max-w-4xl px-4 py-6 sm:px-8 sm:py-8">
            <%= case @live_action do %>
              <% :index when not is_nil(@folder) -> %>
                <.folder_body
                  board={@board}
                  folder={@folder}
                  node={folder_node(@folders, @folder.id)}
                  can_write={@can_write}
                />
              <% :index -> %>
                <.index_body
                  board={@board}
                  tree={@tree}
                  folders={@folders}
                  recent={@recent}
                  wanted={@wanted}
                  can_write={@can_write}
                />
              <% action when action in [:new, :edit] -> %>
                <.editor
                  form={@form}
                  page={@page}
                  board={@board}
                  preview={@preview}
                  conflict={@conflict}
                  base_hash={@base_hash}
                  uploads={@uploads}
                  column={@new_column}
                  outline={@folder_outline}
                />
              <% :history -> %>
                <.history_body board={@board} page={@page} revisions={@revisions} />
              <% :revision -> %>
                <.revision_body
                  board={@board}
                  page={@page}
                  revision={@revision}
                  diff={@diff}
                  can_write={@can_write}
                />
              <% _ -> %>
                <.page_body
                  board={@board}
                  fields_board={@fields_board}
                  page={@page}
                  html={@html}
                  backlinks={@backlinks}
                  children={@children}
                  cards={@cards}
                  card_query={@card_query}
                  card_results={@card_results}
                  outline={@folder_outline}
                  tags={@tags}
                  columns={@columns}
                  can_write={@can_write}
                  can_manage={@can_manage}
                  current_user={@current_user}
                  form_key={@form_key}
                />
            <% end %>
          </div>
        </main>
      </div>

      <.folder_modal :if={@folder_modal} modal={@folder_modal} outline={@folder_outline} />
      <.folder_delete_modal :if={@folder_delete} folder={@folder_delete} />
    </Layouts.app>
    """
  end

  attr :modal, :map, required: true
  attr :outline, :list, required: true

  @doc false
  # One dialog for both making and renaming a folder: the two differ only in
  # whether there is a folder to start from, and a rename that can also move
  # is one form rather than two.
  defp folder_modal(assigns) do
    ~H"""
    <.modal id="folder-modal" on_close={JS.push("close_folder_modal")} size="sm">
      <div class="space-y-5 p-6">
        <h2 class="text-lg font-semibold">
          {if @modal.folder, do: "Rename or move folder", else: "New folder"}
        </h2>
        <form id="folder-form" phx-submit="save_folder" class="space-y-4">
          <label class="block space-y-1.5">
            <span class="text-sm font-medium">Name</span>
            <input
              type="text"
              name="name"
              value={@modal.name}
              autofocus
              required
              maxlength={Slipdock.Wiki.Folder.name_length()}
              placeholder="Design decisions"
              class="input input-bordered w-full"
            />
            <span :if={is_nil(@modal.folder)} class="block text-xs text-base-content/50">
              A name with slashes makes the whole path: “Design/Decisions” makes both.
            </span>
          </label>
          <%!-- A tree you type at rather than a flat select: see
                `SlipdockWeb.FolderPicker`. The folder being moved and anything
                inside it are shown greyed, because "you cannot file it in
                itself" is worth saying rather than hiding. --%>
          <.folder_picker
            id="folder-parent-picker"
            label="Inside"
            name="parent_id"
            outline={@outline}
            selected={
              (@modal.folder && @modal.folder.parent_id) || (@modal.parent && @modal.parent.id)
            }
            exclude={@modal.folder && @modal.folder.id}
          />
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="close_folder_modal" class="btn btn-ghost btn-sm">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              {if @modal.folder, do: "Save", else: "Make folder"}
            </button>
          </div>
        </form>
      </div>
    </.modal>
    """
  end

  attr :folder, :map, required: true

  @doc false
  # Deleting a folder that has something in it: the two answers are offered
  # side by side with what each one costs, because "delete" on a folder is
  # ambiguous in a way "delete" on a page is not.
  defp folder_delete_modal(assigns) do
    ~H"""
    <.modal id="folder-delete-modal" on_close={JS.push("close_folder_delete")} size="sm">
      <div class="space-y-5 p-6">
        <div class="space-y-1">
          <h2 class="text-lg font-semibold">Delete “{@folder.folder.name}”?</h2>
          <p class="text-sm text-base-content/60">
            {@folder.path} holds {count(@folder.counts.pages, "page")}<span :if={
              @folder.counts.folders > 0
            }>
              in {count(@folder.counts.folders, "folder")}</span>.
          </p>
        </div>

        <div class="space-y-2">
          <button
            type="button"
            phx-click="delete_folder"
            phx-value-how="keep"
            class="w-full rounded-xl border border-base-300 p-3 text-left hover:border-primary hover:bg-base-200"
          >
            <span class="flex items-center gap-2 text-sm font-medium">
              <.icon name="hero-folder-minus" class="size-4" /> Delete the folder only
            </span>
            <span class="mt-1 block text-xs text-base-content/60">
              Its pages go back to the top of the wiki and any folders inside it move up. Nothing
              written is lost.
            </span>
          </button>
          <button
            type="button"
            phx-click="delete_folder"
            phx-value-how="purge"
            class="w-full rounded-xl border border-error/40 p-3 text-left hover:bg-error/10"
          >
            <span class="flex items-center gap-2 text-sm font-medium text-error">
              <.icon name="hero-trash" class="size-4" /> Delete the folder and everything in it
            </span>
            <span class="mt-1 block text-xs text-base-content/60">
              {count(@folder.counts.pages, "page")} deleted for good, history and all — this
              cannot be undone. Pages filed elsewhere that are children of these are left
              behind.
            </span>
          </button>
        </div>

        <div class="flex justify-end">
          <button type="button" phx-click="close_folder_delete" class="btn btn-ghost btn-sm">
            Cancel
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  # What is about to be lost, said plainly. A page's children are not deleted
  # with it, so the warning says where they will end up instead.
  defp delete_warning(%Page{} = page, children) do
    base = "Delete “#{page.title}” and its whole history for good? This cannot be undone."

    case length(children) do
      0 -> base
      n -> base <> " The #{count(n, "page")} under it will be kept, at the top of the tree."
    end
  end

  attr :nodes, :list, required: true
  attr :board, :any, required: true
  attr :current, :any, default: nil
  attr :collapsed, :any, required: true
  attr :can_write, :boolean, default: false
  attr :depth, :integer, default: 0
  attr :open, :any, default: nil, doc: "the folder being looked at, if any"
  attr :organising, :boolean, default: false
  attr :parent, :any, default: nil, doc: "the folder these sit in, for a drop"

  @doc false
  # A folder and what is filed in it: the folders below it, then the pages.
  # Shut folders keep their contents — collapsing is a reader's convenience,
  # so it lives in the socket rather than in anything saved.
  defp folder_tree(assigns) do
    ~H"""
    <%!-- In organise mode every list is a drop target, including the empty
          ones: a folder with nothing in it is exactly where you want to drag
          the first thing. Folders and pages are separate lists in the same
          tree, which is what stops a page being dropped where only a folder
          belongs. --%>
    <ul
      class="space-y-0.5"
      data-tree-list={@organising && "folders"}
      data-into={@organising && "folder:#{@parent && @parent.id}"}
      data-empty={@organising and @nodes == []}
    >
      <li
        :for={%{folder: folder, children: children, pages: pages} = node <- @nodes}
        data-id={folder.id}
      >
        <%!-- The chevron opens the folder in the tree; the name opens the
              folder itself. A folder is a place you can be, not only a lid. --%>
        <div
          class={[
            "group flex items-center gap-1 rounded-lg pr-1 text-sm hover:bg-base-200",
            @open && @open.id == folder.id && "bg-base-200"
          ]}
          style={"padding-left: #{0.25 + @depth * 0.75}rem"}
        >
          <span
            :if={@organising}
            data-drag
            class="shrink-0 cursor-grab py-1.5 text-base-content/30 hover:text-base-content/60"
            title="Drag to move this folder"
          >
            <.icon name="hero-bars-2" class="size-3.5" />
          </span>
          <button
            type="button"
            phx-click="toggle_folder"
            phx-value-id={folder.id}
            class="shrink-0 py-1.5 pr-0.5"
            title={if MapSet.member?(@collapsed, folder.id), do: "Open", else: "Close"}
            aria-label="Open or close this folder"
          >
            <.icon
              name={
                if MapSet.member?(@collapsed, folder.id),
                  do: "hero-chevron-right",
                  else: "hero-chevron-down"
              }
              class="size-3 shrink-0 text-base-content/40"
            />
          </button>
          <.link
            patch={~p"/boards/#{@board}/wiki?#{[folder: folder.id]}"}
            class="flex min-w-0 flex-1 items-center gap-1.5 py-1.5 text-left"
            title={Wiki.folder_path(folder)}
          >
            <.icon name="hero-folder" class="size-3.5 shrink-0 text-base-content/50" />
            <span class="min-w-0 flex-1 truncate font-medium">{folder.name}</span>
            <span class="shrink-0 text-2xs text-base-content/40">
              {Slipdock.Wiki.Folders.page_count(node)}
            </span>
          </.link>
          <div :if={@can_write} class="dropdown dropdown-end shrink-0">
            <div
              tabindex="0"
              role="button"
              class="btn btn-ghost btn-xs btn-square opacity-0 group-hover:opacity-100"
              title="Folder actions"
            >
              <.icon name="hero-ellipsis-horizontal" class="size-3.5" />
            </div>
            <ul
              tabindex="0"
              class="menu dropdown-content z-40 mt-1 w-48 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
            >
              <li>
                <.link patch={~p"/boards/#{@board}/wiki?#{[folder: folder.id]}"}>
                  <.icon name="hero-folder-open" class="size-4" /> Open this folder
                </.link>
              </li>
              <li>
                <.link navigate={~p"/boards/#{@board}/wiki/new?#{[folder: folder.id]}"}>
                  <.icon name="hero-document-plus" class="size-4" /> New page here
                </.link>
              </li>
              <li>
                <button type="button" phx-click="new_folder" phx-value-parent={folder.id}>
                  <.icon name="hero-folder-plus" class="size-4" /> New folder inside
                </button>
              </li>
              <li>
                <button type="button" phx-click="rename_folder" phx-value-id={folder.id}>
                  <.icon name="hero-pencil" class="size-4" /> Rename or move…
                </button>
              </li>
              <li>
                <button
                  type="button"
                  phx-click="ask_delete_folder"
                  phx-value-id={folder.id}
                  class="text-error"
                >
                  <.icon name="hero-trash" class="size-4" /> Delete folder…
                </button>
              </li>
            </ul>
          </div>
        </div>
        <div :if={not MapSet.member?(@collapsed, folder.id)}>
          <.folder_tree
            :if={children != [] or @organising}
            nodes={children}
            board={@board}
            current={@current}
            collapsed={@collapsed}
            can_write={@can_write}
            organising={@organising}
            open={@open}
            parent={folder}
            depth={@depth + 1}
          />
          <.page_tree
            nodes={pages}
            board={@board}
            current={@current}
            organising={@organising}
            into={"folder:#{folder.id}"}
            depth={@depth + 1}
          />
          <p
            :if={children == [] and pages == [] and not @organising}
            class="py-1 text-xs italic text-base-content/40"
            style={"padding-left: #{1.25 + @depth * 0.75}rem"}
          >
            Empty
          </p>
        </div>
      </li>
    </ul>
    """
  end

  attr :nodes, :list, required: true
  attr :board, :any, required: true
  attr :current, :any, default: nil
  attr :depth, :integer, default: 0
  attr :organising, :boolean, default: false
  attr :into, :string, default: nil, doc: "the container a drop here lands in"

  defp page_tree(assigns) do
    ~H"""
    <ul
      class="space-y-0.5"
      data-tree-list={@organising && "pages"}
      data-into={@organising && @into}
      data-empty={@organising and @nodes == []}
    >
      <li :for={%{page: page, children: children} <- @nodes} data-id={page.id}>
        <div
          class={[
            "flex items-center gap-1.5 rounded-lg pr-2 text-sm hover:bg-base-200",
            @current && @current.id == page.id && "bg-base-200 font-medium"
          ]}
          style={"padding-left: #{0.5 + @depth * 0.75}rem"}
        >
          <span
            :if={@organising}
            data-drag
            class="shrink-0 cursor-grab py-1.5 text-base-content/30 hover:text-base-content/60"
            title="Drag to move this page"
          >
            <.icon name="hero-bars-2" class="size-3.5" />
          </span>
          <.link
            navigate={page_path(@board, page)}
            class="flex min-w-0 flex-1 items-center gap-1.5 py-1.5"
            title={page.title}
          >
            <.icon name="hero-document-text" class="size-3.5 shrink-0 text-base-content/40" />
            <span class="min-w-0 flex-1 truncate">{page.title}</span>
            <span
              :if={page.status == "draft"}
              class="shrink-0 rounded bg-amber-500/15 px-1 text-2xs font-medium text-amber-700"
            >
              draft
            </span>
          </.link>
        </div>
        <%!-- A page's children are a container of their own, so dragging a
              page onto one makes it part of that page — the second axis,
              reachable without leaving the tree. --%>
        <.page_tree
          :if={children != [] or @organising}
          nodes={children}
          board={@board}
          current={@current}
          organising={@organising}
          into={"page:#{page.id}"}
          depth={@depth + 1}
        />
      </li>
    </ul>
    """
  end

  # The node for one folder, wherever it sits in the tree the sidebar draws.
  defp folder_node(nodes, id) do
    Enum.find_value(nodes, fn %{folder: folder, children: children} = node ->
      if folder.id == id, do: node, else: folder_node(children, id)
    end)
  end

  attr :board, :any, required: true
  attr :folder, :any, required: true
  attr :node, :any, default: nil
  attr :can_write, :boolean, required: true

  @doc false
  # One folder, looked at: what is in it, and everything you would want to do
  # to it. A folder with no page of its own to stand on is the thing that made
  # filing feel like an afterthought — this is that page.
  defp folder_body(assigns) do
    assigns = assign(assigns, children: (assigns.node && assigns.node.children) || [])
    assigns = assign(assigns, pages: (assigns.node && assigns.node.pages) || [])

    ~H"""
    <nav class="mb-2 flex flex-wrap items-center gap-1 text-sm text-base-content/50">
      <.link patch={wiki_path(@board)} class="hover:text-base-content">Wiki</.link>
      <span :for={up <- Wiki.folder_ancestors(@folder)} class="flex items-center gap-1">
        <.icon name="hero-chevron-right" class="size-3" />
        <.link
          patch={~p"/boards/#{@board}/wiki?#{[folder: up.id]}"}
          class="hover:text-base-content"
        >
          {up.name}
        </.link>
      </span>
      <.icon name="hero-chevron-right" class="size-3" />
      <span class="text-base-content">{@folder.name}</span>
    </nav>

    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h1 class="flex items-center gap-2 text-2xl font-bold tracking-tight sm:text-3xl">
          <.icon name="hero-folder" class="size-6 shrink-0 text-base-content/40" />
          {@folder.name}
        </h1>
        <p class="mt-1 text-sm text-base-content/60">
          {count((@node && Slipdock.Wiki.Folders.page_count(@node)) || 0, "page")}<span :if={
            @children != []
          }>
            in {count(length(@children), "folder")}</span>. Filed at <span class="font-mono text-xs">{Wiki.folder_path(@folder)}</span>.
        </p>
      </div>
      <div :if={@can_write} class="flex shrink-0 items-center gap-1">
        <.link
          navigate={~p"/boards/#{@board}/wiki/new?#{[folder: @folder.id]}"}
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-document-plus" class="size-4" /> New page here
        </.link>
        <div class="dropdown dropdown-end">
          <div
            tabindex="0"
            role="button"
            class="btn btn-ghost btn-sm btn-square"
            title="Folder actions"
          >
            <.icon name="hero-ellipsis-horizontal" class="size-5" />
          </div>
          <ul
            tabindex="0"
            class="menu dropdown-content z-40 mt-1 w-56 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
          >
            <li>
              <button type="button" phx-click="new_folder" phx-value-parent={@folder.id}>
                <.icon name="hero-folder-plus" class="size-4" /> New folder inside
              </button>
            </li>
            <li>
              <button type="button" phx-click="rename_folder" phx-value-id={@folder.id}>
                <.icon name="hero-pencil" class="size-4" /> Rename or move…
              </button>
            </li>
            <li>
              <button
                type="button"
                phx-click="ask_delete_folder"
                phx-value-id={@folder.id}
                class="text-error"
              >
                <.icon name="hero-trash" class="size-4" /> Delete folder…
              </button>
            </li>
          </ul>
        </div>
      </div>
    </div>

    <section :if={@children != []} class="mt-8">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">Folders</h2>
      <ul class="mt-3 grid gap-2 sm:grid-cols-2">
        <li :for={sub <- @children}>
          <.link
            patch={~p"/boards/#{@board}/wiki?#{[folder: sub.folder.id]}"}
            class="flex items-center gap-2 rounded-xl border border-base-300 bg-base-100 p-3 text-sm hover:border-primary"
          >
            <.icon name="hero-folder" class="size-4 shrink-0 text-base-content/50" />
            <span class="min-w-0 flex-1 truncate font-medium">{sub.folder.name}</span>
            <span class="shrink-0 text-xs text-base-content/40">
              {count(Slipdock.Wiki.Folders.page_count(sub), "page")}
            </span>
          </.link>
        </li>
      </ul>
    </section>

    <section class="mt-8">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">Pages</h2>
      <div
        :if={@pages == []}
        class="mt-3 rounded-xl border border-dashed border-base-300 p-8 text-center"
      >
        <.icon name="hero-document-text" class="size-7 text-base-content/30" />
        <p class="mt-3 text-sm text-base-content/60">
          Nothing filed here{if @children != [], do: " directly", else: ""}.
        </p>
        <.link
          :if={@can_write}
          navigate={~p"/boards/#{@board}/wiki/new?#{[folder: @folder.id]}"}
          class="btn btn-sm mt-4"
        >
          Write the first page
        </.link>
      </div>
      <ul
        :if={@pages != []}
        class="mt-3 divide-y divide-base-300 rounded-xl border border-base-300 bg-base-100"
      >
        <li :for={%{page: page, children: kids} <- @pages}>
          <.link
            navigate={page_path(@board, page)}
            class="flex items-baseline gap-3 px-4 py-3 hover:bg-base-200"
          >
            <span class="min-w-0 flex-1">
              <span class="font-medium">{page.title}</span>
              <span :if={page.status == "draft"} class="chip chip-line ml-2 text-2xs">draft</span>
              <span :if={summary_of(page) != ""} class="ml-2 text-sm text-base-content/50">
                {summary_of(page)}
              </span>
            </span>
            <span :if={kids != []} class="shrink-0 text-2xs text-base-content/40">
              {length(kids)} under it
            </span>
            <span class="shrink-0 font-mono text-2xs text-base-content/40">{page.code}</span>
            <span class="hidden shrink-0 text-xs text-base-content/40 sm:inline">
              {stamp(page.updated_at)}
            </span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  attr :board, :any, required: true
  attr :tree, :list, required: true
  attr :folders, :list, default: []
  attr :recent, :list, required: true
  attr :wanted, :list, default: []
  attr :can_write, :boolean, required: true

  defp index_body(assigns) do
    ~H"""
    <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">{@board.name} wiki</h1>
    <p class="mt-2 text-sm text-base-content/60">
      What the board can't say: how it works, what was decided and why.
    </p>

    <div
      :if={@tree == []}
      class="mt-10 rounded-xl border border-dashed border-base-300 p-8 text-center"
    >
      <.icon name="hero-book-open" class="size-8 text-base-content/30" />
      <p class="mt-3 text-sm text-base-content/60">No pages yet.</p>
      <.link
        :if={@can_write}
        navigate={~p"/boards/#{@board}/wiki/new"}
        class="btn btn-primary btn-sm mt-4"
      >
        Write the first one
      </.link>
    </div>

    <%!-- Pages people have linked to but nobody has written. The classic way
          a wiki grows, and the best work queue it has. --%>
    <p class="mt-4 text-sm">
      <a href={~p"/boards/#{@board}/wiki.zip"} class="link text-base-content/60">
        Download the whole wiki as Markdown
      </a>
      <span class="text-base-content/40">
        — one .md file per page, front matter and all, so it opens in Obsidian or a text editor.
      </span>
    </p>

    <%!-- The filing, as a set of cards rather than the sidebar's tree: this
          is the page somebody lands on, and "where does anything live" is
          the first question it should answer. --%>
    <section :if={@folders != []} class="mt-8">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
        Folders
      </h2>
      <ul class="mt-3 grid gap-2 sm:grid-cols-2">
        <li :for={node <- @folders}>
          <div class="rounded-xl border border-base-300 bg-base-100 p-4">
            <.link
              patch={~p"/boards/#{@board}/wiki?#{[folder: node.folder.id]}"}
              class="flex items-baseline gap-2 hover:text-primary"
            >
              <.icon name="hero-folder" class="size-4 shrink-0 text-base-content/50" />
              <span class="min-w-0 flex-1 truncate font-medium">{node.folder.name}</span>
              <span class="shrink-0 text-xs text-base-content/40">
                {count(Slipdock.Wiki.Folders.page_count(node), "page")}
              </span>
            </.link>
            <ul class="mt-2 space-y-0.5 text-sm">
              <li :for={sub <- node.children}>
                <.link
                  patch={~p"/boards/#{@board}/wiki?#{[folder: sub.folder.id]}"}
                  class="flex items-center gap-1.5 text-base-content/60 hover:text-base-content"
                >
                  <.icon name="hero-folder" class="size-3 shrink-0" /> {sub.folder.name}
                </.link>
              </li>
              <li :for={%{page: page} <- node.pages}>
                <.link navigate={page_path(@board, page)} class="link link-hover">
                  {page.title}
                </.link>
              </li>
            </ul>
            <.link
              :if={@can_write}
              navigate={~p"/boards/#{@board}/wiki/new?#{[folder: node.folder.id]}"}
              class="mt-2 inline-flex items-center gap-1 text-xs text-base-content/50 hover:text-base-content"
            >
              <.icon name="hero-plus" class="size-3" /> New page here
            </.link>
          </div>
        </li>
      </ul>
    </section>

    <section :if={@wanted != []} class="mt-8">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
        Wanted pages
      </h2>
      <p class="mt-1 text-sm text-base-content/50">
        Linked to, but not written yet.
      </p>
      <ul class="mt-3 flex flex-wrap gap-2">
        <li :for={want <- @wanted}>
          <.link
            navigate={~p"/boards/#{@board}/wiki/new?#{[title: want.title]}"}
            class="chip chip-line border-dashed hover:bg-base-200"
            title={"Linked from #{Enum.map_join(want.from, ", ", & &1.title)}"}
          >
            {want.title}
            <span :if={want.count > 1} class="ml-1 text-base-content/40">×{want.count}</span>
          </.link>
        </li>
      </ul>
    </section>

    <section :if={@recent != []} class="mt-8">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
        Recently changed
      </h2>
      <ul class="mt-3 divide-y divide-base-300 rounded-xl border border-base-300 bg-base-100">
        <li :for={page <- @recent}>
          <.link
            navigate={page_path(@board, page)}
            class="flex items-baseline gap-3 px-4 py-3 hover:bg-base-200"
          >
            <span class="min-w-0 flex-1">
              <span class="font-medium">{page.title}</span>
              <span :if={summary_of(page) != ""} class="ml-2 text-sm text-base-content/50">
                {summary_of(page)}
              </span>
            </span>
            <span class="shrink-0 font-mono text-2xs text-base-content/40">{page.code}</span>
            <span class="hidden shrink-0 text-xs text-base-content/40 sm:inline">
              {stamp(page.updated_at)}
            </span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  attr :board, :any, required: true
  attr :page, :any, default: nil
  attr :html, :string, default: ""
  attr :backlinks, :list, default: []
  attr :children, :list, default: []
  attr :cards, :list, default: []
  attr :card_query, :string, default: ""
  attr :card_results, :list, default: []
  attr :outline, :list, default: []
  attr :tags, :list, default: []
  attr :columns, :list, default: []
  attr :can_write, :boolean, required: true
  attr :can_manage, :boolean, default: false
  attr :fields_board, :any, default: nil
  attr :current_user, :any, default: nil
  attr :form_key, :integer, default: 0

  defp page_body(assigns) do
    ~H"""
    <div :if={is_nil(@page)} class="py-16 text-center">
      <p class="text-base-content/60">That page doesn't exist.</p>
      <.link navigate={wiki_path(@board)} class="btn btn-sm mt-4">Back to the wiki</.link>
    </div>

    <article :if={@page}>
      <%!-- Two breadcrumbs, because a page sits on two axes: where it is
            filed, and what it is part of (see `Slipdock.Wiki.Folder`). --%>
      <nav
        :if={not is_nil(@page.folder_id) or Wiki.ancestors(@page) != []}
        class="mb-2 flex flex-wrap items-center gap-1 text-sm text-base-content/50"
      >
        <span
          :for={folder <- folder_crumbs(@page)}
          class="flex items-center gap-1"
          title="Filed here"
        >
          <.icon name="hero-folder" class="size-3" />
          <span>{folder.name}</span>
          <.icon name="hero-chevron-right" class="size-3" />
        </span>
        <span :for={ancestor <- Wiki.ancestors(@page)} class="flex items-center gap-1">
          <.link navigate={page_path(@board, ancestor)} class="hover:text-base-content">
            {ancestor.title}
          </.link>
          <.icon name="hero-chevron-right" class="size-3" />
        </span>
      </nav>

      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">{@page.title}</h1>
          <p :if={@page.summary} class="mt-1 text-base-content/60">{@page.summary}</p>
        </div>
        <div class="flex shrink-0 items-center gap-1">
          <span class="chip chip-line font-mono text-2xs" title="Page code">{@page.code}</span>
          <.link
            :if={@can_write}
            navigate={~p"/boards/#{@board}/wiki/#{@page.slug}/edit"}
            class="btn btn-sm gap-1.5"
          >
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </.link>
          <.link
            navigate={~p"/boards/#{@board}/wiki/#{@page.slug}/history"}
            class="btn btn-ghost btn-sm gap-1.5"
          >
            <.icon name="hero-clock" class="size-4" />
            <span class="hidden sm:inline">History</span>
          </.link>
          <%!-- Everything that changes what the page *is* rather than what
                it says, behind one menu: publishing, filing it away, and the
                owner's purge. Archiving is the reversible one and is offered
                first; deleting says what it will cost. --%>
          <div :if={@can_write} class="dropdown dropdown-end">
            <div
              tabindex="0"
              role="button"
              class="btn btn-ghost btn-sm btn-square"
              title="Page actions"
            >
              <.icon name="hero-ellipsis-horizontal" class="size-5" />
            </div>
            <ul
              tabindex="0"
              class="menu dropdown-content z-40 mt-1 w-64 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
            >
              <li :if={is_nil(@page.public_token) and @page.status != "draft"}>
                <button
                  type="button"
                  phx-click="publish"
                  data-confirm="Publish this page? Anyone with the link will be able to read it."
                >
                  <.icon name="hero-globe-alt" class="size-4" /> Publish at a public link
                </button>
              </li>
              <li :if={not is_nil(@page.public_token)}>
                <button type="button" phx-click="unpublish">
                  <.icon name="hero-globe-alt" class="size-4" /> Withdraw the public link
                </button>
              </li>
              <li>
                <.link navigate={~p"/boards/#{@board}/wiki/new?#{[parent: @page.id]}"}>
                  <.icon name="hero-document-plus" class="size-4" /> New page under this one
                </.link>
              </li>
              <li>
                <a href={~p"/boards/#{@board}/wiki/#{@page.slug}/page.md"} download>
                  <.icon name="hero-arrow-down-tray" class="size-4" /> Download as Markdown
                </a>
              </li>
              <li :if={is_nil(@page.archived_at)}>
                <button
                  type="button"
                  phx-click="archive"
                  data-confirm={"Archive “#{@page.title}” and everything under it? Nothing is lost: it can be restored."}
                >
                  <.icon name="hero-archive-box" class="size-4" /> Archive this page
                </button>
              </li>
              <li :if={not is_nil(@page.archived_at)}>
                <button type="button" phx-click="restore">
                  <.icon name="hero-arrow-uturn-left" class="size-4" /> Restore this page
                </button>
              </li>
              <li :if={@can_manage}>
                <button
                  type="button"
                  phx-click="delete_page"
                  data-confirm={delete_warning(@page, @children)}
                  class="text-error"
                >
                  <.icon name="hero-trash" class="size-4" /> Delete permanently
                </button>
              </li>
              <li :if={not @can_manage} class="menu-disabled">
                <span class="text-xs text-base-content/50">
                  Only the board's owner can delete a page for good.
                </span>
              </li>
            </ul>
          </div>
        </div>
      </div>

      <div
        :if={@page.archived_at}
        class="mt-4 flex items-center gap-3 rounded-xl border border-amber-500/30 bg-amber-500/10 px-4 py-3 text-sm"
      >
        <.icon name="hero-archive-box" class="size-4 shrink-0 text-amber-700" />
        <span class="flex-1">This page is archived.</span>
        <button :if={@can_write} type="button" phx-click="restore" class="btn btn-xs">Restore</button>
        <button
          :if={@can_manage}
          type="button"
          phx-click="delete_page"
          data-confirm={delete_warning(@page, @children)}
          class="btn btn-ghost btn-xs text-error"
        >
          Delete for good
        </button>
      </div>

      <div
        :if={@page.status == "draft"}
        class="mt-4 rounded-xl border border-base-300 bg-base-100 px-4 py-3 text-sm text-base-content/70"
      >
        A draft: only people who can write on this board can see it.
      </div>

      <%!-- Where it is filed. A page starts at the root, which is a place
            rather than a limbo; a folder is filing and nothing else. --%>
      <div
        :if={@can_write or not is_nil(@page.folder_id)}
        class="mt-4 flex flex-wrap items-center gap-2 text-sm text-base-content/60"
      >
        <.icon name="hero-folder" class="size-4 shrink-0" />
        <span>{if @page.folder_id, do: "Filed in", else: "Not in a folder."}</span>
        <%!-- The same picker the editor uses, pushing straight at `file_page`
              rather than through a form: filing a page is one click from
              reading it, and the tree is filterable here too. --%>
        <.folder_picker
          :if={@can_write}
          id="page-folder-picker"
          outline={@outline}
          selected={@page.folder_id}
          event="file_page"
          new_event="new_folder"
          size="xs"
          class="w-60"
        />
        <.link
          :if={not @can_write and @page.folder_id}
          navigate={~p"/boards/#{@board}/wiki?#{[folder: @page.folder_id]}"}
          class="link font-medium"
        >
          {filed_in(@page)}
        </.link>
        <.link
          :if={@can_write and @page.folder_id}
          navigate={~p"/boards/#{@board}/wiki?#{[folder: @page.folder_id]}"}
          class="link"
        >
          Open the folder
        </.link>
      </div>

      <%!-- On the board as well as in the wiki: a spec can sit in the list
            beside the work it describes, and be dragged about like a card. --%>
      <div
        :if={@can_write or @page.column_id}
        class="mt-4 flex flex-wrap items-center gap-2 text-sm text-base-content/60"
      >
        <.icon name="hero-view-columns" class="size-4 shrink-0" />
        <span :if={@page.column_id}>
          On the board in
          <.link navigate={~p"/boards/#{@board}"} class="link font-medium">
            {column_name(@columns, @page.column_id)}
          </.link>
        </span>
        <span :if={is_nil(@page.column_id)}>Not on the board.</span>
        <.link
          :if={@page.column_id}
          navigate={~p"/boards/#{@board}?#{[page: @page.id]}"}
          class="link"
        >
          Open its panel
        </.link>
        <div :if={@can_write} class="dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost btn-xs">
            {if @page.column_id, do: "Move to…", else: "Put it in a list…"}
          </div>
          <ul
            tabindex="0"
            class="menu dropdown-content z-40 mt-1 w-56 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
          >
            <li :for={column <- @columns}>
              <button
                type="button"
                phx-click="place"
                phx-value-column={column.id}
                class={@page.column_id == column.id && "menu-active"}
              >
                {column.name}
              </button>
            </li>
          </ul>
        </div>
        <button
          :if={@can_write and @page.column_id}
          type="button"
          phx-click="unplace"
          class="btn btn-ghost btn-xs"
        >
          Take it off
        </button>
      </div>

      <%!-- A published page is a live copy of its prose and a snapshot of its
            answers: nobody is behind an anonymous request to have the
            permissions a live query would need. --%>
      <div
        :if={@page.public_token}
        class="mt-4 flex flex-wrap items-center gap-3 rounded-xl border border-primary/30 bg-primary/5 px-4 py-3 text-sm"
      >
        <.icon name="hero-globe-alt" class="size-4 shrink-0 text-primary" />
        <span class="min-w-0 flex-1">
          Published at
          <a href={~p"/w/#{@page.public_token}"} class="link link-primary break-all" target="_blank">
            /w/{@page.public_token}
          </a>
          <span class="block text-xs text-base-content/50">
            Anything counted or listed in it was counted when you published, {stamp(
              @page.published_at
            )}.
          </span>
        </span>
        <button :if={@can_write} type="button" phx-click="publish" class="btn btn-xs">
          Refresh the answers
        </button>
        <button :if={@can_write} type="button" phx-click="unpublish" class="btn btn-ghost btn-xs">
          Withdraw
        </button>
      </div>

      <%!-- Selecting a passage offers to make a card of it, with the link
            written into both ends. A doc is where a backlog comes from. --%>
      <button
        :if={@can_write}
        id="selection-to-card"
        type="button"
        hidden
        class="btn btn-primary btn-xs absolute z-40 gap-1 shadow-lg"
        style="position: absolute"
      >
        <.icon name="hero-plus" class="size-3" /> Make a card
      </button>
      <%!-- The card facets this page carries. They are set on the board — in
            the page's panel, or by dragging it onto an axis — because that is
            the only place they mean anything. --%>
      <div :if={facets(@page) != []} class="mt-4 flex flex-wrap items-center gap-1.5">
        <span :for={{label, title} <- facets(@page)} class="chip chip-line text-xs" title={title}>
          {label}
        </span>
      </div>

      <div
        id="wiki-body"
        phx-hook="WikiSelection"
        data-button="selection-to-card"
        class="wiki-prose mt-6"
      >
        {Phoenix.HTML.raw(@html)}
      </div>

      <%!-- The cards this page is about. The other half of the card panel's
            Docs section: a document and the work it describes have to be one
            click from each other in both directions, and a pinned link is
            what survives the prose being rewritten. --%>
      <section
        :if={@cards != [] or @can_write}
        class="mt-10 border-t border-base-300 pt-6"
        id="page-cards"
      >
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          Cards this is about
        </h2>
        <ul :if={@cards != []} class="mt-3 space-y-1">
          <li :for={link <- @cards} class="flex items-center gap-2 text-sm">
            <.icon
              name={if link.pinned, do: "hero-bookmark", else: "hero-rectangle-stack"}
              class={[
                "size-3.5 shrink-0",
                if(link.pinned, do: "text-primary", else: "text-base-content/40")
              ]}
            />
            <.link
              navigate={~p"/boards/#{link.target_card.board_id}/cards/#{link.target_card_id}"}
              class={[
                "min-w-0 flex-1 truncate hover:underline",
                link.target_card.completed && "text-base-content/60 line-through"
              ]}
            >
              {link.target_card.title}
            </.link>
            <span class="shrink-0 font-mono text-2xs text-base-content/40">
              #{link.target_card_id}
            </span>
            <button
              :if={@can_write}
              type="button"
              class="btn btn-ghost btn-xs btn-square"
              phx-click="toggle_pin_card"
              phx-value-id={link.target_card_id}
              title={if link.pinned, do: "Unpin", else: "Pin: this is the doc for that card"}
            >
              <.icon
                name={if link.pinned, do: "hero-bookmark-slash", else: "hero-bookmark"}
                class="size-3.5"
              />
            </button>
            <button
              :if={@can_write and link.count == 0}
              type="button"
              class="btn btn-ghost btn-xs btn-square"
              phx-click="detach_card"
              phx-value-id={link.target_card_id}
              title="Detach this card"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </li>
        </ul>
        <p :if={@cards == []} class="mt-3 text-sm text-base-content/50">
          This page isn't attached to a card yet.
        </p>
        <form
          :if={@can_write}
          id="page-card-search"
          phx-change="card_search"
          phx-submit="card_search"
          class="relative mt-3 max-w-sm"
        >
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
          />
          <input
            type="search"
            name="q"
            value={@card_query}
            placeholder="Attach a card…"
            phx-debounce="200"
            autocomplete="off"
            class="input input-sm w-full rounded-full pl-8"
          />
        </form>
        <ul :if={@card_results != []} class="mt-1 max-w-sm space-y-0.5">
          <li :for={card <- @card_results}>
            <button
              type="button"
              phx-click="attach_card"
              phx-value-id={card.id}
              class="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm hover:bg-base-200"
            >
              <.icon name="hero-plus" class="size-3.5 shrink-0 text-base-content/40" />
              <span class="min-w-0 flex-1 truncate">{card.title}</span>
              <span class="shrink-0 font-mono text-2xs text-base-content/40">#{card.id}</span>
            </button>
          </li>
        </ul>
      </section>

      <section :if={@children != []} class="mt-10 border-t border-base-300 pt-6">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          Pages under this one
        </h2>
        <ul class="mt-3 space-y-1">
          <li :for={child <- @children}>
            <.link
              navigate={page_path(@board, child)}
              class="flex items-baseline gap-2 rounded-lg px-2 py-1.5 hover:bg-base-200"
            >
              <.icon name="hero-document-text" class="size-3.5 shrink-0 text-base-content/40" />
              <span class="font-medium">{child.title}</span>
              <span :if={summary_of(child) != ""} class="truncate text-sm text-base-content/50">
                {summary_of(child)}
              </span>
            </.link>
          </li>
        </ul>
      </section>

      <%!-- Backlinks are always shown, whether or not the page asked for them
            with [[!backlinks]]: what points here is part of what a page means. --%>
      <section :if={@backlinks != []} class="mt-10 border-t border-base-300 pt-6">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          Linked from
        </h2>
        <ul class="mt-3 flex flex-wrap gap-2">
          <li :for={link <- @backlinks}>
            <.link navigate={page_path(@board, link.page)} class="chip chip-line hover:bg-base-200">
              {link.page.title}
            </.link>
          </li>
        </ul>
      </section>

      <div :if={@tags != []} class="mt-6 flex flex-wrap gap-1.5">
        <span :for={tag <- @tags} class="chip chip-line text-xs">{tag.name}</span>
      </div>

      <%!-- The card contents a page carries: a checklist, links, fields,
            votes, reported health and comments. The same components the card
            panel draws, because they are the same rows in the same tables
            (see `Slipdock.Boards.Owned`). This is the document's own view, so
            there are no keyboard section keys. --%>
      <section class="mt-10 space-y-8 border-t border-base-300 pt-6">
        <%!-- A grid of equal panels rather than one tall rail beside the
              prose: these are short, and a skinny column of them runs on
              far below everything else on the page. --%>
        <div class="grid items-start gap-4 sm:grid-cols-2 xl:grid-cols-3">
          <div class="min-w-0 rounded-xl bg-base-100 p-4 ring-1 ring-base-content/5">
            <.status_section item={@page} can_write={@can_write} form_key={@form_key} />
          </div>
          <div class="min-w-0 rounded-xl bg-base-100 p-4 ring-1 ring-base-content/5">
            <.checklist_section item={@page} can_write={@can_write} form_key={@form_key} />
          </div>
          <div class="min-w-0 rounded-xl bg-base-100 p-4 ring-1 ring-base-content/5">
            <.urls_section item={@page} can_write={@can_write} form_key={@form_key} />
          </div>
          <div
            :if={@fields_board && @fields_board.fields != []}
            class="min-w-0 rounded-xl bg-base-100 p-4 ring-1 ring-base-content/5"
          >
            <.fields_section item={@page} board={@fields_board} can_write={@can_write} />
          </div>
          <div class="min-w-0 rounded-xl bg-base-100 p-4 ring-1 ring-base-content/5">
            <.vote_box
              item={@page}
              board={@board}
              current_user={@current_user}
              can_write={@can_write}
            />
          </div>
        </div>

        <.comments_section
          item={@page}
          board={@board}
          current_user={@current_user}
          can_write={@can_write}
          form_key={@form_key}
        />
      </section>

      <footer class="mt-10 border-t border-base-300 pt-4 text-xs text-base-content/50">
        Last edited {stamp(@page.updated_at)}
        <.link navigate={~p"/boards/#{@board}/wiki/#{@page.slug}/history"} class="link">
          see history
        </.link>
      </footer>
    </article>
    """
  end

  attr :form, :any, required: true
  attr :page, :any, default: nil
  attr :board, :any, required: true
  attr :preview, :string, default: ""
  attr :conflict, :any, default: nil
  attr :base_hash, :string, default: nil
  attr :uploads, :any, required: true
  attr :column, :any, default: nil, doc: "the list a new page will be placed in"
  attr :outline, :list, default: [], doc: "the board's folders, for the Folder picker"

  defp editor(assigns) do
    ~H"""
    <.form for={@form} id="page-form" phx-change="validate" phx-submit="save" class="space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight">
            {if @page, do: "Editing #{@page.title}", else: "New page"}
          </h1>
          <%!-- Started from the foot of a list: say so, since the page will
                appear there as a card the moment it is saved. --%>
          <p :if={@column} class="mt-0.5 flex items-center gap-1.5 text-xs text-base-content/60">
            <.icon name="hero-view-columns" class="size-3.5" />
            It will sit on the board in <span class="font-medium">{@column.name}</span>.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.link
            navigate={if @page, do: page_path(@board, @page), else: wiki_path(@board)}
            class="btn btn-ghost btn-sm"
          >
            Cancel
          </.link>
          <button type="submit" class="btn btn-primary btn-sm">Save</button>
        </div>
      </div>

      <div
        :if={@conflict}
        class="rounded-xl border border-rose-500/40 bg-rose-500/10 p-4 text-sm"
      >
        <div class="flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-rose-600" />
          <div class="min-w-0 flex-1">
            <p class="font-medium">
              This page changed while you were writing. Nothing has been overwritten.
            </p>
            <p class="mt-1 text-base-content/70">
              Below is the page as it now stands. Merge what you need into your text, then save
              again.
            </p>
            <pre
              class="kanban-scroll mt-3 max-h-64 overflow-auto rounded-lg bg-base-100 p-3 text-xs"
              phx-no-curly-interpolation
            ><%= @conflict.body %></pre>
          </div>
          <button type="button" phx-click="dismiss_conflict" class="btn btn-ghost btn-xs btn-square">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>

      <input :if={@base_hash} type="hidden" name="page[base_hash]" value={@base_hash} />

      <%!-- A new page has an empty title and that is what you came to type;
            an edit has one already, and stealing the cursor from the body
            would be wrong. --%>
      <.input
        field={@form[:title]}
        type="text"
        label="Title"
        required
        phx-hook={is_nil(@page) && "Focus"}
        id={is_nil(@page) && "new-page-title"}
      />
      <.input
        field={@form[:summary]}
        type="text"
        label="Summary"
        placeholder="One line, shown in listings and search"
      />

      <div class="grid gap-4 lg:grid-cols-2">
        <div id="page-body-paste" phx-hook="PasteImage" data-upload="page_image">
          <label for="page_body" class="mb-1 block text-sm font-medium">
            Body (Markdown)
            <span class="ml-1 font-normal text-base-content/50">— paste or drop an image to attach it</span>
          </label>
          <textarea
            id="page_body"
            name="page[body]"
            rows="24"
            class="w-full rounded-xl border border-base-300 bg-base-100 p-3 font-mono text-sm leading-relaxed focus:border-primary focus:outline-none"
            phx-debounce="200"
          ><%= Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value) %></textarea>
          <.live_file_input upload={@uploads.page_image} class="hidden" />
        </div>
        <div class="hidden lg:block">
          <p class="mb-1 text-sm font-medium">Preview</p>
          <div class="wiki-prose kanban-scroll max-h-[36rem] overflow-y-auto rounded-xl border border-base-300 bg-base-100 p-4">
            {Phoenix.HTML.raw(@preview)}
          </div>
        </div>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div>
          <label for="edit-message" class="mb-1 block text-sm font-medium">
            Why this edit <span class="font-normal text-base-content/50">(optional)</span>
          </label>
          <input
            id="edit-message"
            type="text"
            name="message"
            placeholder="Recorded in the page's history"
            class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm focus:border-primary focus:outline-none"
          />
        </div>
        <.input
          field={@form[:status]}
          type="select"
          label="Status"
          options={[{"Published", "published"}, {"Draft — only writers can see it", "draft"}]}
        />
        <%!-- Where it is filed. Offered here so a page can be put away at the
              moment it is written, rather than written and then found again. --%>
        <.folder_picker
          id="editor-folder-picker"
          label="Folder"
          name={@form[:folder_id].name}
          selected={@form[:folder_id].value}
          outline={@outline}
        />
      </div>
    </.form>
    """
  end

  attr :board, :any, required: true
  attr :page, :any, required: true
  attr :revisions, :list, required: true

  defp history_body(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-2">
      <h1 class="text-xl font-bold tracking-tight">History of {@page.title}</h1>
      <.link navigate={page_path(@board, @page)} class="btn btn-ghost btn-sm">Back to the page</.link>
    </div>

    <ul class="mt-6 divide-y divide-base-300 rounded-xl border border-base-300 bg-base-100">
      <li :for={revision <- @revisions}>
        <.link
          navigate={~p"/boards/#{@board}/wiki/#{@page.slug}/history/#{revision.id}"}
          class="flex flex-wrap items-baseline gap-x-3 gap-y-1 px-4 py-3 hover:bg-base-200"
        >
          <span class="w-40 shrink-0 text-sm text-base-content/60">{stamp(revision.inserted_at)}</span>
          <span class="font-medium">{author_label(revision)}</span>
          <span :if={revision.via && revision.via != "web"} class="chip chip-line text-2xs">
            {via_label(revision.via)}{if revision.agent, do: " · #{revision.agent}"}
          </span>
          <span :if={revision.summary} class="min-w-0 flex-1 truncate text-sm text-base-content/60">
            {revision.summary}
          </span>
          <span class="shrink-0 text-xs text-base-content/40">{revision.byte_size} bytes</span>
        </.link>
      </li>
    </ul>
    """
  end

  attr :board, :any, required: true
  attr :page, :any, required: true
  attr :revision, :any, default: nil
  attr :diff, :list, default: []
  attr :can_write, :boolean, required: true

  defp revision_body(assigns) do
    ~H"""
    <div :if={is_nil(@revision)} class="py-16 text-center text-base-content/60">
      No such revision.
    </div>

    <div :if={@revision}>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h1 class="text-xl font-bold tracking-tight">{@revision.title}</h1>
          <p class="mt-1 text-sm text-base-content/60">
            {stamp(@revision.inserted_at)} · {author_label(@revision)} {via_label(@revision.via)}
            <span :if={@revision.summary}>— {@revision.summary}</span>
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/boards/#{@board}/wiki/#{@page.slug}/history"}
            class="btn btn-ghost btn-sm"
          >
            All versions
          </.link>
          <button
            :if={@can_write}
            type="button"
            phx-click="revert"
            data-confirm="Put the page back to this version? The current text is kept in history."
            class="btn btn-sm"
          >
            Restore this version
          </button>
        </div>
      </div>

      <div class="mt-6 overflow-hidden rounded-xl border border-base-300 bg-base-100 font-mono text-xs">
        <div :for={{op, lines} <- @diff}>
          <%!-- The marker and the line are joined in Elixir rather than
                interpolated twice, so no template whitespace can land inside
                the pre-wrapped span. --%>
          <div
            :for={line <- lines}
            class={[
              "px-3 py-0.5",
              op == :ins && "bg-emerald-500/10 text-emerald-900",
              op == :del && "bg-rose-500/10 text-rose-900 line-through",
              op == :eq && "text-base-content/50"
            ]}
          >
            <span class="whitespace-pre-wrap">{diff_marker(op) <> line}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp diff_marker(:ins), do: "+ "
  defp diff_marker(:del), do: "- "
  defp diff_marker(_), do: "  "
end
