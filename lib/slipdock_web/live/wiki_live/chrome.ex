defmodule SlipdockWeb.WikiLive.Chrome do
  @moduledoc """
  The frame of the wiki view (`WikiLive.Index.render/1`), in four parts:
  the header's breadcrumbs, the bar above the tree, the tree pane and the
  middle column. Each is given the assigns it reads, by name.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents,
    only: [view_tabs: 1, filter_menu: 1]

  import SlipdockWeb.WikiLive.Format
  import SlipdockWeb.WikiLive.FolderView
  import SlipdockWeb.WikiLive.PageView
  import SlipdockWeb.WikiLive.Editor
  import SlipdockWeb.WikiLive.HistoryView
  alias Slipdock.Palette
  alias SlipdockWeb.BoardLive.BoardView

  attr :board, :any, required: true
  attr :current_user, :any, required: true
  attr :folder, :any, required: true
  attr :page, :any, required: true
  attr :tree_context, :any, required: true
  attr :vault_addresses, :any, required: true
  attr :vault_view, :any, required: true

  # The header's breadcrumbs: the vault's, the board's, or another board's
  # tree's when a page was opened from it (#758).
  def wiki_crumbs(assigns) do
    ~H"""
    <%!-- The vault view's breadcrumbs: the vault, the directories down to
          what is shown, and quietly, the board that holds it. --%>
    <nav :if={@vault_view} id="vault-crumbs" class="flex min-w-0 items-center gap-1 text-sm">
      <.link
        navigate={SlipdockWeb.VaultUrls.url(@vault_view)}
        class="flex min-w-0 items-center gap-1.5 rounded-lg px-2 py-1 font-semibold hover:bg-base-200"
      >
        <.icon name="hero-rectangle-stack" class="size-4 shrink-0 text-primary" />
        <span class="truncate">Wiki</span>
      </.link>
      <%= for crumb <- vault_crumbs(@vault_view, @vault_addresses, @page, @folder, @current_user.tree_names) do %>
        <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
        <.link
          navigate={crumb.url}
          title={crumb.full}
          class="min-w-0 truncate rounded-lg px-1.5 py-1 hover:bg-base-200"
        >
          {crumb.name}
        </.link>
      <% end %>
      <%!-- Which board holds what is open. The vault's top holds nothing,
           so it names no board, though the view stands on one. --%>
      <.link
        :if={@page || @folder}
        id="vault-board"
        navigate={if @page, do: page_path(@board, @page), else: wiki_path(@board)}
        class="ml-2 hidden shrink-0 items-center gap-1 rounded-full px-2 py-0.5 text-xs text-base-content/50 hover:bg-base-200 sm:flex"
        title="The board that holds it: its permissions, history and comments"
      >
        <span class={["size-2 rounded-full", Palette.dot(@board.color)]}></span> on {@board.name}
      </.link>
    </nav>
    <nav :if={!@vault_view && !@tree_context} class="flex min-w-0 items-center gap-1 text-sm">
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
    <%!-- Opened from another board's tree (#758): that board's
          breadcrumbs, and quietly, the board that holds what is shown. --%>
    <nav
      :if={!@vault_view && @tree_context}
      id="context-crumbs"
      class="flex min-w-0 items-center gap-1 text-sm"
    >
      <.link
        navigate={~p"/boards/#{@tree_context}"}
        class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
      >
        <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@tree_context.color)]}></span>
        <span class="truncate font-semibold">{@tree_context.name}</span>
      </.link>
      <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
      <.link
        navigate={wiki_path(@tree_context)}
        class="rounded-lg px-2 py-1 font-semibold hover:bg-base-200"
      >
        Wiki
      </.link>
      <.link
        id="context-board"
        navigate={if @page, do: page_path(@board, @page), else: wiki_path(@board)}
        class="ml-2 hidden shrink-0 items-center gap-1 rounded-full px-2 py-0.5 text-xs text-base-content/50 hover:bg-base-200 sm:flex"
        title="The board that holds it: open it in that board's own wiki"
      >
        <span class={["size-2 rounded-full", Palette.dot(@board.color)]}></span> on {@board.name}
      </.link>
    </nav>
    """
  end

  attr :board, :any, required: true
  attr :board_paths, :any, required: true
  attr :can_manage, :any, required: true
  attr :can_write, :any, required: true
  attr :filtering, :any, required: true
  attr :filters, :any, required: true
  attr :hidden, :any, required: true
  attr :inbound, :any, required: true
  attr :live_action, :any, required: true
  attr :marks, :any, required: true
  attr :show, :any, required: true
  attr :shown, :any, required: true
  attr :tree_drawer, :any, required: true
  attr :vault_view, :any, required: true
  attr :view_only, :any, required: true

  # The bar above the tree and the page: the tree's toggles, the view tabs,
  # search, the filter menu and the board's `…` menu.
  def wiki_toolbar(assigns) do
    ~H"""
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
      <%!-- The tree, on a wide screen: folded away and back (#737). The
            WikiTreeCollapse hook (assets/js/wiki_pane.js) keeps the
            choice in this browser, and sets aria-expanded, hence the
            ignore. --%>
      <span id="wiki-tree-collapse-keep" phx-update="ignore" class="hidden lg:inline-flex">
        <button
          id="wiki-tree-collapse"
          type="button"
          phx-hook="WikiTreeCollapse"
          class="group btn btn-ghost btn-sm btn-square"
          aria-controls="wiki-tree"
          aria-expanded="true"
          title="Hide the page tree"
        >
          <.icon
            name="hero-chevron-double-left"
            class="size-4 group-aria-expanded:inline-block hidden"
          />
          <.icon name="hero-chevron-double-right" class="size-4 group-aria-expanded:hidden" />
          <span class="sr-only">Page tree</span>
        </button>
      </span>
      <%!-- The page in a column, or across the whole width (#748). The
            WikiWidthToggle hook keeps the choice in this browser and
            puts it on <html> (see `#wiki-column` in app.css); writing
            takes the whole width either way. --%>
      <span
        :if={@live_action not in [:new, :edit]}
        id="wiki-width-toggle-keep"
        phx-update="ignore"
        class="hidden lg:inline-flex"
      >
        <button
          id="wiki-width-toggle"
          type="button"
          phx-hook="WikiWidthToggle"
          class="group btn btn-ghost btn-sm btn-square"
          aria-controls="wiki-column"
          aria-pressed="false"
          title="Read across the full width"
        >
          <.icon
            name="hero-arrows-pointing-out"
            class="size-4 group-aria-pressed:hidden"
          />
          <.icon
            name="hero-arrows-pointing-in"
            class="size-4 hidden group-aria-pressed:inline-block"
          />
          <span class="sr-only">Page width</span>
        </button>
      </span>
      <.view_tabs
        board={@board}
        mode={:wiki}
        view={nil}
        marks={@marks}
      />
      <span class="hidden h-5 w-px bg-base-300 sm:block"></span>

      <form id="wiki-search" phx-change="search" phx-submit="search" class="relative">
        <.search_input
          value={@filters.q}
          placeholder="Titles, folders, #tags…"
          phx-debounce="200"
          class="w-56 transition-[width] focus:w-72"
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
          <p class="section-label">
            Show in the tree
          </p>
          <label :if={@can_write} class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              type="checkbox"
              class="toggle"
              checked={@show.drafts}
              phx-click="toggle_show"
              phx-value-what="drafts"
            /> Drafts
          </label>
          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              type="checkbox"
              class="toggle"
              checked={@show.templates}
              phx-click="toggle_show"
              phx-value-what="templates"
            /> Templates
          </label>
          <label :if={@can_write} class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              type="checkbox"
              class="toggle"
              checked={@show.archived}
              phx-click="toggle_show"
              phx-value-what="archived"
            /> Archived pages
          </label>
          <%!-- The board's choice, not the reader's (#792): writers set it
                for everyone, as they do the tree's order. --%>
          <label :if={@can_write} class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              id="toggle-tree-icons"
              type="checkbox"
              class="toggle"
              checked={@board.wiki_tree_icons}
              phx-click="toggle_tree_icons"
            /> Icons and colours
          </label>
        </div>
      </div>

      <span
        id="tree-page-count"
        class="ml-auto hidden text-xs text-base-content/50 lg:inline"
        title="Pages shown"
      >
        {@shown} {if @shown == 1, do: "page", else: "pages"}<span :if={@hidden > 0}> · {@hidden} hidden</span>
      </span>
      <%!-- The board's own `…` menu, as on its other views. --%>
      <div :if={!@view_only and !@vault_view} class="ml-auto lg:ml-0">
        <BoardView.board_more_menu
          paths={@board_paths}
          can_manage={@can_manage}
          rules={[]}
          inbound={@inbound}
          navigate
        />
      </div>
    </div>
    """
  end

  attr :all_folders, :any, required: true
  attr :board, :any, required: true
  attr :can_write, :any, required: true
  attr :current_user, :any, required: true
  attr :filtering, :any, required: true
  attr :filters, :any, required: true
  attr :folder, :any, required: true
  attr :inbound, :any, required: true
  attr :live_action, :any, required: true
  attr :organising, :any, required: true
  attr :page, :any, required: true
  attr :shared_tree, :any, required: true
  attr :tree_contents, :any, required: true
  attr :tree_current, :any, required: true
  attr :tree_drawer, :any, required: true
  attr :tree_empty, :any, required: true
  attr :tree_filter, :any, required: true
  attr :tree_recent, :any, required: true
  attr :tree_reveal, :any, required: true
  attr :tree_scope, :any, required: true
  attr :tree_version, :any, required: true
  attr :tree_view, :any, required: true
  attr :vault, :any, required: true
  attr :vault_view, :any, required: true

  # The page tree down the left (a drawer on a phone): its header, the rows
  # the WikiTree hook draws, the Recent view and the pages shared with the reader.
  def tree_pane(assigns) do
    ~H"""
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
      data-inbound={to_string(@inbound)}
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
      <div id="wiki-tree-head" class="mb-2 flex items-center gap-1">
        <.link
          patch={wiki_path(@board)}
          class={[
            "flex min-w-0 flex-1 items-center gap-2 rounded-lg px-2 py-1.5 text-sm font-semibold hover:bg-base-200",
            @live_action == :index && is_nil(@folder) && "bg-base-200"
          ]}
        >
          <.icon name="hero-book-open" class="size-4 shrink-0" />
          <span class="truncate">All pages</span>
        </.link>
        <%!-- The tree, or this board's pages last edited first (#738),
              on the same line as everything else up here (#739). The
              WikiTreeView hook keeps the choice in this browser. --%>
        <div
          id="wiki-tree-view"
          phx-hook="WikiTreeView"
          class="join shrink-0"
          role="group"
          aria-label="How to list the pages"
        >
          <button
            :for={
              {view, icon, label} <- [
                {"tree", "hero-folder", "Pages in their folders"},
                {"recent", "hero-clock", "The most recently edited pages first"}
              ]
            }
            id={"wiki-tree-view-#{view}"}
            type="button"
            phx-click="tree_view"
            phx-value-view={view}
            class={["btn btn-xs btn-square join-item", @tree_view == view && "btn-active"]}
            aria-pressed={to_string(@tree_view == view)}
            aria-label={if view == "recent", do: "Recent", else: "Tree"}
            title={label}
          >
            <.icon name={icon} class="size-4" />
          </button>
        </div>
        <%!-- Full titles or short names: one person's choice, kept with
              them rather than in this browser (account settings too). --%>
        <button
          id="wiki-tree-names"
          type="button"
          phx-click="toggle_tree_names"
          class={[
            "btn btn-ghost btn-xs btn-square shrink-0",
            @current_user.tree_names == "short" && "btn-active"
          ]}
          aria-pressed={to_string(@current_user.tree_names == "short")}
          aria-label="Short names"
          title={
            if @current_user.tree_names == "short",
              do: "Showing short names: show full titles",
              else: "Showing full titles: show short names"
          }
        >
          <.icon name="hero-bars-3-bottom-left" class="size-4" />
        </button>
        <%!-- Open or shut every folder at once. Not while filtering or
              organising: a filter opens what it found itself. The
              hook keeps its icon and title, so it is left alone here. --%>
        <span
          id="wiki-tree-toggle-all-box"
          class={[
            (@filtering or @organising or @all_folders == [] or @tree_view == "recent") &&
              "hidden"
          ]}
        >
          <span id="wiki-tree-toggle-all-keep" phx-update="ignore">
            <button
              id="wiki-tree-toggle-all"
              type="button"
              data-tree-toggle-all
              class="btn btn-ghost btn-xs btn-square shrink-0"
              title="Open or close all folders"
            >
              <.icon name="hero-chevron-double-down" class="size-4" />
            </button>
          </span>
        </span>
        <%!-- Back to where you are, after shutting or scrolling it away
              (the hook opens the way and scrolls to it). --%>
        <button
          :if={@tree_current != "" and @tree_view == "tree"}
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
          :if={@can_write and @tree_view == "tree"}
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
      <%!-- In the wiki view the tree is the whole wiki's, and its
            settings are a click away. --%>
      <div :if={@vault_view} class="mb-2 flex items-center gap-1">
        <span class="min-w-0 flex-1 truncate px-1 text-xs font-semibold text-base-content/60">
          Your wiki
        </span>
        <.link
          id="vault-settings"
          navigate={SlipdockWeb.VaultUrls.settings(@vault_view)}
          class="btn btn-ghost btn-xs gap-1"
          title="Your wiki's keys, recordings folder and synced folders"
        >
          <.icon name="hero-cog-6-tooth" class="size-3.5" /> Settings
        </.link>
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
            class="checkbox"
            checked={@tree_contents}
            phx-click="toggle_tree_contents"
          /> Match the words inside pages here too
        </label>
      </p>
      <p
        :if={@tree_empty and not @filtering and (@tree_scope == "board" or @tree_view == "recent")}
        class="px-2 py-4 text-sm text-base-content/50"
      >
        Nothing written yet.
      </p>
      <p
        :if={@tree_view == "tree" && @tree_filter && @tree_filter.nodes == %{}}
        class="px-2 py-4 text-sm text-base-content/50"
      >
        No page or folder name matches that.
      </p>
      <%!-- Focusable, and owning its keys while focused (the arrows,
            F2, Delete, type-ahead), which the page-wide shortcuts
            stand down for. --%>
      <%!-- What is picked with Ctrl/Cmd- or Shift-click, and what can be
            done to all of it: drawn by the hook. --%>
      <%!-- Recent: a flat list, newest edit first, drawn here rather
            than by the hook. The tree's own rows stay mounted, hidden,
            so switching back finds them as they were left. --%>
      <ul
        :if={@tree_view == "recent"}
        id="wiki-tree-recent"
        class="space-y-0.5"
        aria-label="Recently edited pages"
      >
        <li :for={page <- @tree_recent} id={"wiki-recent-#{page.id}"}>
          <.link
            patch={page.href}
            class={[
              "flex items-baseline gap-2 rounded-lg px-2 py-1 text-sm hover:bg-base-200",
              @page && @page.id == page.id && "bg-base-200 font-medium"
            ]}
            title={"Edited #{stamp(page.updated_at)}"}
          >
            <span class={["min-w-0 flex-1 truncate", page.archived && "line-through opacity-60"]}>
              {page.title}
            </span>
            <span :if={page.draft} class="badge badge-ghost badge-xs shrink-0">draft</span>
            <span class="shrink-0 text-2xs text-base-content/40">
              {recent_stamp(page.updated_at)}
            </span>
          </.link>
        </li>
        <li
          :if={@tree_recent == [] and not @tree_empty}
          class="px-2 py-4 text-sm text-base-content/50"
        >
          No page matches that.
        </li>
      </ul>
      <div class={[@tree_view == "recent" && "hidden"]}>
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
      </div>
      <button
        :if={@can_write}
        type="button"
        phx-click="new_folder"
        class="mt-2 flex w-full items-center gap-1.5 rounded-lg px-2 py-1.5 text-sm text-base-content/60 hover:bg-base-200"
      >
        <.icon name="hero-folder-plus" class="size-4" /> New folder
      </button>
      <%!-- What other people have shared with this reader (#817), under
            every one of their trees: hidden when there is nothing. --%>
      <div :if={@shared_tree != []} class="mt-4 border-t border-base-300 pt-3">
        <SlipdockWeb.SharedComponents.shared_tree groups={@shared_tree} id="wiki-shared-tree" />
      </div>
    </aside>
    """
  end

  attr :autosaved?, :any, required: true
  attr :backlinks, :any, required: true
  attr :base, :any, required: true
  attr :base_hash, :any, required: true
  attr :board, :any, required: true
  attr :can_comment, :any, required: true
  attr :can_manage, :any, required: true
  attr :can_write, :any, required: true
  attr :card_query, :any, required: true
  attr :card_results, :any, required: true
  attr :cards, :any, required: true
  attr :children, :any, required: true
  attr :columns, :any, required: true
  attr :comparing, :any, required: true
  attr :conflict, :any, required: true
  attr :current_user, :any, required: true
  attr :diff, :any, required: true
  attr :excerpts, :any, required: true
  attr :fields_board, :any, required: true
  attr :file_shown, :any, required: true
  attr :folder, :any, required: true
  attr :folder_more, :any, required: true
  attr :folder_outline, :any, required: true
  attr :folder_rows, :any, required: true
  attr :form, :any, required: true
  attr :form_key, :any, required: true
  attr :history_previews, :any, required: true
  attr :html, :any, required: true
  attr :index_folders, :any, required: true
  attr :latest_revision, :any, required: true
  attr :live_action, :any, required: true
  attr :marks, :any, required: true
  attr :new_column, :any, required: true
  attr :page, :any, required: true
  attr :page_shares, :any, required: true
  attr :page_tools, :any, required: true
  attr :page_tools_ai, :any, required: true
  attr :preview, :any, required: true
  attr :recent, :any, required: true
  attr :recording, :any, required: true
  attr :recording_help, :any, required: true
  attr :restored_from, :any, required: true
  attr :revision, :any, required: true
  attr :revision_changes, :any, required: true
  attr :revisions, :any, required: true
  attr :show_preview, :any, required: true
  attr :tags, :any, required: true
  attr :tree_empty, :any, required: true
  attr :unsaved, :any, required: true
  attr :uploads, :any, required: true
  attr :vault_dir, :any, required: true
  attr :vault_view, :any, required: true
  attr :wanted, :any, required: true

  # The middle column: a folder, the index, a page, its editor or its
  # history, as the address says.
  def wiki_main(assigns) do
    ~H"""
    <%!-- `relative`: the status buttons' radios are `sr-only`, which is
          `position: absolute`, and with nothing positioned above them
          they stretched the whole document to the page's length. --%>
    <%!-- A page is opened in place (a patch), so the tree stays as it was
          rather than being rebuilt and sent again; ScrollTopOnPage puts
          this column back at the top when the page changes. --%>
    <%!-- Hidden rather than taken away while a file is shown in its
          place (#773), so a half-written edit is still there when
          the file is put away. --%>
    <main
      id="wiki-main"
      phx-hook="ScrollTopOnPage"
      data-page={"#{@live_action}:#{@page && @page.id}"}
      class={[
        "kanban-scroll relative min-w-0 flex-1 overflow-y-auto",
        @file_shown && "hidden"
      ]}
    >
      <%!-- Reading keeps one measure for the whole article, text,
            headings, rules and footer alike (#1743, `.wiki-reading` in
            app.css), unless the reader asked for the full width (#748);
            writing takes the whole width. --%>
      <div
        id="wiki-column"
        data-measure={if(@live_action in [:new, :edit], do: "wide", else: "reading")}
        class={[
          "mx-auto px-4 py-6 sm:px-8 sm:py-8",
          if(@live_action in [:new, :edit], do: "max-w-none", else: "wiki-reading")
        ]}
      >
        <.unsaved_pages :if={@unsaved != []} board={@board} unsaved={@unsaved} />
        <%= case @live_action do %>
          <% :index when not is_nil(@folder) -> %>
            <.folder_body
              board={@board}
              folder={@folder}
              rows={@folder_rows}
              more={@folder_more}
              recent={@vault_dir && @recent}
              excerpts={@excerpts}
              can_write={@can_write}
              tree_names={@current_user.tree_names}
            />
          <% :index -> %>
            <.index_body
              board={@board}
              empty={@tree_empty}
              folders={@index_folders}
              recent={@recent}
              vault={@vault_dir && @vault_view}
              vault_dir={@vault_dir}
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
              autosaved?={@autosaved?}
              restored_from={@restored_from}
              page_tools={page_tools_button(assigns)}
            />
          <% :history -> %>
            <.history_body
              board={@board}
              page={@page}
              revisions={@revisions}
              changes={@revision_changes}
              previews={@history_previews}
            />
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
              recording={@recording}
              recording_help={@recording_help}
              backlinks={@backlinks}
              children={@children}
              cards={@cards}
              card_query={@card_query}
              card_results={@card_results}
              outline={@folder_outline}
              tags={@tags}
              columns={@columns}
              can_write={@can_write}
              can_comment={@can_comment}
              can_manage={@can_manage}
              current_user={@current_user}
              form_key={@form_key}
              shares={@page_shares}
              marks={@marks}
              page_tools={page_tools_button(assigns)}
            />
        <% end %>
      </div>
    </main>
    """
  end
end
