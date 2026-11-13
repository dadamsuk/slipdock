defmodule SlipdockWeb.WikiLive.State do
  @moduledoc """
  The wiki view's state (`WikiLive.Index`): the board a view is of and
  switching it, the tree's counts and listings, what the address shows (a
  folder, a page, a version, the editor) and saving and reloading a page.

  Each function takes the socket and returns it, assigned. The logic modules
  (`State`, `Drafts`, `TreeRows`, `TreeOps`) call each other by name rather
  than importing each other, so the compile graph keeps no cycle among them.
  """
  use SlipdockWeb, :html
  import Phoenix.LiveView

  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Wiki.{Autosaves, Folder, LineChanges, Page, Tree}
  alias SlipdockWeb.Params
  alias SlipdockWeb.WikiLive.{Drafts, TreeRows}

  # What the middle column lists of a folder, and of each on the index.
  @folder_listing 200
  @index_pages 8

  # How many versions a page's history lists.
  @history_limit 100

  # How many of a vault folder's notes it lists, newest first (#1211).
  @vault_recent 50

  # Opening a page of another board from the tree (a vault's tree holds
  # several) is a patch, not a fresh view, so the tree isn't torn down and
  # drawn again from nothing on every click. The board this is a view of
  # changes here as well as at mount, keeping what the reader chose about
  # the view itself.
  @kept_on_switch [
    :tree_version,
    :tree_view,
    :show,
    :show_preview,
    :tree_contents,
    :marks,
    :shared_tree
  ]

  # How many pages the tree's Recent view lists (#738).
  @tree_recent 100

  @doc """
  The gates of an open wiki, set again from the level just read (#2998):
  the event hook `WikiLive.Index` attaches at mount calls this before every
  event, so a guard on `can_write` asks what the database says now, not
  what mount found. Unchanged, nothing is assigned. An open page is asked
  for its own level again, since a share on it can keep its reader
  commenting. Only the gates the events read are set: the tree and the
  menus are drawn for the new level when the wiki next loads.
  """
  def assign_access(%{assigns: %{perm: perm}} = socket, perm), do: socket

  def assign_access(socket, perm) do
    for_page =
      case socket.assigns.page do
        %Page{} = page -> Access.page_permission(socket.assigns.current_user, page)
        _ -> perm
      end

    assign(socket,
      perm: perm,
      can_write: Access.can_write?(perm),
      can_comment: Access.can_comment?(for_page),
      can_manage: perm == :owner
    )
  end

  @doc """
  `assign_access/2` for what isn't an event and so passes no hook: an
  upload's progress. The level is read here.
  """
  def refresh_access(socket),
    do: assign_access(socket, SlipdockWeb.LiveAccess.board_level(socket))

  # Everything a view of one board's wiki starts from. Mount sets it all;
  # opening a page of another board from the tree sets it again in
  # `switch_board/3`, apart from what the reader chose about the view itself.
  def board_assigns(socket, board, perm) do
    [
      board: board,
      perm: perm,
      can_write: Access.can_write?(perm),
      # Joining an open page's discussion (#863); `assign_page/2` asks again
      # of each page, since a page grant can raise it.
      can_comment: Access.can_comment?(perm),
      can_manage: perm == :owner,
      # The AI tools beside a page (#1539): whether they can run, and open.
      page_tools_ai: Slipdock.AI.configured?(socket.assigns.current_user),
      # The board's `…` menu, as its own views have it: where its panels
      # are, and whether it offers Email to this board.
      view_only: perm == :view,
      inbound: Access.can_write?(perm) and Slipdock.Inbound.enabled?(),
      board_paths: board_paths(board),
      page: nil,
      page_shares: 0,
      revision: nil,
      form: nil,
      preview: "",
      # The editor's Preview pane beside the source. The editor already
      # renders as you type, so it starts off (#1744): one pane at the whole
      # width. A writer who wants it gets it, and the browser remembers
      # (EditorPrefs).
      show_preview: false,
      page_tools: false,
      conflict: nil,
      base_hash: nil,
      # Auto-save (#1532): the row for what is open, the form waiting for the
      # timer, when it last landed, and what the editor was opened from.
      autosave: nil,
      autosave_pending: nil,
      autosave_timer: false,
      autosaved?: false,
      restored_from: nil,
      unsaved: [],
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
      # On a board in a vault the tree is the vault's from the board's
      # folder down, its own rows and the sub-boards below them
      # together (#758); `tree_root` is the key of its top.
      tree_version: 0,
      tree_filter: nil,
      # Whether the search box looks inside pages too, not only at names.
      tree_contents: false,
      # A page the tree's keyboard is renaming (F2) or archiving (Delete).
      tree_prompt: nil,
      # On a phone the tree is a drawer, shut until asked for (R11.11).
      tree_drawer: false,
      # A wiki file opened beside the page (#768): what
      # `SlipdockWeb.FileViewer.load/2` gave, or nil.
      file_shown: nil,
      tree_scope: "board",
      tree_root: "root",
      # Opened from another board's tree (`?in=`): that board, whose tree
      # and breadcrumbs are kept, and where its folder is.
      tree_context: nil,
      tree_context_root: nil,
      # The tree, or "recent": this board's pages, last edited first
      # (#738). The browser keeps the choice (WikiTreeView hook).
      tree_view: "tree",
      tree_recent: [],
      tree_empty: true,
      tree_current: "",
      tree_reveal: [],
      vault: Slipdock.Vaults.for_board(board),
      # The vault view's own (#752): the vault, what the address named,
      # and where everything of it sits. Nil on a board's wiki.
      vault_view: nil,
      vault_target: nil,
      vault_addresses: nil,
      # The vault path the index is looking at (#1211): "" for the whole
      # vault, a board's or folder's path, nil off the vault view.
      vault_dir: nil,
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
      # The Share dialog (#813): what is being shared, who has it, and the
      # groups the reader may pick from.
      share_modal: nil,
      # The folder being looked *at*, when the index is scoped to one.
      folder: nil,
      # A folder whose deletion is being decided: keep what is in it, or
      # take it all with it (see `Slipdock.Wiki.Folders.delete/2`).
      folder_delete: nil,
      html: "",
      recording: nil,
      recording_help: %{settings_url: nil, owner: nil},
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
      revision_changes: %{},
      # The history rows opened to show their changed lines (#1745), by id.
      history_previews: %{},
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
      marks: Slipdock.Favourites.marks(socket.assigns.current_user),
      # Shared with me (#817): what other people have shared with the reader.
      shared_tree: Slipdock.Wiki.SharedTree.for_user(socket.assigns.current_user)
    ]
  end

  # The board's panels, from its own board view: the wiki's `…` menu
  # navigates to them, as they belong to `SlipdockWeb.BoardLive.Show`.
  defp board_paths(board) do
    base = %{mode: :board, board: board, swim_query: []}

    [:tags, :activity, :archive, :settings, :automations]
    |> Map.new(&{&1, SlipdockWeb.BoardLive.Paths.panel_path(base, &1)})
    |> Map.put(:tidy, ~p"/boards/#{board}/tidy")
    |> Map.put(:agentic, SlipdockWeb.BoardLive.State.agentic_path(board))
  end

  def switch_board(%{assigns: %{board: %{id: id}}} = socket, id, _params), do: {:ok, socket}
  def switch_board(socket, nil, _params), do: {:ok, socket}

  def switch_board(socket, board_id, params) do
    old = socket.assigns.board
    board = Boards.get_board!(board_id)
    perm = Access.board_permission(socket.assigns.current_user, board)

    if Access.can_read?(perm) do
      if connected?(socket) do
        Wiki.unsubscribe(old.id)
        Wiki.subscribe(board.id)
      end

      {:ok,
       socket
       |> assign(Keyword.drop(board_assigns(socket, board, perm), @kept_on_switch))
       |> assign_context(params["in"])
       |> load_tree_state()}
    else
      {:error,
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
  def load_tree(socket), do: socket |> load_tree_state() |> assign_listing()

  def reload_names(socket), do: socket |> update(:tree_version, &(&1 + 1)) |> assign_listing()

  # Mount reads the state alone: the listing comes with `handle_params`,
  # which knows which view it is for.
  def load_tree_state(socket) do
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

    socket
    |> assign(
      all_folders: folders,
      # Paths and depths worked out once, in memory, for every picker on the
      # page (see `SlipdockWeb.FolderPicker`).
      folder_outline: Slipdock.Wiki.Folders.outline(folders),
      tree_filter: filter,
      tree_empty: total == 0 and folders == [],
      filtering: filtering
    )
    |> assign_counts(total)
    |> assign_tree_recent()
    |> update(:tree_version, &(&1 + 1))
  end

  # The toolbar's "N pages": what the tree beside it shows (#1698). In a
  # vault that is every board under the tree's top (the whole vault on the
  # wiki home, a board and its sub-boards on a board's own wiki), not just
  # the board the view is mounted on, which on the wiki home is the
  # Knowledge Base and may hold nothing at all.
  def assign_counts(socket, board_total \\ nil) do
    filter = socket.assigns.tree_filter

    {total, shown} =
      case count_root(socket) do
        nil ->
          total =
            board_total || Tree.count(socket.assigns.board, tree_opts(socket.assigns))

          {total, if(filter, do: filter.shown, else: total)}

        root ->
          boards = vault_boards(socket)
          total = Tree.vault_count(socket.assigns.vault, boards, root)

          shown =
            if filter,
              do:
                Tree.vault_filter(socket.assigns.vault, boards, socket.assigns.filters,
                  contents: socket.assigns.tree_contents,
                  root: root
                ).shown,
              else: total

          {total, shown}
      end

    assign(socket, shown: shown, hidden: total - shown)
  end

  # Where in the vault the tree starts, for counting: as `recent_root/1`,
  # but keeping a context opened from another board (`?in=`).
  defp count_root(%{assigns: %{vault: nil}}), do: nil

  defp count_root(%{assigns: %{tree_scope: "vault"} = assigns}),
    do: assigns.tree_context_root || ""

  defp count_root(socket), do: TreeRows.board_vault_root(socket)

  # The Recent view's rows: what the tree would show, newest edit first, and
  # narrowed by the filter bar as the tree is. Only read while it is shown.
  def assign_tree_recent(%{assigns: %{tree_view: "recent"}} = socket),
    do: assign(socket, tree_recent: recent_rows(socket, @tree_recent))

  def assign_tree_recent(socket), do: assign(socket, tree_recent: [])

  # The `n` pages edited last of what the tree shows, each with where it
  # opens: in a vault, the sub-boards below this tree's top as well as its
  # own board's (#1202).
  defp recent_rows(socket, n) do
    filter = TreeRows.scope_filter(socket, socket.assigns.tree_scope)
    only = filter && filter.only

    case recent_root(socket) do
      nil ->
        Tree.recent(socket.assigns.board, [only: only] ++ tree_opts(socket.assigns), n)

      root ->
        Tree.vault_recent(socket.assigns.vault, vault_boards(socket), n, root: root, only: only)
    end
    |> Enum.map(&Map.merge(&1, %{href: TreeRows.row_href(&1, nil), nav: "patch"}))
    |> TreeRows.in_vault_view(socket.assigns)
    |> TreeRows.in_context(socket.assigns)
  end

  # Where in the vault this tree starts: the vault's top in the vault view,
  # the board it was opened from, or this board's folder. Nil off a vault.
  defp recent_root(%{assigns: %{vault: nil}}), do: nil
  defp recent_root(%{assigns: %{tree_context: %{}, tree_context_root: root}}), do: root
  defp recent_root(%{assigns: %{tree_scope: "vault"}}), do: ""
  defp recent_root(socket), do: TreeRows.board_vault_root(socket)

  # `as`: whose tree it is, which decides the pages also filed in a folder
  # that it shows (W-103 R12.2).
  def tree_opts(%{can_write: can_write, show: show} = assigns),
    do: list_opts(can_write, show) ++ [as: assigns[:current_user]]

  # A container's rows on this board, as the tree draws them: from what the
  # filter left when one is on, from the database when not.
  def tree_rows(socket, key, extra) do
    case socket.assigns.tree_filter do
      %{nodes: nodes} ->
        {:ok, Map.get(nodes, key, [])}

      nil ->
        with {:ok, ref} <- Tree.parse_ref(key),
             do: Tree.children(socket.assigns.board, ref, tree_opts(socket.assigns) ++ extra)
    end
  end

  # The middle column's listings, read only for the view that draws them.
  # A vault's (#1211): the tree beside it has the folders already, so what
  # is listed is the notes changed most lately anywhere under the folder
  # being looked at, or the whole vault when none is.
  defp assign_listing(%{assigns: %{live_action: :index, vault_dir: dir}} = socket)
       when is_binary(dir) do
    recent = vault_dir_recent(socket, String.trim(dir, "/"), @vault_recent)

    assign(socket,
      index_folders: [],
      folder_rows: [],
      folder_more: false,
      recent: recent,
      excerpts: Tree.excerpts(Enum.map(recent, & &1.id))
    )
  end

  defp assign_listing(%{assigns: %{live_action: :index, folder: %Folder{} = folder}} = socket) do
    rows =
      case tree_rows(socket, "folder:#{folder.id}", limit: @folder_listing) do
        {:ok, rows} -> TreeRows.name_rows(rows, socket)
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
      for %{kind: "folder"} = folder <- TreeRows.name_rows(top, socket),
          do: index_folder(socket, folder, prepared)

    recent = recent_rows(socket, 8)

    assign(socket,
      index_folders: index_folders,
      recent: recent,
      excerpts: Tree.excerpts(Enum.map(recent, & &1.id))
    )
  end

  defp assign_listing(socket), do: socket

  # One folder's card on the index: its folders, its first pages, and
  # whether there are more.
  defp index_folder(socket, folder, prepared) do
    inner =
      case tree_rows(socket, "folder:#{folder.id}", [limit: @index_pages] ++ prepared) do
        {:ok, rows} -> TreeRows.name_rows(rows, socket)
        _ -> []
      end

    %{
      folder: folder,
      children: Enum.filter(inner, &(&1.kind == "folder")),
      pages: inner |> Enum.filter(&(&1.kind == "page")) |> Enum.take(@index_pages),
      more: Enum.any?(inner, &(&1.kind == "more"))
    }
  end

  # The vault's notes under `dir` ("" for all of it), newest first, each
  # with the folder it sits in.
  defp vault_dir_recent(socket, dir, n) do
    %{vault_view: vault, vault_addresses: addresses} = socket.assigns
    filter = TreeRows.scope_filter(socket, "vault")

    ids =
      if dir != "" do
        prefix = String.downcase(dir) <> "/"

        for {id, path} <- addresses.pages,
            String.starts_with?(String.downcase(path), prefix),
            do: id
      end

    vault
    |> Tree.vault_recent(vault_boards(socket), n, only: filter && filter.only, ids: ids)
    |> Enum.map(fn row ->
      # Where it sits below the folder being looked at, not the whole way.
      path = addresses.pages[row.id] || ""
      path = if dir == "", do: path, else: String.slice(path, (String.length(dir) + 1)..-1//1)
      where = path |> String.split("/") |> Enum.drop(-1) |> Enum.join(" / ")
      Map.merge(row, %{href: TreeRows.row_href(row, nil), nav: "patch", where: where})
    end)
    |> TreeRows.in_vault_view(socket.assigns)
  end

  def list_opts(can_write, show) do
    [
      status: if(can_write and show.drafts, do: nil, else: "published"),
      template: if(show.templates, do: nil, else: false),
      archived: if(can_write and show.archived, do: :all, else: false)
    ]
    |> Enum.reject(&match?({_, nil}, &1))
  end

  # What the tree highlights, and the way to it: a page is opened in place,
  # so the hook opens the folders leading to it here as well as on a fresh
  # visit (one reached by a link in a note may sit in a folder the reader
  # shut). Worked out for the tree the reader has on screen, the board's or
  # the vault's.
  def assign_current(socket) do
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
        Tree.vault_path_to(vault, item, vault_boards(socket),
          root: socket.assigns.tree_context_root || ""
        )

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
  def vault_boards(%{assigns: %{vault: nil}}), do: %{}

  # An archived board's tree, and a board with nothing written, are out of
  # the wiki's (W-2201), unless it is the one being read: opened from the
  # archive, or its own wiki opened to write its first page.
  def vault_boards(socket) do
    %{vault: vault, current_user: user, show: show, board: here} = socket.assigns
    hidden = Slipdock.Vaults.out_of_tree_ids(vault)
    here_root = Slipdock.Boards.Board.root_id(here)

    vault
    |> Slipdock.Vaults.board_ids()
    |> Enum.flat_map(&vault_board_rows(&1, hidden, here_root, user, show))
    |> Map.new()
  end

  defp vault_board_rows(id, hidden, here_root, user, show) do
    case Slipdock.Boards.get_board_record(id) do
      nil ->
        []

      board ->
        if MapSet.member?(hidden, id) and Slipdock.Boards.Board.root_id(board) != here_root,
          do: [],
          else: vault_board_entry(user, show, id, board)
    end
  end

  defp vault_board_entry(user, show, id, board) do
    perm = Access.board_permission(user, board)

    if Access.can_read?(perm),
      do: [{id, {board, list_opts(Access.can_write?(perm), show) ++ [as: user]}}],
      else: []
  end

  # A page or folder of this board opened from another board's tree, as
  # `?in=<board>` says (#758): that board's tree is kept, from its folder
  # down, so a reader walking a board's wiki into a sub-board of it stays in
  # that board's wiki. Only a board of the same vault the reader can open,
  # with this board below it; anything else is this board's own wiki as ever.
  def assign_context(socket, ref) do
    %{board: board, vault: vault} = socket.assigns

    with %{} <- vault,
         id when is_integer(id) and id != board.id <- Params.id(to_string(ref || "")),
         boards = vault_boards(socket),
         {:ok, {context, _opts}} <- Map.fetch(boards, id),
         root when is_binary(root) <- Tree.vault_root(vault, id, boards),
         true <- under_root?(vault, board.id, root) do
      assign(socket,
        tree_context: context,
        tree_context_root: root,
        tree_scope: "vault",
        tree_root: "board:#{id}"
      )
    else
      _ -> socket
    end
  end

  defp under_root?(vault, board_id, root) do
    case Slipdock.Vaults.Layout.dirs(vault).boards[board_id] do
      nil -> false
      path -> root == "" or path == root or String.starts_with?(path, root <> "/")
    end
  end

  # The index does double duty: the whole wiki, or one folder of it with
  # `?folder=`. A query parameter rather than a path of its own, so a folder
  # named "new" or "edit" can never shadow a page's routes.
  def apply_action(socket, :index, params) do
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

  def apply_action(socket, :new, params) do
    if socket.assigns.can_write do
      %{board: board, current_user: user} = socket.assigns
      # Coming back to a new page that was never saved (#1532).
      autosave = params["autosave"] && Autosaves.get_new(user, board, params["autosave"])
      attrs = (autosave && autosave.attrs) || %{}
      parent = parent_from(socket.assigns.board, attrs["parent"] || params["parent"])
      # "Add a page…" at the foot of a list comes straight here with the list
      # it was pressed in, and the page is placed there when it is saved.
      column = column_from(socket.assigns.board, attrs["column"] || params["column"])
      # "New page" pressed inside a folder files it there without asking.
      folder = folder_from(socket.assigns.board, params["folder"])

      blank = blank_page(socket.assigns.board, parent, folder, params)

      socket
      |> assign(
        page: nil,
        revision: nil,
        new_parent: parent,
        new_column: column,
        new_folder: folder
      )
      |> assign(page_title: "New page")
      |> Drafts.assign_form(blank, attrs)
      |> Drafts.assign_autosave(autosave)
      |> assign(preview: Drafts.render_body(socket, nil, attrs["body"] || blank.body))
    else
      refuse(socket, "You can't write on this board.")
    end
  end

  def apply_action(socket, action, %{"slug" => slug} = params) do
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

  defp blank_page(board, parent, folder, params) do
    %Page{
      board_id: board.id,
      parent_id: parent && parent.id,
      folder_id: folder && folder.id,
      title: params["title"] || "",
      # A link can arrive with the page's opening block already written.
      body: params["block"] || ""
    }
  end

  # The wanted pages are drawn on the index alone, so they are worked out
  # only when it is what is showing: an open page never pays for them.
  def assign_wanted(%{assigns: %{page: nil, board: board}} = socket),
    do: assign(socket, wanted: Wiki.wanted(board))

  def assign_wanted(socket), do: assign(socket, wanted: [])

  defp apply_page_action(socket, :edit, _params) do
    if socket.assigns.can_write do
      page = socket.assigns.page
      # What they had typed and never saved comes back by itself (#1532).
      autosave = Autosaves.for_page(socket.assigns.current_user, page)
      attrs = (autosave && autosave.attrs) || %{}

      # The hash the editor opened against, held apart from `@page` on
      # purpose: a live update from someone else must not quietly re-base the
      # save it is meant to catch. A restored edit keeps the one it was typed
      # against, so a change made since is still caught.
      socket
      |> Drafts.assign_form(page, attrs)
      |> Drafts.assign_autosave(autosave)
      |> assign(
        preview: Drafts.render_body(socket, page, attrs["body"] || page.body),
        conflict: nil,
        revision: nil,
        base_hash: (autosave && autosave.base_hash) || page.content_hash
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

  defp apply_page_action(socket, :history, _params) do
    revisions = Wiki.list_revisions(socket.assigns.page, @history_limit)

    # The oldest listed is compared with the one before it, unless it is
    # the page's first, whose lines are all added.
    before =
      if length(revisions) == @history_limit,
        do: Wiki.previous_revision(List.last(revisions))

    assign(socket,
      revision: nil,
      revisions: revisions,
      revision_changes: LineChanges.for_revisions(revisions, before),
      history_previews: %{}
    )
  end

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
      html: Drafts.render_body(socket, page, page.body),
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
  def card_links(%Page{} = page) do
    page
    |> Wiki.outgoing_links()
    |> Enum.filter(&(&1.kind == "card" and not is_nil(&1.target_card)))
  end

  def speaker_refusal(:blank), do: "A voice needs a name."

  def speaker_refusal(:invalid),
    do: "A name can be up to 60 characters, without <, > or a colon."

  def speaker_refusal(:unchanged), do: "That is already its name."
  def speaker_refusal(:not_found), do: "Nobody by that name speaks in this page's transcript."
  def speaker_refusal(_), do: "That voice couldn't be renamed."

  def assign_page(socket, %Page{} = page) do
    recording = Slipdock.Recordings.for_page(page)

    assign(socket,
      page: Wiki.with_board_preloads(page, [], force: true),
      can_comment: Access.can_comment?(Access.page_permission(socket.assigns.current_user, page)),
      # How many people and groups it has been shared with (#813).
      page_shares: length(Access.list_grants(page)),
      # A meeting page's recording, played beside its transcript (W-1690).
      recording: recording,
      recording_help: recording_help(recording, page, socket.assigns.current_user)
    )
  end

  # Where a vault with no recordings folder gets one (#784): the setting
  # itself for the vault's owner, who alone can set it; the owner's name for
  # anybody else, to ask.
  defp recording_help({:error, :no_folder}, page, user) do
    case Slipdock.Vaults.for_board(page.board_id) do
      %{user_id: owner_id} = vault when not is_nil(user) and owner_id == user.id ->
        %{settings_url: ~p"/wiki/.settings" <> "#recordings-folder-#{vault.id}", owner: nil}

      %{} = vault ->
        vault = Slipdock.Vaults.with_user(vault)
        %{settings_url: nil, owner: Slipdock.Accounts.User.display_name(vault.user)}

      nil ->
        %{settings_url: nil, owner: nil}
    end
  end

  defp recording_help(_recording, _page, _user), do: %{settings_url: nil, owner: nil}

  def put_filter(socket, key, value),
    do: socket |> assign(filters: Map.put(socket.assigns.filters, key, value)) |> load_tree()

  # Clicking the filter that is already on turns it off.
  def toggle_filter(socket, key, value) do
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

  def folder_from(_board, ref) when ref in [nil, "", "none"], do: nil

  def folder_from(board, ref) do
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

  def assign_card_results(socket) do
    query = String.trim(socket.assigns.card_query || "")
    attached = Enum.map(socket.assigns.cards, & &1.target_card_id)

    results =
      if query == "",
        do: [],
        else: Boards.Links.search_cards(socket.assigns.board.id, query, attached)

    assign(socket, card_results: results)
  end

  def blank_to_integer(nil), do: nil

  def blank_to_integer(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def blank_to_nil(value) when value in [nil, "", "none"], do: nil

  def blank_to_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def blank_to_nil(value), do: value

  def save(socket, nil, params, message, _purge) do
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

    autosave = socket.assigns.autosave

    case Wiki.create_page(board, params,
           user: socket.assigns.current_user,
           via: "web",
           message: message,
           finish_body: autosave && (&Autosaves.adopt(autosave, &1, &1.body))
         ) do
      {:ok, page} ->
        {page, note} = place_new(page, column)

        socket
        |> Drafts.clear_autosave()
        |> put_flash(:info, "Wrote “#{page.title}”.#{note}")
        |> push_patch(to: ~p"/boards/#{board}/wiki/#{page.slug}")

      {:error, {:finish_body, message}} ->
        put_flash(socket, :error, message)

      {:error, changeset} ->
        assign(socket, form: to_form(changeset))
    end
  end

  def save(socket, %Page{} = page, params, message, purge) do
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
        |> Drafts.clear_autosave()
        |> put_flash(:info, "Saved." <> purged(saved, purge, socket.assigns.current_user))
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

  # Started from the foot of a list: it belongs in that list.
  defp place_new(page, column) do
    case column && Wiki.place(page, column) do
      {:ok, placed} -> {placed, " It's in #{column.name}."}
      _ -> {page, ""}
    end
  end

  # After the save, so the newest revision is the encrypted one and is kept.
  defp purged(_page, purge, _user) when purge in [nil, ""], do: ""

  defp purged(page, purge, user) do
    case Wiki.purge_revisions(page, String.split(purge, ","), user: user) do
      {:ok, 0} -> ""
      {:ok, 1} -> " One earlier revision that held the text in plain was purged."
      {:ok, n} -> " #{n} earlier revisions that held the text in plain were purged."
      {:error, :forbidden} -> " Only the board's owner can purge earlier revisions."
    end
  end

  def reload(socket, %Page{} = page) do
    fresh = Wiki.get_page!(page.id)

    socket
    |> assign_page(fresh)
    |> assign(html: Drafts.render_body(socket, fresh, fresh.body), cards: card_links(fresh))
    |> assign_card_results()
    |> load_tree()
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
end
