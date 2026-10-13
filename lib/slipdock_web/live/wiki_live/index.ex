defmodule SlipdockWeb.WikiLive.Index do
  @moduledoc """
  A board's wiki: the tree of pages down the side, one page in the middle.

  One LiveView covers reading, writing and history because they share the
  tree and the breadcrumb, and a document is a thing you flip between those
  three states on without losing your place.

  The editor is raw Markdown with a preview beside it (which a writer can
  turn off) — deliberately, and
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
  alias Slipdock.Wiki.{Folder, Page, Tree, TreeStates}
  alias SlipdockWeb.Params
  alias SlipdockWeb.Wiki.Renderer

  # How much the tree asks for at once: a page of a big folder's rows, and
  # at most this many open containers in one go.
  @tree_page 500
  @tree_max_keys 300
  # A wiki this small opens with every folder open on a first visit, as the
  # tree always did; a bigger one opens only the way to what is shown.
  @tree_small 300
  # What the middle column lists of a folder, and of each on the index.
  @folder_listing 200
  @index_pages 8

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
         meetings: Slipdock.Meetings.presence(socket.assigns.current_user, board),
         page: nil,
         revision: nil,
         form: nil,
         preview: "",
         # The editor's preview beside the source; a writer can put it away
         # for the whole width, and the browser remembers (EditorPrefs).
         show_preview: true,
         conflict: nil,
         base_hash: nil,
         new_parent: nil,
         new_column: nil,
         new_folder: nil,
         # Filing (see `Slipdock.Wiki.Folder`): every folder, for the pickers.
         all_folders: [],
         folder_outline: [],
         # The tree down the side is drawn by the WikiTree hook, which asks
         # for one container at a time (`tree_load`, `tree_children`; see
         # `Slipdock.Wiki.Tree`). The server keeps what the hook cannot: a
         # version it bumps when the tree should be asked for again (a
         # filter, a toggle, a change by anyone), what the filter bar lets
         # through, and whether it is this board's tree or its vault's.
         tree_version: 0,
         tree_filter: nil,
         # Whether the search box looks inside pages too, not only at names.
         tree_contents: false,
         # A page the tree's keyboard is renaming (F2) or archiving (Delete).
         tree_prompt: nil,
         # On a phone the tree is a drawer, shut until asked for (R11.11).
         tree_drawer: false,
         tree_scope: "board",
         tree_empty: true,
         tree_current: "",
         tree_reveal: [],
         vault: Slipdock.Vaults.for_board(board),
         # The middle column's own listings: the index's folders and recent
         # pages, or what is in the folder being looked at.
         index_folders: [],
         recent: [],
         folder_rows: [],
         folder_more: false,
         excerpts: %{},
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
         # The version a revision is compared with (nil: nothing before it),
         # whether the reader chose it, and the page's newest version.
         base: nil,
         comparing: false,
         latest_revision: nil,
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
       |> load_tree_state()}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have access to that board.")
       |> push_navigate(to: ~p"/")}
    end
  end

  # Everything the tree is drawn from that is not its rows: the counts, what
  # the filter bar lets through, the folders for the pickers. Then the
  # version goes up, which is the WikiTree hook's cue to ask for the rows it
  # shows again. No page is loaded whole for any of it, and without a filter
  # none is loaded at all.
  #
  # The filter bar's search matches the filing as well as what is filed: a
  # folder whose name matches is a hit, and everything in it comes with it,
  # because "where are the design decisions" is the question somebody typing
  # the name of a folder is asking (see `Slipdock.Wiki.Tree.filter/3`).
  defp load_tree(socket), do: socket |> load_tree_state() |> assign_listing()

  # Mount reads the state alone: the listing comes with `handle_params`,
  # which knows which view it is for.
  defp load_tree_state(socket) do
    %{board: board, filters: filters} = socket.assigns
    folders = Wiki.folders(board)
    opts = tree_opts(socket.assigns)
    total = Tree.count(board, opts)
    filtering = Slipdock.Filters.any?(filters)

    filter =
      if filtering,
        do:
          Tree.filter(
            board,
            filters,
            [folders: folders, contents: socket.assigns.tree_contents] ++ opts
          )

    shown = if filter, do: filter.shown, else: total

    socket
    |> assign(
      all_folders: folders,
      # Paths and depths worked out once, in memory, for every picker on the
      # page (see `SlipdockWeb.FolderPicker`).
      folder_outline: Slipdock.Wiki.Folders.outline(folders),
      tree_filter: filter,
      tree_empty: total == 0 and folders == [],
      shown: shown,
      hidden: total - shown,
      filtering: filtering
    )
    |> update(:tree_version, &(&1 + 1))
  end

  # `as`: whose tree it is, which decides the pages also filed in a folder
  # that it shows (W-103 R12.2).
  defp tree_opts(%{can_write: can_write, show: show} = assigns),
    do: list_opts(can_write, show) ++ [as: assigns[:current_user]]

  # A container's rows on this board, as the tree draws them: from what the
  # filter left when one is on, from the database when not.
  defp tree_rows(socket, key, extra) do
    case socket.assigns.tree_filter do
      %{nodes: nodes} ->
        {:ok, Map.get(nodes, key, [])}

      nil ->
        with {:ok, ref} <- Tree.parse_ref(key),
             do: Tree.children(socket.assigns.board, ref, tree_opts(socket.assigns) ++ extra)
    end
  end

  # The middle column's listings, read only for the view that draws them.
  defp assign_listing(%{assigns: %{live_action: :index, folder: %Folder{} = folder}} = socket) do
    rows =
      case tree_rows(socket, "folder:#{folder.id}", limit: @folder_listing) do
        {:ok, rows} -> rows
        _ -> []
      end

    {more, rows} = Enum.split_with(rows, &(&1.kind == "more"))
    pages = for %{kind: "page", id: id} <- rows, do: id

    assign(socket,
      folder_rows: rows,
      folder_more: more != [],
      excerpts: Tree.excerpts(pages)
    )
  end

  defp assign_listing(%{assigns: %{live_action: :index}} = socket) do
    # The folders and their counts are read once for every card on the index.
    prepared =
      Tree.prepare(socket.assigns.board,
        folders: socket.assigns.all_folders,
        status: tree_opts(socket.assigns)[:status],
        template: tree_opts(socket.assigns)[:template],
        archived: tree_opts(socket.assigns)[:archived]
      )
      |> Keyword.take([:folders, :stats])

    {:ok, top} = tree_rows(socket, "root", prepared)

    index_folders =
      for %{kind: "folder"} = folder <- top do
        inner =
          case tree_rows(socket, "folder:#{folder.id}", [limit: @index_pages] ++ prepared) do
            {:ok, rows} -> rows
            _ -> []
          end

        %{
          folder: folder,
          children: Enum.filter(inner, &(&1.kind == "folder")),
          pages: inner |> Enum.filter(&(&1.kind == "page")) |> Enum.take(@index_pages),
          more: Enum.any?(inner, &(&1.kind == "more"))
        }
      end

    only = socket.assigns.tree_filter && socket.assigns.tree_filter.only
    recent = Tree.recent(socket.assigns.board, [only: only] ++ tree_opts(socket.assigns), 8)

    assign(socket,
      index_folders: index_folders,
      recent: recent,
      excerpts: Tree.excerpts(Enum.map(recent, & &1.id))
    )
  end

  defp assign_listing(socket), do: socket

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
    # Opening something from the drawer shuts it: the page is what was asked
    # for.
    socket =
      apply_action(
        assign(socket, folder: nil, tree_drawer: false),
        socket.assigns.live_action,
        params
      )

    {:noreply, assign_current(socket)}
  end

  # What the tree highlights, and the way to it: a page is opened in place,
  # so the hook opens the folders leading to it here as well as on a fresh
  # visit (one reached by a link in a note may sit in a folder the reader
  # shut). Worked out for the tree the reader has on screen, the board's or
  # the vault's.
  defp assign_current(socket) do
    current =
      case socket.assigns do
        %{page: %Page{id: id}} -> "page:#{id}"
        %{folder: %Folder{id: id}} -> "folder:#{id}"
        _ -> ""
      end

    assign(socket, tree_current: current, tree_reveal: reveal_keys(socket))
  end

  defp reveal_keys(socket) do
    item =
      case socket.assigns do
        %{page: %Page{} = page} -> page
        %{folder: %Folder{} = folder} -> folder
        _ -> nil
      end

    case {item, socket.assigns.tree_scope, socket.assigns.vault} do
      {nil, _, _} ->
        []

      {item, "vault", %{} = vault} ->
        Tree.vault_path_to(vault, item, vault_boards(socket))

      {%Page{} = page, _, _} ->
        page |> Tree.path_to(socket.assigns.all_folders) |> Enum.map(&Tree.ref_key/1)

      {%Folder{} = folder, _, _} ->
        folder
        |> Tree.path_to_folder(socket.assigns.all_folders)
        |> Enum.map(&Tree.ref_key/1)
    end
  end

  # The vault's boards this reader may open, each with the options its tree
  # is read with: drafts and archived pages only where they can write.
  defp vault_boards(%{assigns: %{vault: nil}}), do: %{}

  defp vault_boards(socket) do
    %{vault: vault, current_user: user, show: show} = socket.assigns

    vault
    |> Slipdock.Vaults.board_ids()
    |> Enum.flat_map(fn id ->
      case Slipdock.Repo.get(Slipdock.Boards.Board, id) do
        nil ->
          []

        board ->
          perm = Access.board_permission(user, board)

          if Access.can_read?(perm),
            do: [{id, {board, list_opts(Access.can_write?(perm), show) ++ [as: user]}}],
            else: []
      end
    end)
    |> Map.new()
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

    socket
    |> assign(page: nil, revision: nil, folder: folder, page_title: title)
    |> assign_wanted()
    |> assign_listing()
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

  # The wanted pages are drawn on the index alone, so they are worked out
  # only when it is what is showing: an open page never pays for them.
  defp assign_wanted(%{assigns: %{page: nil, board: board}} = socket),
    do: assign(socket, wanted: Wiki.wanted(board))

  defp assign_wanted(socket), do: assign(socket, wanted: [])

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

  # A revision against the one before it, or with `?against=<id>` against
  # any other version of the same page: the history's compare picker and
  # "Compare with current" both come here.
  defp apply_page_action(socket, :revision, %{"rev" => rev} = params) do
    page = socket.assigns.page

    case Wiki.get_revision(page, rev) do
      {:ok, revision} ->
        {base, comparing, socket} = compare_base(socket, page, revision, params["against"])
        before = if base, do: base.body, else: ""

        assign(socket,
          revision: revision,
          base: base,
          comparing: comparing,
          latest_revision: List.first(Wiki.list_revisions(page, 1)),
          diff: Wiki.split_diff(before, revision.body)
        )

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

  # How long a change waits for the rest of its burst (see the
  # `:wiki_changed` handler). Short enough that one edit still shows at once.
  @reload_after_ms Application.compile_env(:slipdock, :wiki_reload_after_ms, 300)

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
       |> push_patch(to: ~p"/boards/#{socket.assigns.board}/wiki")}
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
       |> push_patch(to: ~p"/boards/#{socket.assigns.board}/wiki")}
    else
      false -> {:noreply, put_flash(socket, :error, "Only the board's owner can delete a page.")}
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be deleted.")}
    end
  end

  # Either way round the picker is filled in, the older version goes on the
  # left: the history lists newest first, so the later position is older.
  def handle_event("compare", %{"from" => from, "to" => to}, socket) when from != to do
    ids = Enum.map(socket.assigns.revisions, &to_string(&1.id))

    case {Enum.find_index(ids, &(&1 == from)), Enum.find_index(ids, &(&1 == to))} do
      {i, j} when is_integer(i) and is_integer(j) ->
        {newer, older} = if i < j, do: {from, to}, else: {to, from}
        board = socket.assigns.board
        slug = socket.assigns.page.slug

        {:noreply,
         push_patch(socket,
           to: ~p"/boards/#{board}/wiki/#{slug}/history/#{newer}?against=#{older}"
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Pick two versions from the list to compare.")}
    end
  end

  def handle_event("compare", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Pick two different versions to compare.")}

  def handle_event("revert", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         revision when not is_nil(revision) <- socket.assigns.revision,
         {:ok, page} <-
           Wiki.revert_page(page, revision, user: socket.assigns.current_user, via: "web") do
      {:noreply,
       socket
       |> put_flash(:info, "Put “#{page.title}” back to that version.")
       |> push_patch(to: ~p"/boards/#{socket.assigns.board}/wiki/#{page.slug}")}
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
         %{} = card <- Boards.get_card(Params.id(id)),
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
         %{} = card <- Boards.get_card(Params.id(id)),
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
         %{} = card <- Boards.get_card(Params.id(id)),
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
    socket = assign_scope(socket, params["scope"])
    scope = socket.assigns.tree_scope
    root = if scope == "vault", do: "vault", else: "root"
    filter = scope_filter(socket, scope)

    kept =
      if is_list(params["keys"]),
        do: nil,
        else: TreeStates.get(socket.assigns.current_user, tree_state_scope(socket))

    {nodes, reveal} =
      if filter do
        {filter.nodes, []}
      else
        reveal = socket.assigns.tree_reveal

        keys =
          cond do
            params["all"] == true -> [root | all_container_keys(socket, scope)]
            params["only"] == true -> keys_param(params["keys"])
            true -> [root | keys_param(params["keys"] || kept) ++ reveal]
          end

        {load_nodes(
           socket,
           scope,
           keys |> Enum.uniq() |> Enum.take(@tree_max_keys),
           through(socket, params, root)
         ), reveal}
      end

    {:reply,
     %{
       scope: scope,
       root: root,
       filtering: filter != false and filter != nil,
       nodes: Map.new(nodes, fn {key, rows} -> {key, client_rows(rows, socket)} end),
       reveal: reveal,
       # How the top of this board's tree is sorted, for its menu.
       sort: socket.assigns.board.wiki_sort || "manual",
       # What was kept of this tree's open folders: the hook's open set, or
       # nil the first time, when a small wiki opens whole.
       open: kept && Enum.filter(kept, &Map.has_key?(nodes_map(nodes), &1)),
       small: socket.assigns.shown + socket.assigns.hidden <= @tree_small
     }, socket}
  end

  # The hook saying what is open now, after a folder is opened or shut.
  def handle_event("tree_open", %{"keys" => keys} = params, socket) when is_list(keys) do
    socket = assign_scope(socket, params["scope"])
    TreeStates.put(socket.assigns.current_user, tree_state_scope(socket), keys)
    {:noreply, socket}
  end

  def handle_event("tree_open", _params, socket), do: {:noreply, socket}

  # The next page of a big container's rows, from the "more" row the hook
  # scrolled into view.
  def handle_event("tree_children", %{"key" => key} = params, socket) when is_binary(key) do
    offset = max(Params.id(to_string(params["offset"] || 0)) || 0, 0)
    socket = assign_scope(socket, params["scope"])

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
      {:noreply, socket |> tree_move(kind, id, into, before) |> load_tree() |> assign_current()}
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
    with %Folder{} = folder <- tree_item(socket, "folder:#{id}") do
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
    # A folder being renamed was checked when its dialog opened; a new one
    # goes on this board, which takes a writer.
    board_id = if modal && modal.folder, do: modal.folder.board_id, else: socket.assigns.board.id

    result =
      cond do
        is_nil(modal) or (is_nil(modal.folder) and not socket.assigns.can_write) ->
          {:error, :forbidden, "You can't write on this board."}

        not (is_nil(parent_id) or match?(%Folder{board_id: ^board_id}, Wiki.get_folder(parent_id))) ->
          {:error, :unprocessable_entity,
           "A folder can only go inside a folder on its own board."}

        is_nil(modal.folder) ->
          Wiki.create_folder(socket.assigns.board, %{
            "name" => name,
            "parent_id" => parent_id || (modal.parent && modal.parent.id)
          })

        true ->
          Wiki.update_folder(modal.folder, %{"name" => name, "parent_id" => parent_id})
      end

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
    with %Folder{} = folder <- tree_item(socket, "folder:#{id}") do
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
        id -> tree_item(socket, "folder:#{id}")
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

        "archive" when pages != [] ->
          %{kind: :archive_many, items: pages}

        "tag" when pages != [] ->
          %{
            kind: :tag_many,
            items: pages,
            tags: Boards.list_tags(Slipdock.Boards.Board.root_id(socket.assigns.board))
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

  # "Move to…": what is on the target's board moves there at once; pages
  # bound for another board of the vault wait for the confirmation of what
  # goes with them. Folders move within their own board.
  def handle_event("move_to", %{"target" => target}, socket) do
    with %{kind: :move, items: items} <- socket.assigns.tree_prompt,
         {:folder, board, folder} <- drop_target(socket, target) do
      {here, there} = Enum.split_with(items, &(&1.board_id == board.id))
      user = socket.assigns.current_user

      moved =
        Enum.count(here, fn
          %Page{} = page ->
            with {:ok, page} <- Wiki.file_page(page, folder),
                 {:ok, _} <- Wiki.move_page(page, nil, :bottom, user: user, via: "web"),
                 do: true,
                 else: (_ -> false)

          %Folder{} = moving ->
            match?({:ok, _}, Wiki.move_folder(moving, folder, nil))
        end)

      folders_left = for %Folder{} = f <- there, do: f.name
      pages_there = for %Page{} = p <- there, do: p

      socket =
        socket
        |> assign(tree_prompt: nil)
        |> then(
          &if(moved > 0, do: put_flash(&1, :info, "Moved #{count(moved, "item")}."), else: &1)
        )
        |> then(fn socket ->
          if folders_left != [],
            do:
              put_flash(
                socket,
                :error,
                "A folder moves within its own board: #{Enum.join(folders_left, ", ")} stayed."
              ),
            else: socket
        end)
        |> load_tree()
        |> assign_current()

      {:noreply,
       if(pages_there != [],
         do: cross_move_prompt(socket, pages_there, board, folder, nil),
         else: socket
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "Those couldn't be moved there.")}
    end
  end

  def handle_event("confirm_cross_move", _params, socket) do
    with %{kind: :cross_move, pages: pages, board: board, folder: folder, parent: parent} <-
           socket.assigns.tree_prompt do
      user = socket.assigns.current_user

      results =
        for page <- pages do
          with {:ok, moved} <- Slipdock.Wiki.Move.to_board(page, board, folder, user, via: "web") do
            if parent, do: Wiki.move_page(moved, parent, :bottom, user: user, via: "web")
            {:ok, moved}
          end
        end

      moved = for {:ok, page} <- results, do: page

      socket =
        socket
        |> assign(tree_prompt: nil)
        |> put_flash(:info, "Moved #{count(length(moved), "page")} to #{board.name}.")
        |> load_tree()

      # The page being read went with them: follow it to its new board.
      {:noreply,
       case Enum.find(moved, &(socket.assigns.page && &1.id == socket.assigns.page.id)) do
         nil -> assign_current(socket)
         page -> push_navigate(socket, to: ~p"/boards/#{board}/wiki/#{page.slug}")
       end}
    else
      _ -> {:noreply, socket}
    end
  end

  # "Also file in…": a placement beside the page's home (W-103 R12).
  def handle_event("also_file_in", %{"target" => target}, socket) do
    with %{kind: :also, items: [page]} <- socket.assigns.tree_prompt,
         {:folder, _board, %Folder{} = folder} <- drop_target(socket, target),
         {:ok, _} <- Slipdock.Wiki.Placements.add(page, folder, socket.assigns.current_user) do
      {:noreply,
       socket
       |> assign(tree_prompt: nil)
       |> put_flash(:info, "“#{page.title}” is also filed in #{Wiki.folder_path(folder)}.")
       |> load_tree()}
    else
      {:error, _status, message} -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be filed there.")}
    end
  end

  def handle_event("bulk_archive", _params, socket) do
    with %{kind: :archive_many, items: pages} <- socket.assigns.tree_prompt do
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
    else
      _ -> {:noreply, socket}
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

  # "Take out of this folder", on a page's extra placement (R12.4: the page
  # itself stays where it is).
  def handle_event("remove_placement", %{"id" => id, "folder" => folder_id}, socket) do
    with %Page{} = page <- tree_item(socket, "page:#{id}"),
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
      path = ~p"/boards/#{board}/wiki/#{page.slug}"

      {:noreply,
       if(board.id == socket.assigns.board.id,
         do: socket |> load_tree() |> push_patch(to: path),
         else: push_navigate(socket, to: path)
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "A drawing couldn't be made there.")}
    end
  end

  # The tree as a drawer, on a screen too narrow to keep it beside the page.
  def handle_event("toggle_tree_drawer", _params, socket),
    do: {:noreply, update(socket, :tree_drawer, &(not &1))}

  def handle_event("close_tree_drawer", _params, socket),
    do: {:noreply, assign(socket, tree_drawer: false)}

  # The search box reads names; this has it read the pages' words too.
  def handle_event("toggle_tree_contents", _params, socket),
    do: {:noreply, socket |> update(:tree_contents, &(not &1)) |> load_tree()}

  def handle_event("filter_tag", %{"id" => id}, socket) do
    case Params.id(id) do
      nil ->
        {:noreply, socket}

      id ->
        tags = socket.assigns.filters.tags
        {:noreply, put_filter(socket, :tags, if(id in tags, do: tags -- [id], else: [id | tags]))}
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
      else:
        contents_event(
          socket,
          &Boards.add_comment(&1, String.trim(body), by: socket.assigns.current_user)
        )
  end

  # The page's own view has no paste-an-image upload on the comment box, so
  # the change event the shared form sends has nothing to do here.
  def handle_event("comment_change", _params, socket), do: {:noreply, socket}

  def handle_event("delete_comment", %{"id" => id}, socket) do
    contents_event(socket, fn page ->
      if Enum.any?(page.comments, &(to_string(&1.id) == id)),
        do: Boards.delete_comment(Params.id(id))
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
        do: Boards.delete_status_update(Params.id(id))
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
        with count when is_integer(count) <- Params.int(count),
             {:ok, _} <- Votes.set(page, user, count) do
          {:noreply, reload_page(socket)}
        else
          nil -> {:noreply, socket}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("place", %{"column" => column_id}, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         column_id when is_integer(column_id) <- Params.id(column_id),
         {:ok, placed} <- Wiki.place(page, column_id) do
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

  ## The tree's rows ----------------------------------------------------------

  # A page the tree's keyboard acts on: on a board the reader can write to.
  defp tree_page(socket, id), do: tree_item(socket, "page:#{id}")

  # A filter in the vault's tree filters every board of it (R11.5), worked out
  # when asked for; this board's is worked out with the filter bar.
  defp scope_filter(%{assigns: %{tree_filter: nil}}, _scope), do: nil

  defp scope_filter(socket, "vault") do
    Tree.vault_filter(socket.assigns.vault, vault_boards(socket), socket.assigns.filters,
      contents: socket.assigns.tree_contents
    )
  end

  defp scope_filter(socket, _board), do: socket.assigns.tree_filter

  # The tree the hook asked for: this board's, or — on a board in a vault —
  # the vault's. Anything else is this board's. A changed scope changes the
  # way to the current page too.
  defp assign_scope(socket, scope) do
    scope = if scope == "vault" and socket.assigns.vault, do: "vault", else: "board"

    if scope == socket.assigns.tree_scope,
      do: socket,
      else: socket |> assign(tree_scope: scope) |> assign_current()
  end

  # The page the rows of its container must reach, however far down a big
  # folder it is: the one asked for (`through`, when the hook reveals the
  # page being read), or else the page being read, in its own container.
  defp through(_socket, %{"through" => "page:" <> id, "keys" => [key | _]}, _root) do
    case Params.id(id) do
      nil -> nil
      id -> {key, id}
    end
  end

  defp through(%{assigns: %{page: %Page{id: id}, tree_reveal: reveal}}, _params, root),
    do: {List.last(reveal) || root, id}

  defp through(_socket, _params, _root), do: nil

  defp nodes_map(nodes) when is_map(nodes), do: nodes
  defp nodes_map(nodes), do: Map.new(nodes)

  # Which kept open set this tree is: the board's own, or its vault's.
  defp tree_state_scope(%{assigns: %{tree_scope: "vault", vault: %{id: id}}}),
    do: TreeStates.scope(:vault, id)

  defp tree_state_scope(%{assigns: %{board: board}}), do: TreeStates.scope(:board, board.id)

  defp keys_param(keys) when is_list(keys), do: Enum.filter(keys, &is_binary/1)
  defp keys_param(_), do: []

  # Each asked-for container's rows, the board's folders and counts read
  # once for all of them. A key that is gone, or not this reader's, is left
  # out, and the hook stops asking for it.
  defp load_nodes(socket, "vault", keys, through) do
    boards = vault_boards(socket)

    for key <- keys,
        extra = [limit: @tree_page] ++ through_opt(through, key),
        {:ok, rows} <- [Tree.vault_children(socket.assigns.vault, key, boards, extra)],
        do: {key, rows}
  end

  defp load_nodes(socket, _board, keys, through) do
    opts = Tree.prepare(socket.assigns.board, tree_opts(socket.assigns))

    for key <- keys,
        {:ok, ref} <- [Tree.parse_ref(key)],
        extra = [limit: @tree_page] ++ through_opt(through, key),
        {:ok, rows} <- [Tree.children(socket.assigns.board, ref, extra ++ opts)],
        do: {key, rows}
  end

  defp through_opt({key, id}, key), do: [through: id]
  defp through_opt(_through, _key), do: []

  defp container_rows(socket, "vault", key, extra),
    do: Tree.vault_children(socket.assigns.vault, key, vault_boards(socket), extra)

  defp container_rows(socket, _board, key, extra), do: tree_rows(socket, key, extra)

  # Every container "open all" opens: the folders, and in a vault the
  # vault's own folders and every mapped board's folders too.
  defp all_container_keys(socket, "vault") do
    boards = vault_boards(socket)
    Tree.vault_folder_keys(socket.assigns.vault, boards)
  end

  defp all_container_keys(socket, _board),
    do: Enum.map(socket.assigns.all_folders, &"folder:#{&1.id}")

  # A row as the hook draws it: its key, where it links to, and whether
  # following that link stays in this view (a patch) or opens another
  # board's wiki. Only what is drawn goes over the wire.
  defp client_rows(rows, socket) do
    writable = writable_ids(socket)
    Enum.map(rows, &client_row(&1, socket.assigns.board, writable))
  end

  # The boards whose rows the reader can move, rename and archive: this one
  # when they can write to it, and the vault's others they can write to.
  defp writable_ids(%{assigns: %{tree_scope: "vault", vault: %{} = vault}} = socket) do
    vault
    |> Slipdock.Vaults.board_ids()
    |> Enum.filter(&writable_board(socket, &1))
    |> MapSet.new()
  end

  defp writable_ids(socket) do
    if socket.assigns.can_write, do: MapSet.new([socket.assigns.board.id]), else: MapSet.new()
  end

  defp client_row(%{kind: "more"} = row, _board, _writable),
    do: %{kind: "more", key: "more:#{row.offset}", offset: row.offset, count: 0}

  defp client_row(row, board, writable) do
    key = row[:key] || "#{row.kind}:#{row.id}"

    base =
      row
      |> Map.take([:kind, :id, :board_id, :title, :count, :pages, :code, :placed_in])
      |> Map.merge(%{
        key: key,
        href: row_href(row, key),
        nav: if(row.board_id in [nil, board.id], do: "patch", else: "redirect")
      })

    base =
      Enum.reduce([:draft, :template, :archived, :context, :also, :mount], base, fn flag, acc ->
        if row[flag], do: Map.put(acc, flag, true), else: acc
      end)

    base
    |> then(
      &if(MapSet.member?(writable, row[:board_id]), do: Map.put(&1, :writable, true), else: &1)
    )
    |> then(&if(row[:sort] && row.sort != "manual", do: Map.put(&1, :sort, row.sort), else: &1))
  end

  defp row_href(%{kind: "page"} = row, _key), do: ~p"/boards/#{row.board_id}/wiki/#{row.slug}"

  defp row_href(%{kind: "file"} = row, _key),
    do: Slipdock.Wiki.Files.url(%Slipdock.Wiki.WikiFile{id: row.id, name: row.title})

  defp row_href(%{kind: "dir"}, _key), do: nil
  defp row_href(%{board_id: board_id}, "board:" <> _), do: ~p"/boards/#{board_id}/wiki"

  defp row_href(%{board_id: board_id}, "folder:" <> id),
    do: ~p"/boards/#{board_id}/wiki?#{[folder: id]}"

  defp row_href(_row, _key), do: nil

  # Where a drop landed, on whichever board the tree shows: "folder:" is the
  # top of this board's wiki, "board:4" the top of that board's (in a vault's
  # tree), "folder:9" a folder, and "page:7" inside a page, which is the
  # other axis (see `Slipdock.Wiki.Folder`). Only boards the reader can write.
  defp drop_target(socket, "folder:") do
    case writable_board(socket, socket.assigns.board.id) do
      nil -> :none
      board -> {:folder, board, nil}
    end
  end

  defp drop_target(socket, "folder:" <> ref) do
    with id when is_integer(id) <- Params.id(ref),
         %Folder{} = folder <- Wiki.get_folder(id),
         %Slipdock.Boards.Board{} = board <- writable_board(socket, folder.board_id) do
      {:folder, board, folder}
    else
      _ -> :none
    end
  end

  defp drop_target(socket, "board:" <> ref) do
    case Params.id(ref) && writable_board(socket, Params.id(ref)) do
      nil -> :none
      board -> {:folder, board, nil}
    end
  end

  defp drop_target(socket, "page:" <> ref) do
    with id when is_integer(id) <- Params.id(ref),
         %Page{} = page <- Wiki.get_page(id),
         %Slipdock.Boards.Board{} = board <- writable_board(socket, page.board_id) do
      {:page, board, page}
    else
      _ -> :none
    end
  end

  defp drop_target(_socket, _into), do: :none

  # The board `board_id` as one the reader can write to from here: this one,
  # or another board of its vault.
  defp writable_board(%{assigns: %{board: %{id: id} = board, can_write: true}}, id), do: board
  defp writable_board(%{assigns: %{board: %{id: id}}}, id), do: nil
  defp writable_board(%{assigns: %{vault: nil}}, _id), do: nil

  defp writable_board(socket, id) do
    with true <- id in Slipdock.Vaults.board_ids(socket.assigns.vault),
         %Slipdock.Boards.Board{} = board <- Boards.get_board(id),
         true <- Access.can_write?(Access.board_permission(socket.assigns.current_user, board)) do
      board
    else
      _ -> nil
    end
  end

  # A row of the tree the reader can change: a page or a folder on a board
  # they can write to.
  defp tree_item(socket, "page:" <> ref) do
    with id when is_integer(id) <- Params.id(ref),
         %Page{} = page <- Wiki.get_page(id),
         %{} <- writable_board(socket, page.board_id),
         do: page,
         else: (_ -> nil)
  end

  defp tree_item(socket, "folder:" <> ref) do
    with id when is_integer(id) <- Params.id(ref),
         %Folder{} = folder <- Wiki.get_folder(id),
         %{} <- writable_board(socket, folder.board_id),
         do: folder,
         else: (_ -> nil)
  end

  defp tree_item(_socket, _key), do: nil

  defp tree_items(socket, keys) when is_list(keys) do
    keys
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(500)
    |> Enum.map(&tree_item(socket, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp tree_items(_socket, _keys), do: []

  defp tree_move(socket, "page", id, into, before) do
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

  defp tree_move(socket, "folder", id, into, before) do
    with %Folder{} = folder <- tree_item(socket, "folder:#{id}"),
         {:folder, board, parent} <- drop_target(socket, into),
         true <-
           board.id == folder.board_id ||
             {:error, :unprocessable_entity,
              "A folder moves within its own board; move the pages in it instead."},
         {:ok, _} <- Wiki.move_folder(folder, parent, blank_to_integer(before)) do
      socket
    else
      {:error, :unprocessable_entity, message} -> put_flash(socket, :error, message)
      _ -> put_flash(socket, :error, "That folder couldn't be moved.")
    end
  end

  defp tree_move(socket, _kind, _id, _into, _before), do: socket

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

  # Pages bound for another board of the vault wait for the reader to see
  # what goes with them and what cannot (R11.8): see `Slipdock.Wiki.Move`.
  defp cross_move_prompt(socket, pages, board, folder, parent) do
    user = socket.assigns.current_user

    reports =
      for page <- pages,
          {:ok, report} <- [Slipdock.Wiki.Move.preview(page, board, user)],
          do: report

    if length(reports) == length(pages) do
      assign(socket,
        tree_prompt: %{
          kind: :cross_move,
          pages: pages,
          board: board,
          folder: folder,
          parent: parent,
          report: merge_reports(reports)
        }
      )
    else
      put_flash(socket, :error, "Those pages can't move to #{board.name}.")
    end
  end

  defp merge_reports(reports) do
    both = fn key, part ->
      reports |> Enum.flat_map(&(&1[key][part] || [])) |> Enum.uniq() |> Enum.sort()
    end

    %{
      pages: reports |> Enum.map(& &1.pages) |> Enum.sum(),
      tags: %{carried: both.(:tags, :carried), dropped: both.(:tags, :dropped)},
      fields: %{carried: both.(:fields, :carried), dropped: both.(:fields, :dropped)},
      pins: %{carried: both.(:pins, :carried), dropped: both.(:pins, :dropped)},
      assignees:
        reports |> Enum.map(& &1.assignee.dropped) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      lists: reports |> Enum.map(& &1.list) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      parents: reports |> Enum.map(& &1.parent) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }
  end

  # Where "Move to…" and "Also file in…" offer to put things: the top of
  # each board the reader can write to, then its folders by path. Every
  # board of the vault, or this board alone outside one.
  defp move_targets(socket, roots? \\ true) do
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

  defp item_name(%Page{title: title}), do: title
  defp item_name(%Folder{name: name}), do: name

  # What a move to another board leaves behind, one line each.
  defp cross_losses(report) do
    [
      report.tags.dropped != [] && "Tags: " <> Enum.join(report.tags.dropped, ", "),
      report.fields.dropped != [] && "Field values: " <> Enum.join(report.fields.dropped, ", "),
      report.pins.dropped != [] &&
        "Pinned cards (they stay linked, unpinned): " <> Enum.join(report.pins.dropped, ", "),
      report.assignees != [] && "Assigned to: " <> Enum.join(report.assignees, ", "),
      report.lists != [] && "A place in the list: " <> Enum.join(report.lists, ", "),
      report.parents != [] && "Its parent page: " <> Enum.join(report.parents, ", ")
    ]
    |> Enum.filter(& &1)
  end

  defp visible_targets(%{targets: targets, q: q}) do
    case String.downcase(String.trim(q || "")) do
      "" -> targets
      term -> Enum.filter(targets, &String.contains?(String.downcase(&1.label), term))
    end
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
        |> push_patch(to: ~p"/boards/#{board}/wiki/#{page.slug}")

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
        |> push_patch(to: ~p"/boards/#{socket.assigns.board}/wiki/#{saved.slug}")

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
  # Changes come in bursts — an import or a sync sends one per page, several a
  # second for minutes — and each reload reads the whole wiki. So a change
  # only books a reload a moment off, and those that land before it share it:
  # one reload per burst, not one per page, and the tab stays answerable.
  def handle_info({:wiki_changed, _board_id}, socket) do
    if socket.assigns[:reload_booked] do
      {:noreply, socket}
    else
      Process.send_after(self(), :reload_wiki, @reload_after_ms)
      {:noreply, assign(socket, reload_booked: true)}
    end
  end

  def handle_info(:reload_wiki, socket) do
    socket =
      socket |> assign(reload_booked: false) |> load_tree() |> assign_wanted() |> assign_current()

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

  # A listing's line under a title, from what `Slipdock.Wiki.Tree.excerpts/1`
  # read of the page: the summary, or the start of the body.
  defp excerpt_of(excerpts, id) do
    case excerpts[id] do
      %{summary: summary} when is_binary(summary) and summary != "" -> summary
      %{body: body} -> Renderer.excerpt(body, 140)
      _ -> ""
    end
  end

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

  defp compare_base(socket, _page, revision, against) when against in [nil, ""],
    do: {Wiki.previous_revision(revision), false, socket}

  defp compare_base(socket, page, revision, against) do
    case Wiki.get_revision(page, against) do
      {:ok, base} ->
        {base, true, socket}

      _ ->
        {Wiki.previous_revision(revision), false,
         put_flash(socket, :error, "No such version to compare with; showing the one before.")}
    end
  end

  defp stamp(nil), do: ""
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y, %H:%M")

  defp via_label("web"), do: "in the app"
  defp via_label("api"), do: "over the API"
  defp via_label("cli"), do: "from the CLI"
  defp via_label("assistant"), do: "by the assistant"
  defp via_label("automation"), do: "by an automation"
  defp via_label("mcp"), do: "over MCP"
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
      <:subnav>
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
            patch={wiki_path(@board)}
            class="rounded-lg px-2 py-1 font-semibold hover:bg-base-200"
          >
            Wiki
          </.link>
        </nav>
      </:subnav>
      <:subactions>
        <.link
          :if={@can_write}
          patch={~p"/boards/#{@board}/wiki/new"}
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-plus" class="size-4" />
          <span class="hidden sm:inline">New page</span>
        </.link>
      </:subactions>

      <%!-- A column the height of the layout's <main>, so the page tree and
            the page each scroll inside it. Without it the two panes grow to
            the length of the page and run out past the bottom of the app
            (#323). --%>
      <div id="wiki-shell" class="flex h-full flex-col">
        <%!-- The same bar the card views carry. The wiki is one more way of
              looking at a board, and a page is one more thing that answers a
              filter, so switching view and narrowing down work here too. --%>
        <div class="flex flex-wrap items-center gap-x-2 gap-y-2 border-b border-base-300 bg-base-100/70 px-3 py-2 text-sm">
          <%!-- The tree, on a phone: it opens as a drawer (R11.11). --%>
          <button
            id="wiki-tree-drawer-toggle"
            type="button"
            phx-click="toggle_tree_drawer"
            class="btn btn-ghost btn-sm gap-1 lg:hidden"
            aria-controls="wiki-tree"
            aria-expanded={to_string(@tree_drawer)}
            title="Pages and folders"
          >
            <.icon name="hero-bars-3-bottom-left" class="size-4" /> Pages
          </button>
          <.view_tabs
            board={@board}
            mode={:wiki}
            view={nil}
            marks={@marks}
            meetings={@meetings}
          />
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
              placeholder="Titles, folders, #tags…"
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
          <%!-- The tree is drawn by the WikiTree hook (assets/js/wiki_tree.js)
                into the box marked data-tree-rows, which LiveView leaves
                alone: only the rows on screen exist, and each folder's are
                asked for when it is opened. Everything around the rows is
                drawn here. `data-version` going up is the hook's cue to ask
                again; `data-current` and `data-reveal` say what to show. --%>
          <aside
            id="wiki-tree"
            phx-hook="WikiTree"
            data-board={@board.id}
            data-vault={@vault && @vault.id}
            data-organising={to_string(@organising)}
            data-can-write={to_string(@can_write)}
            data-version={@tree_version}
            data-current={@tree_current}
            data-reveal={Jason.encode!(@tree_reveal)}
            class={[
              "kanban-scroll w-64 shrink-0 overflow-y-auto border-r border-base-300 bg-base-100 p-3 lg:block",
              if(@tree_drawer,
                do:
                  "fixed inset-y-0 left-0 z-50 block w-[85vw] max-w-80 pt-4 shadow-2xl lg:static lg:z-auto lg:w-64 lg:max-w-none lg:shadow-none",
                else: "hidden"
              )
            ]}
          >
            <div class="mb-2 flex items-center gap-1">
              <.link
                patch={wiki_path(@board)}
                class={[
                  "flex min-w-0 flex-1 items-center gap-2 rounded-lg px-2 py-1.5 text-sm font-semibold hover:bg-base-200",
                  @live_action == :index && is_nil(@folder) && "bg-base-200"
                ]}
              >
                <.icon name="hero-book-open" class="size-4" /> All pages
              </.link>
              <%!-- Open or shut every folder at once. Not while filtering or
                    organising: a filter opens what it found itself. The
                    hook keeps its icon and title, so it is left alone here. --%>
              <span
                id="wiki-tree-toggle-all-box"
                class={[(@filtering or @organising or @all_folders == []) && "hidden"]}
              >
                <span id="wiki-tree-toggle-all-keep" phx-update="ignore">
                  <button
                    id="wiki-tree-toggle-all"
                    type="button"
                    data-tree-toggle-all
                    class="btn btn-ghost btn-xs btn-square shrink-0"
                    title="Open or close all folders"
                  >
                    <span class="hero-chevron-double-down size-4"></span>
                  </button>
                </span>
              </span>
              <%!-- Back to where you are, after shutting or scrolling it away
                    (the hook opens the way and scrolls to it). --%>
              <button
                :if={@tree_current != ""}
                id="wiki-tree-reveal"
                type="button"
                data-tree-reveal
                class="btn btn-ghost btn-xs btn-square shrink-0"
                title="Show where I am in the tree"
              >
                <.icon name="hero-viewfinder-circle" class="size-4" />
              </button>
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
            <%!-- A board in a vault can show its own tree or the vault's:
                  every board of it, laid out by the vault's paths. --%>
            <div
              :if={@vault}
              class="join mb-2 w-full"
              role="group"
              aria-label="Which tree"
            >
              <button
                :for={{scope, label} <- [{"board", "This board"}, {"vault", @vault.name}]}
                type="button"
                data-tree-scope={scope}
                class={[
                  "btn btn-xs join-item flex-1 truncate",
                  @tree_scope == scope && "btn-active"
                ]}
                aria-pressed={to_string(@tree_scope == scope)}
                title={if scope == "vault", do: "Every board in the vault", else: "This board's wiki"}
              >
                {label}
              </button>
            </div>
            <p
              :if={@organising}
              class="mb-2 rounded-lg bg-primary/10 px-2 py-1.5 text-xs text-base-content/70"
            >
              Drag to rearrange. A page dropped in a folder is <em>kept</em> there; dropped on a
              page, it becomes part of it. Rest on a shut folder to open it.
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
              <label class="mt-1 flex cursor-pointer items-center gap-1.5">
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs"
                  checked={@tree_contents}
                  phx-click="toggle_tree_contents"
                /> Match the words inside pages here too
              </label>
            </p>
            <p
              :if={@tree_empty and not @filtering and @tree_scope == "board"}
              class="px-2 py-4 text-sm text-base-content/50"
            >
              Nothing written yet.
            </p>
            <p
              :if={@tree_filter && @tree_filter.nodes == %{}}
              class="px-2 py-4 text-sm text-base-content/50"
            >
              No page or folder name matches that.
            </p>
            <%!-- Focusable, and owning its keys while focused (the arrows,
                  F2, Delete, type-ahead), which the page-wide shortcuts
                  stand down for. --%>
            <%!-- What is picked with Ctrl/Cmd- or Shift-click, and what can be
                  done to all of it: drawn by the hook. --%>
            <div
              id="wiki-tree-selection"
              phx-update="ignore"
              class="sticky top-0 z-20 empty:hidden"
            >
            </div>
            <div
              id="wiki-tree-rows"
              phx-update="ignore"
              data-tree-rows
              data-own-keys
              tabindex="0"
              role="tree"
              class="relative rounded-lg focus:outline-none focus-visible:ring-2 focus-visible:ring-primary/30"
              aria-label="Pages and folders"
            >
            </div>
            <button
              :if={@can_write}
              type="button"
              phx-click="new_folder"
              class="mt-2 flex w-full items-center gap-1.5 rounded-lg px-2 py-1.5 text-sm text-base-content/60 hover:bg-base-200"
            >
              <.icon name="hero-folder-plus" class="size-4" /> New folder
            </button>
          </aside>

          <div
            :if={@tree_drawer}
            id="wiki-tree-backdrop"
            class="fixed inset-0 z-40 bg-base-content/30 lg:hidden"
            phx-click="close_tree_drawer"
            phx-window-keydown="close_tree_drawer"
            phx-key="Escape"
          >
          </div>
          <%!-- `relative`: the status buttons' radios are `sr-only`, which is
                `position: absolute`, and with nothing positioned above them
                they stretched the whole document to the page's length. --%>
          <%!-- A page is opened in place (a patch), so the tree stays as it was
                rather than being rebuilt and sent again; ScrollTopOnPage puts
                this column back at the top when the page changes. --%>
          <main
            id="wiki-main"
            phx-hook="ScrollTopOnPage"
            data-page={"#{@live_action}:#{@page && @page.id}"}
            class="kanban-scroll relative min-w-0 flex-1 overflow-y-auto"
          >
            <%!-- Reading keeps a comfortable measure; writing takes the whole
                  width, source and preview side by side. --%>
            <div class={[
              "mx-auto px-4 py-6 sm:px-8 sm:py-8",
              if(@live_action in [:new, :edit], do: "max-w-none", else: "max-w-4xl")
            ]}>
              <%= case @live_action do %>
                <% :index when not is_nil(@folder) -> %>
                  <.folder_body
                    board={@board}
                    folder={@folder}
                    rows={@folder_rows}
                    more={@folder_more}
                    excerpts={@excerpts}
                    can_write={@can_write}
                  />
                <% :index -> %>
                  <.index_body
                    board={@board}
                    empty={@tree_empty}
                    folders={@index_folders}
                    recent={@recent}
                    excerpts={@excerpts}
                    wanted={@wanted}
                    can_write={@can_write}
                  />
                <% action when action in [:new, :edit] -> %>
                  <.editor
                    form={@form}
                    page={@page}
                    board={@board}
                    preview={@preview}
                    show_preview={@show_preview}
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
                    base={@base}
                    comparing={@comparing}
                    latest={@latest_revision}
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
      </div>

      <.folder_modal :if={@folder_modal} modal={@folder_modal} outline={@folder_outline} />
      <.folder_delete_modal :if={@folder_delete} folder={@folder_delete} />
      <.tree_prompt :if={@tree_prompt} prompt={@tree_prompt} />
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

  attr :prompt, :map, required: true

  # What the tree's keyboard asks before it changes a page: F2's new title,
  # or Delete's "archive this?".
  defp tree_prompt(%{prompt: %{kind: :rename}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <form id="tree-rename-form" phx-submit="save_page_title" class="space-y-4 p-6">
        <h2 class="text-lg font-semibold">Rename page</h2>
        <input
          type="text"
          name="title"
          value={@prompt.page.title}
          autofocus
          required
          class="input input-bordered w-full"
        />
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary btn-sm">Rename</button>
        </div>
      </form>
    </.modal>
    """
  end

  # "Move to…" and "Also file in…": where, typed at to narrow it.
  defp tree_prompt(%{prompt: %{kind: kind}} = assigns) when kind in [:move, :also] do
    assigns =
      assign(assigns,
        targets: visible_targets(assigns.prompt),
        event: if(kind == :move, do: "move_to", else: "also_file_in"),
        heading:
          case {kind, assigns.prompt.items} do
            {:also, [page]} -> "Also file “#{page.title}” in…"
            {:move, [item]} -> "Move “#{item_name(item)}” to…"
            {:move, items} -> "Move #{length(items)} items to…"
          end
      )

    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-3 p-6">
        <h2 class="text-lg font-semibold">{@heading}</h2>
        <form id="tree-target-filter" phx-change="tree_dialog_filter" phx-submit="tree_dialog_filter">
          <input
            type="text"
            name="q"
            value={@prompt.q}
            autofocus
            autocomplete="off"
            placeholder="Type part of a folder's name…"
            class="input input-bordered input-sm w-full"
          />
        </form>
        <ul id="tree-targets" class="max-h-80 space-y-0.5 overflow-y-auto">
          <li :for={target <- @targets}>
            <button
              type="button"
              phx-click={@event}
              phx-value-target={target.key}
              class="flex w-full items-center gap-1.5 rounded-lg px-2 py-1.5 text-left text-sm hover:bg-base-200"
              style={"padding-left: #{0.5 + if(@prompt.q == "", do: target.depth, else: 0) * 0.75}rem"}
            >
              <.icon
                name={if target.depth == 0, do: "hero-book-open", else: "hero-folder"}
                class="size-4 shrink-0 text-base-content/50"
              />
              <span class="truncate">{target.label}</span>
            </button>
          </li>
          <li :if={@targets == []} class="px-2 py-4 text-center text-sm text-base-content/50">
            No folder by that name.
          </li>
        </ul>
        <div class="flex justify-end">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  # What a move to another board of the vault carries and what it cannot,
  # before it happens (R11.8).
  defp tree_prompt(%{prompt: %{kind: :cross_move}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="text-lg font-semibold">
          <%= case @prompt.pages do %>
            <% [page] -> %>
              Move “{page.title}” to {@prompt.board.name}?
            <% pages -> %>
              Move {length(pages)} pages to {@prompt.board.name}?
          <% end %>
        </h2>
        <p class="text-sm text-base-content/70">
          It keeps its code, history, comments, checklist, links and its other folders.
          <span :if={@prompt.report.pages > length(@prompt.pages)}>
            {count(@prompt.report.pages - length(@prompt.pages), "page")} under it come too.
          </span>
        </p>
        <ul id="cross-move-report" class="space-y-1 text-sm">
          <li :if={@prompt.report.tags.carried != []}>
            Tags carried across: {Enum.join(@prompt.report.tags.carried, ", ")}
          </li>
          <li :if={@prompt.report.fields.carried != []}>
            Fields carried across: {Enum.join(@prompt.report.fields.carried, ", ")}
          </li>
          <li :if={@prompt.report.pins.carried != []}>
            Still pinned to: {Enum.join(@prompt.report.pins.carried, ", ")}
          </li>
        </ul>
        <div
          :if={cross_losses(@prompt.report) != []}
          class="rounded-lg bg-warning/10 p-3 text-sm"
        >
          <p class="font-medium">{@prompt.board.name} has no match for these, so they stay behind:</p>
          <ul id="cross-move-losses" class="mt-1 list-inside list-disc space-y-0.5">
            <li :for={line <- cross_losses(@prompt.report)}>{line}</li>
          </ul>
        </div>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            id="cross-move-confirm"
            type="button"
            phx-click="confirm_cross_move"
            class="btn btn-primary btn-sm"
          >
            Move
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  defp tree_prompt(%{prompt: %{kind: :archive_many}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="text-lg font-semibold">Archive {count(length(@prompt.items), "page")}?</h2>
        <ul class="max-h-48 list-inside list-disc overflow-y-auto text-sm text-base-content/70">
          <li :for={page <- @prompt.items}>{page.title}</li>
        </ul>
        <p class="text-sm text-base-content/60">
          The pages under them go too. Archived pages can be shown again from Display, and restored.
        </p>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            id="bulk-archive-confirm"
            type="button"
            phx-click="bulk_archive"
            class="btn btn-error btn-sm"
          >
            Archive
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  defp tree_prompt(%{prompt: %{kind: :tag_many}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="text-lg font-semibold">Tag {count(length(@prompt.items), "page")}</h2>
        <div :if={@prompt.tags == []} class="text-sm text-base-content/60">
          This board has no tags yet; make one in the board's settings.
        </div>
        <div id="bulk-tags" class="flex flex-wrap gap-1.5">
          <button
            :for={tag <- @prompt.tags}
            type="button"
            phx-click="bulk_tag"
            phx-value-tag={tag.id}
            class={["chip cursor-pointer", Palette.chip(tag.color)]}
          >
            {tag.name}
          </button>
        </div>
        <div class="flex justify-end">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  defp tree_prompt(%{prompt: %{kind: :archive}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="text-lg font-semibold">Archive “{@prompt.page.title}”?</h2>
        <p class="text-sm text-base-content/60">
          It leaves the tree, with the pages under it. Archived pages can be shown again from
          Display, and restored.
        </p>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            id="tree-archive-confirm"
            type="button"
            phx-click="archive_from_tree"
            class="btn btn-error btn-sm"
            autofocus
          >
            Archive
          </button>
        </div>
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

  attr :board, :any, required: true
  attr :folder, :any, required: true
  attr :rows, :list, default: [], doc: "what is in it, as `Slipdock.Wiki.Tree` rows"
  attr :more, :boolean, default: false, doc: "whether there were more than are listed"
  attr :excerpts, :map, default: %{}
  attr :can_write, :boolean, required: true

  @doc false
  # One folder, looked at: what is in it, and everything you would want to do
  # to it. A folder with no page of its own to stand on is the thing that made
  # filing feel like an afterthought — this is that page.
  defp folder_body(assigns) do
    assigns =
      assign(assigns,
        children: Enum.filter(assigns.rows, &(&1.kind == "folder")),
        pages: Enum.filter(assigns.rows, &(&1.kind == "page")),
        total:
          Enum.sum(for(%{kind: "folder", pages: n} <- assigns.rows, do: n)) +
            Enum.count(assigns.rows, &(&1.kind == "page"))
      )

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
          {count(@total, "page")}<span :if={@children != []}>
            in {count(length(@children), "folder")}</span>. Filed at <span class="font-mono text-xs">{Wiki.folder_path(@folder)}</span>.
        </p>
      </div>
      <div :if={@can_write} class="flex shrink-0 items-center gap-1">
        <.link
          patch={~p"/boards/#{@board}/wiki/new?#{[folder: @folder.id]}"}
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
            patch={~p"/boards/#{@board}/wiki?#{[folder: sub.id]}"}
            class="flex items-center gap-2 rounded-xl border border-base-300 bg-base-100 p-3 text-sm hover:border-primary"
          >
            <.icon name="hero-folder" class="size-4 shrink-0 text-base-content/50" />
            <span class="min-w-0 flex-1 truncate font-medium">{sub.title}</span>
            <span class="shrink-0 text-xs text-base-content/40">
              {count(sub.pages, "page")}
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
          patch={~p"/boards/#{@board}/wiki/new?#{[folder: @folder.id]}"}
          class="btn btn-sm mt-4"
        >
          Write the first page
        </.link>
      </div>
      <ul
        :if={@pages != []}
        class="mt-3 divide-y divide-base-300 rounded-xl border border-base-300 bg-base-100"
      >
        <li :for={page <- @pages}>
          <.link
            patch={~p"/boards/#{@board}/wiki/#{page.slug}"}
            class="flex items-baseline gap-3 px-4 py-3 hover:bg-base-200"
          >
            <span class="min-w-0 flex-1">
              <span class="font-medium">{page.title}</span>
              <span :if={page.draft} class="chip chip-line ml-2 text-2xs">draft</span>
              <span
                :if={excerpt_of(@excerpts, page.id) != ""}
                class="ml-2 text-sm text-base-content/50"
              >
                {excerpt_of(@excerpts, page.id)}
              </span>
            </span>
            <span :if={page.count > 0} class="shrink-0 text-2xs text-base-content/40">
              {page.count} under it
            </span>
            <span class="shrink-0 font-mono text-2xs text-base-content/40">{page.code}</span>
            <span class="hidden shrink-0 text-xs text-base-content/40 sm:inline">
              {stamp(page.updated_at)}
            </span>
          </.link>
        </li>
      </ul>
      <p :if={@more} class="mt-3 text-sm text-base-content/50">
        The first {length(@pages)} are listed here; the tree beside has every one.
      </p>
    </section>
    """
  end

  attr :board, :any, required: true
  attr :empty, :boolean, default: false
  attr :folders, :list, default: [], doc: "the top folders, each with what is in it"
  attr :recent, :list, required: true
  attr :excerpts, :map, default: %{}
  attr :wanted, :list, default: []
  attr :can_write, :boolean, required: true

  defp index_body(assigns) do
    ~H"""
    <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">{@board.name} wiki</h1>
    <p class="mt-2 text-sm text-base-content/60">
      What the board can't say: how it works, what was decided and why.
    </p>

    <div
      :if={@empty}
      class="mt-10 rounded-xl border border-dashed border-base-300 p-8 text-center"
    >
      <.icon name="hero-book-open" class="size-8 text-base-content/30" />
      <p class="mt-3 text-sm text-base-content/60">No pages yet.</p>
      <.link
        :if={@can_write}
        patch={~p"/boards/#{@board}/wiki/new"}
        class="btn btn-primary btn-sm mt-4"
      >
        Write the first one
      </.link>
    </div>

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
              <span class="min-w-0 flex-1 truncate font-medium">{node.folder.title}</span>
              <span class="shrink-0 text-xs text-base-content/40">
                {count(node.folder.pages, "page")}
              </span>
            </.link>
            <ul class="mt-2 space-y-0.5 text-sm">
              <li :for={sub <- node.children}>
                <.link
                  patch={~p"/boards/#{@board}/wiki?#{[folder: sub.id]}"}
                  class="flex items-center gap-1.5 text-base-content/60 hover:text-base-content"
                >
                  <.icon name="hero-folder" class="size-3 shrink-0" /> {sub.title}
                </.link>
              </li>
              <li :for={page <- node.pages}>
                <.link patch={~p"/boards/#{@board}/wiki/#{page.slug}"} class="link link-hover">
                  {page.title}
                </.link>
              </li>
              <li :if={node.more}>
                <.link
                  patch={~p"/boards/#{@board}/wiki?#{[folder: node.folder.id]}"}
                  class="text-xs text-base-content/50 hover:text-base-content"
                >
                  and more…
                </.link>
              </li>
            </ul>
            <.link
              :if={@can_write}
              patch={~p"/boards/#{@board}/wiki/new?#{[folder: node.folder.id]}"}
              class="mt-2 inline-flex items-center gap-1 text-xs text-base-content/50 hover:text-base-content"
            >
              <.icon name="hero-plus" class="size-3" /> New page here
            </.link>
          </div>
        </li>
      </ul>
    </section>

    <%!-- Pages people have linked to but nobody has written. The classic way
          a wiki grows, and the best work queue it has. --%>
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
            patch={~p"/boards/#{@board}/wiki/new?#{[title: want.title]}"}
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
            patch={~p"/boards/#{@board}/wiki/#{page.slug}"}
            class="flex items-baseline gap-3 px-4 py-3 hover:bg-base-200"
          >
            <span class="min-w-0 flex-1">
              <span class="font-medium">{page.title}</span>
              <span
                :if={excerpt_of(@excerpts, page.id) != ""}
                class="ml-2 text-sm text-base-content/50"
              >
                {excerpt_of(@excerpts, page.id)}
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
      <.link patch={wiki_path(@board)} class="btn btn-sm mt-4">Back to the wiki</.link>
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
          <.link patch={page_path(@board, ancestor)} class="hover:text-base-content">
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
            patch={~p"/boards/#{@board}/wiki/#{@page.slug}/edit"}
            class="btn btn-sm gap-1.5"
          >
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </.link>
          <.link
            patch={~p"/boards/#{@board}/wiki/#{@page.slug}/history"}
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
                <.link patch={~p"/boards/#{@board}/wiki/new?#{[parent: @page.id]}"}>
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
          patch={~p"/boards/#{@board}/wiki?#{[folder: @page.folder_id]}"}
          class="link font-medium"
        >
          {filed_in(@page)}
        </.link>
        <.link
          :if={@can_write and @page.folder_id}
          patch={~p"/boards/#{@board}/wiki?#{[folder: @page.folder_id]}"}
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

      <%!-- The tags the note gives itself (front matter tags and inline
            #tags), on a board in a vault. Not the board's card tags. --%>
      <div
        :if={@page.note_tags != []}
        id="page-note-tags"
        class="mt-3 flex flex-wrap items-center gap-1.5"
      >
        <span
          :for={tag <- @page.note_tags}
          class="chip chip-line text-xs text-primary"
          title="A tag this note gives itself"
        >
          #{tag}
        </span>
      </div>

      <%!-- The front matter the page's file came with, kept exactly as it
            was written (W-103 R3). Folded away: it is the file's business
            more than the reader's, and most pages have none. --%>
      <details
        :if={@page.front_matter}
        id="page-properties"
        class="mt-4 rounded-xl border border-base-300 bg-base-200/40 px-4 py-2 text-sm"
      >
        <summary class="cursor-pointer select-none text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Properties
        </summary>
        <pre class="mt-2 overflow-x-auto whitespace-pre-wrap font-mono text-xs text-base-content/80">{Slipdock.Wiki.FrontMatter.yaml(@page.front_matter)}</pre>
      </details>

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
              patch={page_path(@board, child)}
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
          <li :for={{path, title} <- Enum.map(@backlinks, &Renderer.backlink_source/1)}>
            <.link navigate={path} class="chip chip-line hover:bg-base-200">
              {title}
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
            there are no keyboard section keys. A wiki that is only documents
            turns the lot off (`page_card_features` on its board). --%>
      <section
        :if={@board.page_card_features}
        id="page-card-features"
        class="mt-10 space-y-8 border-t border-base-300 pt-6"
      >
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
        <.link patch={~p"/boards/#{@board}/wiki/#{@page.slug}/history"} class="link">
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
  attr :show_preview, :boolean, default: true
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
          <%!-- Only where the preview can show: below lg it never does. --%>
          <button
            type="button"
            id="toggle-preview"
            phx-hook="EditorPrefs"
            phx-click="toggle_preview"
            aria-pressed={to_string(@show_preview)}
            title={if @show_preview, do: "Hide the preview", else: "Show the preview"}
            class={[
              "btn btn-sm hidden lg:inline-flex",
              if(@show_preview, do: "btn-soft", else: "btn-ghost")
            ]}
          >
            <.icon name={if @show_preview, do: "hero-eye", else: "hero-eye-slash"} class="size-4" />
            Preview
          </button>
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

      <div class={["grid gap-4", @show_preview && "lg:grid-cols-2"]}>
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
        <div :if={@show_preview} id="page-preview" class="hidden lg:block">
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

  # Each version links to what it changed; the two columns of radios pick any
  # pair to compare instead, older on the left whichever way they are ticked.
  defp history_body(assigns) do
    assigns = assign(assigns, :compare?, length(assigns.revisions) > 1)

    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-2">
      <h1 class="text-xl font-bold tracking-tight">History of {@page.title}</h1>
      <.link patch={page_path(@board, @page)} class="btn btn-ghost btn-sm">Back to the page</.link>
    </div>

    <form id="compare-form" phx-submit="compare" class="mt-6">
      <div :if={@compare?} class="mb-2 flex flex-wrap items-center justify-between gap-2">
        <p class="text-sm text-base-content/60">
          Tick two versions to see them side by side, or open one to see what it changed.
        </p>
        <button type="submit" class="btn btn-sm">Compare selected versions</button>
      </div>

      <ul class="divide-y divide-base-300 rounded-xl border border-base-300 bg-base-100">
        <li
          :for={{revision, i} <- Enum.with_index(@revisions)}
          class="flex items-center hover:bg-base-200"
        >
          <span :if={@compare?} class="flex shrink-0 gap-2 pl-4">
            <input
              type="radio"
              name="from"
              value={revision.id}
              checked={i == 1}
              class="radio radio-xs"
              aria-label={"Compare from #{stamp(revision.inserted_at)}"}
            />
            <input
              type="radio"
              name="to"
              value={revision.id}
              checked={i == 0}
              class="radio radio-xs"
              aria-label={"Compare to #{stamp(revision.inserted_at)}"}
            />
          </span>
          <.link
            patch={~p"/boards/#{@board}/wiki/#{@page.slug}/history/#{revision.id}"}
            class="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-3 gap-y-1 px-4 py-3"
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
    </form>
    """
  end

  attr :board, :any, required: true
  attr :page, :any, required: true
  attr :revision, :any, default: nil
  attr :base, :any, default: nil
  attr :comparing, :boolean, default: false
  attr :latest, :any, default: nil
  attr :diff, :list, default: []
  attr :can_write, :boolean, required: true

  # GitHub's split view: the older version on the left, this one on the
  # right, with long unchanged stretches folded behind a button.
  defp revision_body(assigns) do
    assigns =
      assign(assigns,
        changed?: Enum.any?(assigns.diff, &changed_row?/1),
        current?: assigns.latest && assigns.revision && assigns.latest.id == assigns.revision.id
      )

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
            patch={~p"/boards/#{@board}/wiki/#{@page.slug}/history"}
            class="btn btn-ghost btn-sm"
          >
            All versions
          </.link>
          <.link
            :if={@latest && !@current?}
            patch={
              ~p"/boards/#{@board}/wiki/#{@page.slug}/history/#{@latest.id}?against=#{@revision.id}"
            }
            class="btn btn-ghost btn-sm"
          >
            Compare with current
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

      <div id="split-diff" class="mt-6 overflow-x-auto rounded-xl border border-base-300 bg-base-100">
        <table class="w-full min-w-[40rem] table-fixed border-collapse font-mono text-xs">
          <colgroup>
            <col class="w-12" />
            <col />
            <col class="w-12" />
            <col />
          </colgroup>
          <thead class="border-b border-base-300 bg-base-200/60 font-sans text-left text-xs text-base-content/70">
            <tr>
              <th colspan="2" class="px-3 py-2 font-medium">
                <%= if @base do %>
                  {stamp(@base.inserted_at)} · {author_label(@base)}
                  <span :if={!@comparing} class="font-normal text-base-content/50">(the version before)</span>
                <% else %>
                  <span class="font-normal text-base-content/50">Nothing before this version</span>
                <% end %>
              </th>
              <th colspan="2" class="border-l border-base-300 px-3 py-2 font-medium">
                {stamp(@revision.inserted_at)} · {author_label(@revision)}
                <span :if={@current?} class="font-normal text-base-content/50">(current)</span>
              </th>
            </tr>
          </thead>
          <tbody :if={!@changed?}>
            <tr>
              <td colspan="4" class="px-3 py-2 font-sans text-base-content/60">
                No change between these two versions.
              </td>
            </tr>
          </tbody>
          <%= for {entry, i} <- Enum.with_index(@diff) do %>
            <%= case entry do %>
              <% {:row, left, right} -> %>
                <tbody>
                  <.diff_row left={left} right={right} />
                </tbody>
              <% {:fold, rows} -> %>
                <tbody id={"diff-fold-#{i}"}>
                  <tr>
                    <td colspan="4" class="bg-sky-500/5 p-0">
                      <button
                        type="button"
                        class="w-full px-3 py-1 text-left font-sans text-base-content/60 hover:bg-sky-500/10"
                        phx-click={
                          JS.hide(to: "#diff-fold-#{i}")
                          |> JS.show(to: "#diff-folded-#{i}", display: "table-row-group")
                        }
                      >
                        ⋯ {count(length(rows), "unchanged line")}
                      </button>
                    </td>
                  </tr>
                </tbody>
                <tbody id={"diff-folded-#{i}"} class="hidden">
                  <.diff_row :for={{:row, left, right} <- rows} left={left} right={right} />
                </tbody>
            <% end %>
          <% end %>
        </table>
      </div>
    </div>
    """
  end

  attr :left, :any, required: true
  attr :right, :any, required: true

  defp diff_row(assigns) do
    ~H"""
    <tr>
      <.diff_cell cell={@left} />
      <.diff_cell cell={@right} edge />
    </tr>
    """
  end

  attr :cell, :any, required: true
  attr :edge, :boolean, default: false

  # The text is pre-wrapped, so its cell is kept on one line: any template
  # whitespace inside it would show up in the diff.
  defp diff_cell(assigns) do
    ~H"""
    <td class={[
      "select-none px-2 py-0.5 text-right align-top text-base-content/40",
      @edge && "border-l border-base-300",
      @cell && @cell.op == :del && "bg-rose-500/15",
      @cell && @cell.op == :ins && "bg-emerald-500/15",
      is_nil(@cell) && "bg-base-200/60"
    ]}>
      {@cell && @cell.n}
    </td>
    <td
      data-op={@cell && @cell.op}
      class={[
        "whitespace-pre-wrap break-words px-2 py-0.5 align-top",
        @cell && @cell.op == :del && "bg-rose-500/10 text-rose-950 dark:text-rose-100",
        @cell && @cell.op == :ins && "bg-emerald-500/10 text-emerald-950 dark:text-emerald-100",
        @cell && @cell.op == :eq && "text-base-content/70",
        is_nil(@cell) && "bg-base-200/60"
      ]}
      phx-no-format
    ><span :if={@cell && @cell.op != :eq} class="sr-only">{if @cell.op == :del, do: "removed: ", else: "added: "}</span><%= if @cell do %><span :for={{kind, text} <- @cell.parts} class={kind == :chg && diff_word(@cell.op)}>{text}</span><% end %></td>
    """
  end

  defp changed_row?({:row, %{op: :eq}, %{op: :eq}}), do: false
  defp changed_row?({:row, _, _}), do: true
  defp changed_row?(_), do: false

  defp diff_word(:del), do: "diff-word rounded-sm bg-rose-500/30"
  defp diff_word(_), do: "diff-word rounded-sm bg-emerald-500/30"
end
