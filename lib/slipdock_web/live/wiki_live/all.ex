defmodule SlipdockWeb.WikiLive.All do
  @moduledoc """
  The Wiki view from the Home page: every board's documents in one tree.

  Boards are the top level, folders are inside them, pages are inside those.
  That is the whole idea — the wiki on a board answers "what is written about
  this project", and this answers "where is anything written at all", which
  is the question somebody looking for a document they half-remember is
  actually asking.

  Read-only on purpose. Making, renaming and moving folders belongs on the
  board that owns them (`SlipdockWeb.WikiLive.Index`), where the permissions
  and the rest of the wiki's tools already are; a cross-board view that could
  also rearrange four boards at once is a way to file something in the wrong
  place without noticing.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Palette

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Wiki",
       q: "",
       # Shut boards and folders. Collapsing is a reader's convenience, so it
       # lives here rather than in anything saved.
       collapsed: MapSet.new(),
       show_drafts: true
     )
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_user
    query = String.trim(socket.assigns.q || "")

    boards =
      user
      |> Access.list_boards()
      |> Enum.map(fn board ->
        perm = Access.board_permission(user, board)
        can_write = Access.can_write?(perm)

        pages =
          board
          |> Wiki.list_pages(
            status: if(can_write and socket.assigns.show_drafts, do: nil, else: "published"),
            template: false
          )
          |> Enum.filter(&matches?(&1, query))

        %{
          board: board,
          can_write: can_write,
          count: length(pages),
          # While a search is running, a folder with nothing matching in it is
          # noise: the reader asked where something is, not what the filing
          # cabinet looks like.
          folders: board |> Wiki.folder_tree(pages) |> prune(query != ""),
          pages: Wiki.unfiled(pages)
        }
      end)

    assign(socket,
      boards: boards,
      total: Enum.sum(Enum.map(boards, & &1.count)),
      searching: query != ""
    )
  end

  defp prune(nodes, false), do: nodes

  defp prune(nodes, true) do
    nodes
    |> Enum.map(&%{&1 | children: prune(&1.children, true)})
    |> Enum.reject(&(&1.pages == [] and &1.children == []))
  end

  # Searching matches the title and the one-line summary, not the body: this
  # is the filing cabinet, and full-text belongs in Search (`/search`), which
  # matches by meaning and already covers pages.
  defp matches?(_page, ""), do: true

  defp matches?(page, query) do
    term = String.downcase(query)

    String.contains?(String.downcase(page.title), term) or
      String.contains?(String.downcase(page.summary || ""), term)
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(q: q) |> load()}

  def handle_event("toggle", %{"key" => key}, socket) do
    collapsed = socket.assigns.collapsed

    {:noreply,
     assign(socket,
       collapsed:
         if(MapSet.member?(collapsed, key),
           do: MapSet.delete(collapsed, key),
           else: MapSet.put(collapsed, key)
         )
     )}
  end

  def handle_event("toggle_drafts", _params, socket),
    do: {:noreply, socket |> assign(show_drafts: not socket.assigns.show_drafts) |> load()}

  # While a search is running everything is open: a hit three folders down is
  # no use to anyone behind a closed folder.
  defp shut?(_collapsed, _key, true), do: false
  defp shut?(collapsed, key, _searching), do: MapSet.member?(collapsed, key)

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
      nav_active={:wiki}
      page_jumps={[]}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-4xl px-4 py-6 sm:px-6 sm:py-10">
          <div class="mb-6 flex flex-wrap items-end justify-between gap-4">
            <div>
              <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Wiki</h1>
              <p class="mt-1 text-sm text-base-content/60">
                Everything written, everywhere: each board a folder, and its own folders inside.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <form id="wiki-all-search" phx-change="search" phx-submit="search" class="relative">
                <.icon
                  name="hero-magnifying-glass"
                  class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
                />
                <input
                  type="search"
                  name="q"
                  value={@q}
                  placeholder="Find a document…"
                  phx-debounce="200"
                  autocomplete="off"
                  class="input input-sm w-44 rounded-full pl-8 transition-[width] focus:w-64"
                />
              </form>
              <label class="flex cursor-pointer items-center gap-2 text-xs text-base-content/60">
                <input
                  type="checkbox"
                  class="toggle toggle-xs"
                  checked={@show_drafts}
                  phx-click="toggle_drafts"
                /> Drafts
              </label>
            </div>
          </div>

          <p class="mb-4 text-xs text-base-content/50">
            {@total} {if @total == 1, do: "page", else: "pages"}<span :if={@searching}> matching “{@q}”</span>
          </p>

          <div class="space-y-2">
            <section
              :for={entry <- @boards}
              class="overflow-hidden rounded-2xl border border-base-300 bg-base-100"
            >
              <div class="flex items-center gap-2 px-3 py-2.5">
                <button
                  type="button"
                  phx-click="toggle"
                  phx-value-key={"board-#{entry.board.id}"}
                  class="flex min-w-0 flex-1 items-center gap-2 text-left"
                >
                  <.icon
                    name={
                      if shut?(@collapsed, "board-#{entry.board.id}", @searching),
                        do: "hero-chevron-right",
                        else: "hero-chevron-down"
                    }
                    class="size-3.5 shrink-0 text-base-content/40"
                  />
                  <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(entry.board.color)]}></span>
                  <span class="min-w-0 flex-1 truncate font-semibold">{entry.board.name}</span>
                  <span class="shrink-0 text-xs text-base-content/40">{entry.count}</span>
                </button>
                <.link
                  navigate={~p"/boards/#{entry.board}/wiki"}
                  class="btn btn-ghost btn-xs shrink-0"
                  title="Open this board's wiki"
                >
                  Open
                </.link>
                <.link
                  :if={entry.can_write}
                  navigate={~p"/boards/#{entry.board}/wiki/new"}
                  class="btn btn-ghost btn-xs btn-square shrink-0"
                  title="New page on this board"
                >
                  <.icon name="hero-plus" class="size-4" />
                </.link>
              </div>

              <div
                :if={not shut?(@collapsed, "board-#{entry.board.id}", @searching)}
                class="border-t border-base-300 px-3 py-2"
              >
                <p
                  :if={entry.folders == [] and entry.pages == []}
                  class="py-1 text-sm text-base-content/50"
                >
                  {if @searching,
                    do: "Nothing matching here.",
                    else: "Nothing written on this board yet."}
                </p>
                <.folders
                  nodes={entry.folders}
                  board={entry.board}
                  collapsed={@collapsed}
                  searching={@searching}
                  depth={0}
                />
                <.pages nodes={entry.pages} board={entry.board} depth={0} />
              </div>
            </section>
          </div>

          <p
            :if={@boards == []}
            class="rounded-2xl border border-dashed border-base-300 p-8 text-center text-sm text-base-content/60"
          >
            No boards yet. <.link navigate={~p"/"} class="link">Make one</.link>
            and its wiki starts here.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :nodes, :list, required: true
  attr :board, :any, required: true
  attr :collapsed, :any, required: true
  attr :searching, :boolean, default: false
  attr :depth, :integer, default: 0

  defp folders(assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li :for={%{folder: folder, children: children, pages: pages} = node <- @nodes}>
        <%!-- The chevron opens the folder here; the name opens the folder on
              its own board, which is where anything can be done to it. --%>
        <div
          class="flex items-center gap-1.5 rounded-lg pr-2 text-sm hover:bg-base-200"
          style={"padding-left: #{0.25 + @depth * 0.9}rem"}
        >
          <button
            type="button"
            phx-click="toggle"
            phx-value-key={"folder-#{folder.id}"}
            class="shrink-0 py-1.5"
            aria-label="Open or close this folder"
          >
            <.icon
              name={
                if shut?(@collapsed, "folder-#{folder.id}", @searching),
                  do: "hero-chevron-right",
                  else: "hero-chevron-down"
              }
              class="size-3 shrink-0 text-base-content/40"
            />
          </button>
          <.link
            navigate={~p"/boards/#{@board}/wiki?#{[folder: folder.id]}"}
            class="flex min-w-0 flex-1 items-center gap-1.5 py-1.5 text-left"
            title={"Open #{folder.name} on #{@board.name}"}
          >
            <.icon name="hero-folder" class="size-3.5 shrink-0 text-base-content/50" />
            <span class="min-w-0 flex-1 truncate font-medium">{folder.name}</span>
            <span class="shrink-0 text-2xs text-base-content/40">
              {Slipdock.Wiki.Folders.page_count(node)}
            </span>
          </.link>
        </div>
        <div :if={not shut?(@collapsed, "folder-#{folder.id}", @searching)}>
          <.folders
            :if={children != []}
            nodes={children}
            board={@board}
            collapsed={@collapsed}
            searching={@searching}
            depth={@depth + 1}
          />
          <.pages nodes={pages} board={@board} depth={@depth + 1} />
        </div>
      </li>
    </ul>
    """
  end

  attr :nodes, :list, required: true
  attr :board, :any, required: true
  attr :depth, :integer, default: 0

  defp pages(assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li :for={%{page: page, children: children} <- @nodes}>
        <.link
          navigate={~p"/boards/#{@board}/wiki/#{page.slug}"}
          style={"padding-left: #{0.5 + @depth * 0.9}rem"}
          class="flex items-center gap-1.5 rounded-lg py-1.5 pr-2 text-sm hover:bg-base-200"
          title={page.summary || page.title}
        >
          <.icon name="hero-document-text" class="size-3.5 shrink-0 text-base-content/40" />
          <span class="min-w-0 flex-1 truncate">{page.title}</span>
          <span
            :if={page.status == "draft"}
            class="shrink-0 rounded bg-amber-500/15 px-1 text-2xs font-medium text-amber-700"
          >
            draft
          </span>
          <span class="shrink-0 font-mono text-2xs text-base-content/40">{page.code}</span>
        </.link>
        <.pages :if={children != []} nodes={children} board={@board} depth={@depth + 1} />
      </li>
    </ul>
    """
  end
end
