defmodule SlipdockWeb.WikiLive.FolderView do
  @moduledoc """
  What the middle column shows of a folder (`WikiLive.Index`): a
  folder's own listing, a vault folder's recent notes, and the wiki's index.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.WikiLive.Format
  alias Slipdock.Wiki
  alias Slipdock.Vaults.Names

  attr :recent, :list,
    required: true,
    doc: "`Slipdock.Wiki.Tree` page rows with `href` and `where`"

  attr :excerpts, :map, default: %{}
  attr :in_folder, :boolean, default: false

  # A vault folder's notes, newest first (#1211), each saying which folder
  # below this one it is in.
  defp vault_recent(assigns) do
    ~H"""
    <section id="vault-recent" class="mt-8">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
        Recently edited
      </h2>
      <div
        :if={@recent == []}
        class="mt-3 rounded-xl border border-dashed border-base-300 p-8 text-center"
      >
        <.icon name="hero-document-text" class="size-7 text-base-content/30" />
        <p class="mt-3 text-sm text-base-content/60">
          {if @in_folder, do: "No notes in this folder yet.", else: "No notes here yet."}
        </p>
      </div>
      <ul
        :if={@recent != []}
        class="mt-3 divide-y divide-base-300 rounded-xl border border-base-300 bg-base-100"
      >
        <li :for={page <- @recent} id={"vault-recent-#{page.id}"}>
          <.link patch={page.href} class="flex items-baseline gap-3 px-4 py-3 hover:bg-base-200">
            <.wiki_icon
              :if={dressed?(page)}
              kind={:page}
              icon={page[:icon]}
              color={page[:color]}
              class="size-4 self-center"
            />
            <span class="min-w-0 flex-1">
              <span class="font-medium">{page.title}</span>
              <span :if={page.draft} class="chip chip-line ml-2 text-2xs">draft</span>
              <span
                :if={excerpt_of(@excerpts, page.id) != ""}
                class="ml-2 text-sm text-base-content/50"
              >
                {excerpt_of(@excerpts, page.id)}
              </span>
              <span
                :if={page.where != ""}
                class="vault-recent-where mt-0.5 flex items-center gap-1 text-xs text-base-content/40"
              >
                <.icon name="hero-folder" class="size-3" /> {page.where}
              </span>
            </span>
            <span class="shrink-0 text-xs text-base-content/40">{stamp(page.updated_at)}</span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  attr :board, :any, required: true
  attr :folder, :any, required: true
  attr :rows, :list, default: [], doc: "what is in it, as `Slipdock.Wiki.Tree` rows"
  attr :more, :boolean, default: false, doc: "whether there were more than are listed"
  attr :recent, :list, default: nil, doc: "in a vault, its notes newest first instead (#1211)"
  attr :excerpts, :map, default: %{}
  attr :can_write, :boolean, required: true
  attr :tree_names, :string, default: "full", doc: "`users.tree_names`"

  @doc false
  # One folder, looked at: what is in it, and everything you would want to do
  # to it. A folder with no page of its own to stand on is the thing that made
  # filing feel like an afterthought — this is that page.
  def folder_body(assigns) do
    assigns =
      assign(assigns,
        children: Enum.filter(assigns.rows, &(&1.kind == "folder")),
        crumbs: crumbs(Wiki.folder_ancestors(assigns.folder) ++ [assigns.folder]),
        # Where else it is filed (#808): its home is the path above.
        also_in: Wiki.FolderPlacements.folders(assigns.folder),
        pages: Enum.filter(assigns.rows, &(&1.kind == "page")),
        total:
          Enum.sum(for(%{kind: "folder", pages: n} <- assigns.rows, do: n)) +
            Enum.count(assigns.rows, &(&1.kind == "page"))
      )

    ~H"""
    <nav class="mb-2 flex flex-wrap items-center gap-1 text-sm text-base-content/50">
      <.link patch={wiki_path(@board)} class="hover:text-base-content">Wiki</.link>
      <span
        :for={{up, name} <- Enum.drop(@crumbs, -1)}
        class="flex min-w-0 items-center gap-1"
      >
        <.icon name="hero-chevron-right" class="size-3 shrink-0" />
        <.link
          patch={~p"/boards/#{@board}/wiki?#{[folder: up.id]}"}
          class="hover:text-base-content max-w-64 truncate"
          title={name.title}
        >
          {Names.pick(name, @tree_names)}
        </.link>
      </span>
      <.icon name="hero-chevron-right" class="size-3 shrink-0" />
      <% {_here, here} = List.last(@crumbs) %>
      <span class="text-base-content max-w-64 truncate" title={here.title}>
        {Names.pick(here, @tree_names)}
      </span>
    </nav>

    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h1 class="flex items-center gap-2 page-title">
          <.wiki_icon
            kind={:folder}
            icon={@folder.icon}
            color={@folder.color}
            class="size-6"
            plain="text-base-content/40"
          />
          {@folder.name}
        </h1>
        <p class="mt-1 text-sm text-base-content/60">
          {count(@total, "page")}<span :if={@children != []}>
            in {count(length(@children), "folder")}</span>. Filed at <span class="font-mono text-xs">{Wiki.folder_path(@folder)}</span>.
        </p>
        <p :if={@also_in != []} id="folder-also-in" class="mt-1 text-sm text-base-content/60">
          <.icon name="hero-link" class="size-3.5 text-base-content/40" /> Also filed in
          <span :for={{place, i} <- Enum.with_index(@also_in)}>
            <span :if={i > 0}>, </span>
            <.link
              patch={~p"/boards/#{place.board_id}/wiki?#{[folder: place.id]}"}
              class="link link-hover font-mono text-xs"
            >
              {if place.board_id != @board.id,
                do: "#{place.board.name} / #{Wiki.folder_path(place)}",
                else: Wiki.folder_path(place)}
            </.link>
          </span>
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
                <.icon name="hero-pencil" class="size-4" /> Edit folder…
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

    <.vault_recent :if={@recent} recent={@recent} excerpts={@excerpts} in_folder />

    <section :if={is_nil(@recent) and @children != []} class="mt-8">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">Folders</h2>
      <ul class="mt-3 grid gap-2 sm:grid-cols-2">
        <li :for={sub <- @children}>
          <.link
            patch={~p"/boards/#{sub.board_id}/wiki?#{[folder: sub.id]}"}
            class="flex items-center gap-2 rounded-xl border border-base-300 bg-base-100 p-3 text-sm hover:border-primary"
          >
            <.wiki_icon kind={:folder} icon={sub[:icon]} color={sub[:color]} />
            <span class="min-w-0 flex-1 truncate font-medium" title={sub[:full] || sub.title}>
              {sub.title}
            </span>
            <span
              :if={sub[:also]}
              class="inline-flex shrink-0"
              title="Also filed here; its home is another folder"
            >
              <.icon name="hero-link" class="size-3 text-base-content/40" />
            </span>
            <span class="shrink-0 text-xs text-base-content/40">
              {count(sub.pages, "page")}
            </span>
          </.link>
        </li>
      </ul>
    </section>

    <section :if={is_nil(@recent)} class="mt-8">
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
            <.wiki_icon
              :if={dressed?(page)}
              kind={:page}
              icon={page[:icon]}
              color={page[:color]}
              class="size-4 self-center"
            />
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
  attr :vault, :any, default: nil, doc: "the vault, in the vault view (#1211)"
  attr :vault_dir, :string, default: nil
  attr :excerpts, :map, default: %{}
  attr :wanted, :list, default: []
  attr :can_write, :boolean, required: true

  # In the vault view the tree beside it is the filing, so the page is the
  # notes changed most lately: the whole vault's at its top, else those
  # under the board or folder here.
  def index_body(%{vault: %{}} = assigns) do
    ~H"""
    <h1 class="page-title">
      {if @vault_dir in ["", nil],
        do: "Wiki",
        else: @vault_dir |> String.trim("/") |> Path.basename()}
    </h1>
    <p class="mt-2 text-sm text-base-content/60">
      {if @vault_dir in ["", nil],
        do: "The notes changed most lately, across every folder.",
        else: "The notes changed most lately in this folder and the ones inside it."}
    </p>
    <.vault_recent recent={@recent} excerpts={@excerpts} />
    """
  end

  def index_body(assigns) do
    ~H"""
    <h1 class="page-title">{@board.name} wiki</h1>
    <p class="mt-2 text-sm text-base-content/60">
      What the board can't say: how it works, what was decided and why.
    </p>

    <.empty_state
      :if={@empty}
      id="wiki-empty"
      icon="hero-book-open"
      title="No pages yet"
      class="mt-10"
    >
      Start with how something works, or why it was decided.
      <:action :if={@can_write}>
        <.link patch={~p"/boards/#{@board}/wiki/new"} class="btn btn-primary btn-sm">
          Write the first one
        </.link>
      </:action>
    </.empty_state>

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
              <.wiki_icon
                kind={:folder}
                icon={node.folder[:icon]}
                color={node.folder[:color]}
                class="size-4 self-center"
              />
              <span
                class="min-w-0 flex-1 truncate font-medium"
                title={node.folder[:full] || node.folder.title}
              >
                {node.folder.title}
              </span>
              <span class="shrink-0 text-xs text-base-content/40">
                {count(node.folder.pages, "page")}
              </span>
            </.link>
            <ul class="mt-2 space-y-0.5 text-sm">
              <li :for={sub <- node.children}>
                <.link
                  patch={~p"/boards/#{@board}/wiki?#{[folder: sub.id]}"}
                  class="flex min-w-0 items-center gap-1.5 text-base-content/60 hover:text-base-content"
                  title={sub[:full] || sub.title}
                >
                  <.wiki_icon
                    kind={:folder}
                    icon={sub[:icon]}
                    color={sub[:color]}
                    class="size-3"
                    plain=""
                  /> <span class="min-w-0 truncate">{sub.title}</span>
                </.link>
              </li>
              <li :for={page <- node.pages}>
                <.link
                  patch={~p"/boards/#{@board}/wiki/#{page.slug}"}
                  class="link link-hover inline-flex items-center gap-1.5"
                >
                  <.wiki_icon
                    :if={dressed?(page)}
                    kind={:page}
                    icon={page[:icon]}
                    color={page[:color]}
                    class="size-3"
                  />
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
            patch={page.href}
            class="flex items-baseline gap-3 px-4 py-3 hover:bg-base-200"
          >
            <.wiki_icon
              :if={dressed?(page)}
              kind={:page}
              icon={page[:icon]}
              color={page[:color]}
              class="size-4 self-center"
            />
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
end
