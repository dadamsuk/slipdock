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

  It is one LiveView in several modules (#2788), all running in this one
  process on this one socket. This module keeps the callbacks: mount, the
  address, messages, and `render/1`, which draws the frame from
  `WikiLive.Chrome`. The rest is by what it does:

    * the view's state: `WikiLive.State`, `WikiLive.Drafts` (the editor's
      form, autosave and uploads), `WikiLive.TreeRows` (what the tree is
      sent) and `WikiLive.TreeOps` (what its dialogs act on);
    * the events, each module saying which it handles
      (`WikiLive.Events`): `WikiLive.PageEvents`, `WikiLive.TreeEvents`
      and `WikiLive.ItemEvents`;
    * the templates: `WikiLive.PageView`, `WikiLive.Editor`,
      `WikiLive.HistoryView`, `WikiLive.FolderView`, `WikiLive.Modals` and
      `WikiLive.TreePrompt`, with `WikiLive.Format`'s helpers.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.WikiLive.Chrome
  import SlipdockWeb.WikiLive.State
  import SlipdockWeb.WikiLive.Drafts
  import SlipdockWeb.WikiLive.TreeRows
  import SlipdockWeb.WikiLive.Modals
  import SlipdockWeb.WikiLive.TreePrompt
  import SlipdockWeb.WikiLive.PageView
  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Boards.Attachment
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.BoardLive.BoardView
  alias SlipdockWeb.Params
  alias SlipdockWeb.WikiLive.{ItemEvents, PageEvents, PageToolsComponent, TreeEvents}

  # How long a change waits for the rest of its burst (see the
  # `:wiki_changed` handler). Short enough that one edit still shows at once.
  @reload_after_ms Application.compile_env(:slipdock, :wiki_reload_after_ms, 300)

  # The vault view (#752): a vault's own page, its tree and its pages at
  # their vault paths. What the address names decides which board's wiki
  # this is a view of — the page's, the folder's, the board's, or at the top
  # the owner's first — and everything else is that board's wiki as ever, shown with
  # the vault's tree and the vault's breadcrumbs. `?page=` and `?folder=`
  # (ids) are how a board's wiki links here before it knows the path.
  @impl true
  # `/wiki`: the person's one wiki (W-2201), which no address names, with
  # their Knowledge Base made the first time it is wanted.
  def mount(params, session, %{assigns: %{live_action: :vault}} = socket)
      when not is_map_key(params, "vault") and not is_map_key(params, "id") do
    user = socket.assigns.current_user
    {:ok, _} = Slipdock.Wiki.KnowledgeBase.ensure(user)
    mount(Map.put(params, "vault", to_string(Slipdock.Vaults.root(user).id)), session, socket)
  end

  def mount(%{"vault" => ref} = params, session, socket) do
    user = socket.assigns.current_user

    with {:ok, vault} <- Slipdock.Vaults.get_vault(user, ref),
         {:ok, target, board_id} <- vault_target(vault, params) do
      {:ok, socket} = mount(%{"id" => to_string(board_id)}, session, socket)

      {:ok,
       assign(socket,
         vault_view: vault,
         vault_target: target,
         vault_addresses: Slipdock.Vaults.addresses(vault),
         tree_scope: "vault",
         tree_root: "vault"
       )
       |> assign_counts()}
    else
      {:error, :empty, vault} ->
        {:ok,
         socket
         |> put_flash(
           :info,
           "Your wiki has nothing in it yet: every board you make is a folder of it."
         )
         |> push_navigate(to: SlipdockWeb.VaultUrls.settings(vault))}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "There's nothing at that address in your wiki.")
         |> push_navigate(to: ~p"/")}
    end
  end

  def mount(%{"id" => id} = params, _session, socket) do
    board = Boards.get_board!(id)
    perm = Access.board_permission(socket.assigns.current_user, board)

    if Access.can_read?(perm) do
      if connected?(socket) do
        Wiki.subscribe(board.id)
        Access.subscribe_shares(socket.assigns.current_user.id)
      end

      {:ok,
       socket
       |> assign(board_assigns(socket, board, perm))
       # The level is read again before every event (#2998).
       |> SlipdockWeb.LiveAccess.refresh_on_event(&assign_access/2)
       |> allow_upload(:page_image,
         accept: ~w(.png .jpg .jpeg .gif .webp image/png image/jpeg image/gif image/webp),
         max_entries: 5,
         max_file_size: Attachment.image_max_size(),
         auto_upload: true,
         progress: &handle_upload/3
       )
       |> assign_context(params["in"])
       |> load_tree_state()}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have access to that board.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, uri, %{assigns: %{live_action: :vault}} = socket) do
    # The address is read again on every patch: a row of the vault's tree
    # opens by patching to its address, so the tree stays put.
    socket = flush_autosave(socket)
    %{vault_view: vault, vault_addresses: addresses} = socket.assigns

    with {:ok, target, board_id} <- vault_target(vault, params),
         {:ok, socket} <- switch_board(socket, board_id, %{}) do
      socket
      |> assign(
        vault_view: vault,
        vault_target: target,
        vault_addresses: addresses,
        tree_scope: "vault",
        tree_root: "vault"
      )
      |> assign_counts()
      |> show_vault_target(params)
    else
      {:error, %Phoenix.LiveView.Socket{} = socket} ->
        {:noreply, socket}

      # Nothing there now: a fresh visit says why, as it does at mount.
      _ ->
        %URI{path: path, query: query} = URI.parse(uri)
        {:noreply, push_navigate(socket, to: if(query, do: path <> "?" <> query, else: path))}
    end
  end

  def handle_params(params, _uri, socket) do
    # Before anything moves: what is waiting belongs to the page being left.
    socket = flush_autosave(socket)

    # A row of another board in the tree patches to that board's wiki.
    case switch_board(socket, Params.id(params["id"]), params) do
      {:ok, socket} -> show_params(socket, params)
      {:error, socket} -> {:noreply, socket}
    end
  end

  defp show_vault_target(socket, params) do
    %{board: board, vault_target: target} = socket.assigns

    {action, extra, dir} =
      case target do
        {:page, id} ->
          {:show, %{"slug" => Wiki.get_page!(id).slug}, nil}

        {:folder, id} ->
          {:index, %{"folder" => to_string(id)}, socket.assigns.vault_addresses.folders[id]}

        {:index, path} ->
          {:index, %{}, path}
      end

    socket =
      socket
      |> assign(live_action: action, folder: nil, tree_drawer: false, file_shown: nil)
      |> assign(vault_dir: dir)
      |> apply_action(action, Map.merge(%{"id" => to_string(board.id)}, extra))
      |> assign_unsaved()

    # Opened by id from a board's wiki: settle on the address itself.
    socket =
      case {params["page"] || params["folder"], vault_here(socket)} do
        {nil, _} -> socket
        {_, url} -> push_patch(socket, to: url, replace: true)
      end

    {:noreply, assign_current(socket)}
  end

  defp show_params(socket, params) do
    # `folder` is the index's own state; every other action clears it rather
    # than inheriting the last one looked at.
    # Opening something from the drawer shuts it, and puts away a file shown
    # in the page's place (#773): the page is what was asked for.
    socket =
      socket
      |> assign(folder: nil, tree_drawer: false, file_shown: nil)
      |> apply_action(socket.assigns.live_action, params)
      |> assign_unsaved()

    {:noreply, assign_current(socket)}
  end

  # The events, by what they act on: each module says which it handles
  # (`SlipdockWeb.WikiLive.Events`).
  @event_modules [PageEvents, TreeEvents, ItemEvents]

  @impl true
  def handle_event(event, params, socket) do
    case Enum.find(@event_modules, &Enum.member?(&1.events(), event)) do
      nil -> raise FunctionClauseError, module: __MODULE__, function: :handle_event, arity: 3
      module -> module.handle_event(event, params, socket)
    end
  end

  @impl true
  # The AI's suggestions for a folder's Organise… (#791).
  def handle_async(:organise_ai, result, socket) do
    case socket.assigns.tree_prompt do
      %{kind: :organise, mode: "ai"} = prompt ->
        prompt =
          case result do
            {:ok, {:ok, plan}} -> %{prompt | plan: plan, error: nil}
            {:ok, {:error, message}} -> %{prompt | plan: nil, error: message}
            {:exit, _} -> %{prompt | plan: nil, error: "The model couldn't be asked just now."}
          end

        {:noreply, assign(socket, tree_prompt: %{prompt | asking: false, excluded: MapSet.new()})}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  # Changes come in bursts — an import or a sync sends one per page, several a
  # second for minutes — and each reload reads the whole wiki. So a change
  # only books a reload a moment off, and those that land before it share it:
  # one reload per burst, not one per page, and the tab stays answerable.
  # An action from the AI tools became a card, which may have written its
  # number into the page.
  def handle_info({:page_tool_card, %Page{} = page}, socket),
    do: {:noreply, reload(socket, page)}

  def handle_info(:autosave, socket) do
    {:noreply, socket |> assign(autosave_timer: false) |> flush_autosave()}
  end

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
      socket
      |> assign(reload_booked: false)
      |> refresh_tree_icons()
      |> load_tree()
      |> assign_wanted()
      |> assign_current()

    {:noreply,
     case socket.assigns.page do
       %Page{} = page ->
         fresh = Wiki.get_page(page.id) || page
         socket |> assign_page(fresh) |> assign(cards: card_links(fresh))

       _ ->
         socket
     end}
  end

  # From Helpers.drop_invalid_uploads/2, which is shared with the board's
  # components and so says its flash by message.
  def handle_info({:shares_changed}, socket),
    do:
      {:noreply,
       assign(socket, shared_tree: Slipdock.Wiki.SharedTree.for_user(socket.assigns.current_user))}

  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # Another writer may have turned the tree's icons on or off (#792).
  defp refresh_tree_icons(%{assigns: %{board: %{id: id} = board}} = socket) do
    case Wiki.tree_icons?(id) do
      nil -> socket
      on -> assign(socket, board: %{board | wiki_tree_icons: on})
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
      waiting_count={@waiting_count}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={if @vault_view, do: :wiki, else: :boards}
      page_jumps={@page_jumps}
    >
      <:subnav>
        <.wiki_crumbs
          board={@board}
          current_user={@current_user}
          folder={@folder}
          page={@page}
          tree_context={@tree_context}
          vault_addresses={@vault_addresses}
          vault_view={@vault_view}
        />
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
      <:menu :if={!@view_only and !@vault_view}>
        <BoardView.board_menu
          paths={@board_paths}
          can_manage={@can_manage}
          card_only={false}
          view_only={@view_only}
          ai?={false}
          rules={[]}
          inbound={@inbound}
          navigate
        />
      </:menu>

      <%!-- A column the height of the layout's <main>, so the page tree and
            the page each scroll inside it. Without it the two panes grow to
            the length of the page and run out past the bottom of the app
            (#323). --%>
      <%!-- WikiFileOpen: a click on a link to a file opens it beside the
            page rather than in place of it (#768). --%>
      <div id="wiki-shell" phx-hook="WikiFileOpen" class="flex h-full flex-col">
        <.wiki_toolbar
          board={@board}
          board_paths={@board_paths}
          can_manage={@can_manage}
          can_write={@can_write}
          filtering={@filtering}
          filters={@filters}
          hidden={@hidden}
          inbound={@inbound}
          live_action={@live_action}
          marks={@marks}
          show={@show}
          shown={@shown}
          tree_drawer={@tree_drawer}
          vault_view={@vault_view}
          view_only={@view_only}
        />

        <div class="flex min-h-0 flex-1 overflow-hidden">
          <.tree_pane
            all_folders={@all_folders}
            board={@board}
            can_write={@can_write}
            current_user={@current_user}
            filtering={@filtering}
            filters={@filters}
            folder={@folder}
            inbound={@inbound}
            live_action={@live_action}
            organising={@organising}
            page={@page}
            shared_tree={@shared_tree}
            tree_contents={@tree_contents}
            tree_current={@tree_current}
            tree_drawer={@tree_drawer}
            tree_empty={@tree_empty}
            tree_filter={@tree_filter}
            tree_recent={@tree_recent}
            tree_reveal={@tree_reveal}
            tree_scope={@tree_scope}
            tree_version={@tree_version}
            tree_view={@tree_view}
            vault={@vault}
            vault_view={@vault_view}
          />

          <%!-- Drag to make the tree wider or narrower; the arrow keys too,
                and a double-click or Enter puts it back (#737). Wide screens
                only: on a phone the tree is a drawer. --%>
          <div id="wiki-tree-resize-keep" phx-update="ignore" class="hidden lg:contents">
            <div
              id="wiki-tree-resize"
              phx-hook="WikiTreeResize"
              data-pane="wiki-tree"
              role="separator"
              aria-orientation="vertical"
              aria-controls="wiki-tree"
              aria-label="Resize the page tree"
              tabindex="0"
              title="Drag to resize · double-click to reset"
              class="-ml-1 w-2 shrink-0 cursor-col-resize touch-none select-none border-l-2 border-transparent hover:border-primary/50 focus-visible:border-primary focus-visible:outline-none data-[dragging]:border-primary"
            >
            </div>
          </div>

          <div
            :if={@tree_drawer}
            id="wiki-tree-backdrop"
            class="fixed inset-0 z-40 bg-base-content/30 lg:hidden"
            phx-click="close_tree_drawer"
            phx-window-keydown="close_tree_drawer"
            phx-key="Escape"
          >
          </div>
          <.wiki_main
            autosaved?={@autosaved?}
            backlinks={@backlinks}
            base={@base}
            base_hash={@base_hash}
            board={@board}
            can_comment={@can_comment}
            can_manage={@can_manage}
            can_write={@can_write}
            card_query={@card_query}
            card_results={@card_results}
            cards={@cards}
            children={@children}
            columns={@columns}
            comparing={@comparing}
            conflict={@conflict}
            current_user={@current_user}
            diff={@diff}
            excerpts={@excerpts}
            fields_board={@fields_board}
            file_shown={@file_shown}
            folder={@folder}
            folder_more={@folder_more}
            folder_outline={@folder_outline}
            folder_rows={@folder_rows}
            form={@form}
            form_key={@form_key}
            history_previews={@history_previews}
            html={@html}
            index_folders={@index_folders}
            latest_revision={@latest_revision}
            live_action={@live_action}
            marks={@marks}
            new_column={@new_column}
            page={@page}
            page_shares={@page_shares}
            page_tools={@page_tools}
            page_tools_ai={@page_tools_ai}
            preview={@preview}
            recent={@recent}
            recording={@recording}
            recording_help={@recording_help}
            restored_from={@restored_from}
            revision={@revision}
            revision_changes={@revision_changes}
            revisions={@revisions}
            show_preview={@show_preview}
            tags={@tags}
            tree_empty={@tree_empty}
            unsaved={@unsaved}
            uploads={@uploads}
            vault_dir={@vault_dir}
            vault_view={@vault_view}
            wanted={@wanted}
          />

          <.file_panel :if={@file_shown} shown={@file_shown} />

          <.live_component
            :if={@page_tools and page_tools_button(assigns) != nil and is_nil(@file_shown)}
            module={PageToolsComponent}
            id={"page-tools-#{(@page && @page.id) || "new"}"}
            board={@board}
            page={@page}
            title={page_tools_source(assigns).title}
            text={page_tools_source(assigns).text}
            editing={@live_action in [:new, :edit]}
            can_write={@can_write}
            current_user={@current_user}
          />
        </div>
      </div>

      <.folder_modal :if={@folder_modal} modal={@folder_modal} outline={@folder_outline} />
      <.folder_delete_modal :if={@folder_delete} folder={@folder_delete} owner={@can_manage} />
      <.tree_prompt :if={@tree_prompt} prompt={@tree_prompt} />
      <.share_modal :if={@share_modal} modal={@share_modal} />
      <%!-- The `…` menu's Email to this board, as on the board's views. --%>
      <.live_component
        :if={@inbound}
        module={SlipdockWeb.InboundAddressesComponent}
        id="board-inbound"
        board={@board}
        current_user={@current_user}
      />
    </Layouts.app>
    """
  end
end
