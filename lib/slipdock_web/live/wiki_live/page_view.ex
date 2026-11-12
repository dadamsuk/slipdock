defmodule SlipdockWeb.WikiLive.PageView do
  @moduledoc """
  A wiki page as it is read (`WikiLive.Index`): its action row, details,
  body, the cards it is about and the page tools' toggle.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.ItemComponents
  import SlipdockWeb.FolderPicker

  import SlipdockWeb.SlipdockComponents,
    only: [favourite_toggle: 1]

  import SlipdockWeb.WikiLive.Format
  alias Slipdock.Wiki
  alias Slipdock.Vaults.Names
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.Wiki.Renderer

  attr :board, :any, required: true
  attr :page, :any, default: nil
  attr :html, :string, default: ""
  attr :recording, :any, default: nil
  attr :recording_help, :map, default: %{settings_url: nil, owner: nil}
  attr :backlinks, :list, default: []
  attr :children, :list, default: []
  attr :cards, :list, default: []
  attr :card_query, :string, default: ""
  attr :card_results, :list, default: []
  attr :outline, :list, default: []
  attr :tags, :list, default: []
  attr :columns, :list, default: []
  attr :can_write, :boolean, required: true
  attr :can_comment, :boolean, default: false, doc: "may join the page's discussion (#863)"
  attr :can_manage, :boolean, default: false
  attr :fields_board, :any, default: nil
  attr :current_user, :any, default: nil
  attr :form_key, :integer, default: 0
  attr :shares, :integer, default: 0
  attr :marks, :any, default: nil, doc: "the reader's favourites, for the page's heart"
  attr :page_tools, :any, default: nil, doc: "the AI tools button: its pressed state, or nil"

  # Not a hole: @html is MDEx output, sanitised (ammonia), with the CSP behind it.
  # sobelow_skip ["XSS.Raw"]
  def page_body(assigns) do
    ~H"""
    <div :if={is_nil(@page)} class="py-16 text-center">
      <p class="text-base-content/60">That page doesn't exist.</p>
      <.link patch={wiki_path(@board)} class="btn btn-sm mt-4">Back to the wiki</.link>
    </div>

    <article :if={@page}>
      <.page_actions
        board={@board}
        can_manage={@can_manage}
        can_write={@can_write}
        children={@children}
        current_user={@current_user}
        marks={@marks}
        page={@page}
        page_tools={@page_tools}
      />

      <.page_details
        board={@board}
        can_write={@can_write}
        columns={@columns}
        outline={@outline}
        page={@page}
        shares={@shares}
      />

      <%!-- Two breadcrumbs, because a page sits on two axes: where it is
            filed, and what it is part of (see `Slipdock.Wiki.Folder`). --%>
      <nav
        :if={not is_nil(@page.folder_id) or Wiki.ancestors(@page) != []}
        class="mb-2 flex flex-wrap items-center gap-1 text-sm text-base-content/50"
      >
        <span
          :for={{_folder, name} <- crumbs(folder_crumbs(@page))}
          class="flex min-w-0 items-center gap-1"
        >
          <.icon name="hero-folder" class="size-3 shrink-0" />
          <span class="max-w-64 truncate" title={"Filed here: #{name.title}"}>
            {Names.pick(name, (@current_user && @current_user.tree_names) || "full")}
          </span>
          <.icon name="hero-chevron-right" class="size-3 shrink-0" />
        </span>
        <span :for={ancestor <- Wiki.ancestors(@page)} class="flex items-center gap-1">
          <.link patch={page_path(@board, ancestor)} class="hover:text-base-content">
            {ancestor.title}
          </.link>
          <.icon name="hero-chevron-right" class="size-3" />
        </span>
      </nav>

      <div class="min-w-0">
        <h1 class="flex items-center gap-2 page-title">
          <.wiki_icon
            :if={dressed?(Map.from_struct(@page))}
            kind={:page}
            icon={@page.icon}
            color={@page.color}
            class="size-6"
          />
          {@page.title}
        </h1>
        <p :if={@page.summary} class="mt-1 text-base-content/60">{@page.summary}</p>
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
          class="btn btn-ghost btn-error btn-xs"
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

      <%!-- The player for a transcript and, on a meeting page, its recording
            (W-1690): it finds both in the body and draws its bar there. One
            per page, so moving to another page starts a fresh one. --%>
      <div
        id={"wiki-player-#{@page.id}"}
        phx-hook="TranscriptPlayer"
        data-recording-src={@recording && ~p"/wiki-pages/#{@page.id}/recording"}
        data-recording-problem={recording_problem(@recording)}
        data-settings-url={@recording_help.settings_url}
        data-vault-owner={@recording_help.owner}
        data-can-name-speakers={@can_write && "true"}
      >
        <div
          id="wiki-body"
          phx-hook="WikiSelection"
          data-button="selection-to-card"
          class="wiki-prose mt-6"
        >
          {Phoenix.HTML.raw(@html)}
        </div>
      </div>

      <.page_cards
        can_write={@can_write}
        card_query={@card_query}
        card_results={@card_results}
        cards={@cards}
      />

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

      <.page_card_features
        board={@board}
        can_comment={@can_comment}
        can_write={@can_write}
        current_user={@current_user}
        fields_board={@fields_board}
        form_key={@form_key}
        page={@page}
      />

      <footer class="mt-10 border-t border-base-300 pt-4 text-xs text-base-content/50">
        Last edited {stamp(@page.updated_at)}
        <.link patch={~p"/boards/#{@board}/wiki/#{@page.slug}/history"} class="link">
          see history
        </.link>
      </footer>
    </article>
    """
  end

  # Nil where the tools have nothing to work on, or no model to ask: a page
  # that isn't there, a drawing, or a screen that isn't one page's text.
  def page_tools_button(%{page_tools_ai: false}), do: nil

  def page_tools_button(%{live_action: :new, form: %{}} = assigns), do: assigns.page_tools

  def page_tools_button(%{live_action: action, page: %Page{} = page} = assigns)
      when action in [:show, :edit] do
    if Slipdock.Wiki.Excalidraw.page?(page), do: nil, else: assigns.page_tools
  end

  def page_tools_button(_assigns), do: nil

  # When editing, what is in the editor; when reading, what is saved.
  def page_tools_source(%{live_action: action, form: form}) when action in [:new, :edit] do
    %{title: form[:title].value, text: to_string(form[:body].value)}
  end

  def page_tools_source(%{page: page}), do: %{title: page.title, text: page.body}

  attr :pressed, :any, required: true

  def page_tools_toggle(assigns) do
    ~H"""
    <button
      :if={not is_nil(@pressed)}
      type="button"
      id="page-tools-toggle"
      phx-click="toggle_page_tools"
      aria-pressed={to_string(@pressed)}
      title="AI tools: summarise, extract actions and more"
      class={["btn btn-ghost btn-sm gap-1.5", @pressed && "btn-active"]}
    >
      <.icon name="hero-sparkles" class="size-4" />
      <span class="hidden sm:inline">AI tools</span>
    </button>
    """
  end

  attr :board, :any, required: true
  attr :can_manage, :any, required: true
  attr :can_write, :any, required: true
  attr :children, :any, required: true
  attr :current_user, :any, required: true
  attr :marks, :any, required: true
  attr :page, :any, required: true
  attr :page_tools, :any, required: true

  # The page's action row (#1663): the heart, its code, the tools, Edit,
  # History, the page menu, and the button that opens its details.
  def page_actions(assigns) do
    ~H"""
    <%!-- What you can do with the page comes first, above where it is
          filed (#1663): the heart, its code, the tools, Edit, History,
          the page menu, and the button that opens its details. --%>
    <div id="page-actions" class="mb-3 flex flex-wrap items-center gap-1">
      <%!-- Anyone who can read the page may favourite it: it is their
            own shortcut on /favourites, not a change to the page. --%>
      <.favourite_toggle
        :if={@current_user}
        id={@page.id}
        kind="page"
        name={@page.title}
        marks={@marks}
        class="btn btn-ghost btn-sm btn-square"
      />
      <%!-- The page code is for the CLI and `[[links]]`, so it is a
            ghost button, not a chip (#1743): its tooltip shows it, and a
            click copies it (the CopyText hook reads the span inside). --%>
      <button
        id="page-code-copy"
        type="button"
        phx-hook="CopyText"
        data-target={"page-code-#{@page.id}"}
        data-tip={"#{@page.code} · click to copy"}
        aria-label={"Copy the page code, #{@page.code}"}
        class="btn btn-ghost btn-sm btn-square tooltip tooltip-bottom"
      >
        <.icon name="hero-hashtag" class="size-4" />
        <span id={"page-code-#{@page.id}"} class="sr-only">{@page.code}</span>
      </button>
      <%!-- One button style in this row (#1743): every action is a ghost
            button, and the one emphasised (secondary) action is Edit, or
            on a drawing, editing the drawing. A drawing opens in the
            Excalidraw editor (W-103 R5.2); its Markdown is still there
            under Edit Markdown, for the rare fix by hand. --%>
      <.link
        :if={Slipdock.Wiki.Excalidraw.page?(@page)}
        id="open-drawing"
        navigate={~p"/drawings/page/#{@page.id}"}
        class="btn btn-secondary btn-sm gap-1.5"
      >
        <.icon name="hero-paint-brush" class="size-4" />
        {if @can_write, do: "Edit drawing", else: "Open drawing"}
      </.link>
      <.page_tools_toggle pressed={@page_tools} />
      <.link
        :if={@can_write}
        id="edit-page"
        patch={~p"/boards/#{@board}/wiki/#{@page.slug}/edit"}
        class={[
          "btn btn-sm gap-1.5",
          if(Slipdock.Wiki.Excalidraw.page?(@page), do: "btn-ghost", else: "btn-secondary")
        ]}
      >
        <.icon name="hero-pencil-square" class="size-4" />
        {if Slipdock.Wiki.Excalidraw.page?(@page), do: "Edit Markdown", else: "Edit"}
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
            <button
              id="share-page"
              type="button"
              phx-click="share_item"
              phx-value-kind="page"
              phx-value-id={@page.id}
            >
              <.icon name="hero-user-plus" class="size-4" /> Share…
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
      <%!-- Everything about the page rather than in it (where it is
            filed, where it sits on the board, its public link, facets,
            tags and front matter) waits behind this button so the prose
            comes first (#761). The panel opens just beneath this row.
            Closed on every page: both ids carry the page's, so moving to
            another page starts it closed again, while the toggle (a JS
            command, so it survives patches) keeps it open across this
            page's own updates (filing it, placing it). --%>
      <button
        id={"page-details-toggle-#{@page.id}"}
        type="button"
        class="group btn btn-ghost btn-sm gap-1.5"
        aria-expanded="false"
        aria-controls={"page-details-#{@page.id}"}
        phx-click={
          JS.toggle_attribute({"hidden", "hidden"}, to: "#page-details-#{@page.id}")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
      >
        <.icon
          name="hero-chevron-right"
          class="size-4 transition-transform group-aria-expanded:rotate-90"
        /> Page details
      </button>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :can_write, :any, required: true
  attr :columns, :any, required: true
  attr :outline, :any, required: true
  attr :page, :any, required: true
  attr :shares, :any, required: true

  # The page's details, folded away until asked for (#1663): when it was
  # written, who it is shared with, where it is filed, its place on the board,
  # publishing, its facets, its own tags and its front matter.
  def page_details(assigns) do
    ~H"""
    <div
      id={"page-details-#{@page.id}"}
      data-role="page-details"
      hidden
      class="mb-4 rounded-xl border border-base-300 bg-base-100/60 px-4 pb-4"
    >
      <%!-- When it was written and last changed. Kept by Slipdock, not in
            the page's front matter, so a synced file is never rewritten
            just to move a timestamp (#790). --%>
      <div
        id="page-stamps"
        class="mt-4 flex flex-wrap items-center gap-2 text-sm text-base-content/60"
      >
        <.icon name="hero-clock" class="size-4 shrink-0" />
        <span>
          Created <time datetime={iso(@page.inserted_at)}>{stamp(@page.inserted_at)}</time>
        </span>
        <span aria-hidden="true">·</span>
        <span>
          Updated <time datetime={iso(@page.updated_at)}>{stamp(@page.updated_at)}</time>
        </span>
      </div>
      <%!-- Who else it is shared with (#813): a page shared on its own
            is easy to forget about otherwise. --%>
      <div
        :if={@shares > 0}
        id="page-shared"
        class="mt-4 flex flex-wrap items-center gap-2 text-sm text-base-content/60"
      >
        <.icon name="hero-users" class="size-4 shrink-0" />
        <span>
          Shared with {@shares} {if @shares == 1, do: "person or group", else: "people or groups"}.
        </span>
        <button
          :if={@can_write}
          type="button"
          class="link"
          phx-click="share_item"
          phx-value-kind="page"
          phx-value-id={@page.id}
        >
          Manage
        </button>
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
        phx-mounted={JS.ignore_attributes("open")}
        class="mt-4 rounded-xl border border-base-300 bg-base-200/40 px-4 py-2 text-sm"
      >
        <summary class="cursor-pointer select-none section-label">
          Properties
        </summary>
        <pre class="mt-2 overflow-x-auto whitespace-pre-wrap font-mono text-xs text-base-content/80">{Slipdock.Wiki.FrontMatter.yaml(@page.front_matter)}</pre>
      </details>
    </div>
    """
  end

  attr :can_write, :any, required: true
  attr :card_query, :any, required: true
  attr :card_results, :any, required: true
  attr :cards, :any, required: true

  # The cards the page is about, and attaching another.
  def page_cards(assigns) do
    ~H"""
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
        <.search_input
          value={@card_query}
          placeholder="Attach a card…"
          phx-debounce="200"
          autocomplete="off"
          class="w-full"
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
    """
  end

  attr :board, :any, required: true
  attr :can_comment, :any, required: true
  attr :can_write, :any, required: true
  attr :current_user, :any, required: true
  attr :fields_board, :any, required: true
  attr :form_key, :any, required: true
  attr :page, :any, required: true

  # The card contents a page carries, when its board has them on.
  def page_card_features(assigns) do
    ~H"""
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
          <.status_section
            item={@page}
            can_write={@can_write}
            can_comment={@can_comment}
            form_key={@form_key}
          />
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
            can_comment={@can_comment}
          />
        </div>
      </div>

      <.comments_section
        item={@page}
        board={@board}
        current_user={@current_user}
        can_write={@can_write}
        can_comment={@can_comment}
        form_key={@form_key}
      />
    </section>
    """
  end
end
