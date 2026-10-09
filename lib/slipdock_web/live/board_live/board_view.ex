defmodule SlipdockWeb.BoardLive.BoardView do
  @moduledoc """
  The board LiveView's own markup: the board's header row (breadcrumb and actions), the
  board view itself (its lists, their cards, adding to them), its toolbar,
  and the strip that says where the keyboard is. The other views have
  components of their own; the panels over them are LiveComponents.

  Everything here is drawn from assigns the LiveView passes in; the events
  it sends are the LiveView's (the buttons that open a panel target it).
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.SwimlaneComponents
  import SlipdockWeb.BoardLive.Helpers, only: [tag_by_id: 2]

  alias Slipdock.{ListOrder, Palette}
  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Swimlanes.Config

  attr :board, :any, required: true
  attr :ancestry, :list, required: true
  attr :paths, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :can_write, :boolean, required: true

  @doc "The header's breadcrumb: the boards above this one, and this one."
  def board_nav(assigns) do
    ~H"""
    <nav class="flex min-w-0 items-center gap-1 text-sm">
      <%!-- On one row the mark beside this already goes to the boards. --%>
      <.link
        navigate={~p"/"}
        class="hidden shrink-0 text-base-content/50 hover:text-base-content sm:inline lg:hidden"
      >
        Boards
      </.link>
      <.icon
        name="hero-chevron-right"
        class="hidden size-3 shrink-0 text-base-content/40 sm:inline lg:hidden"
      />
      <%!-- Only the boards above: each card between them is the board after
            it under the same name, and the last is this one. --%>
      <span
        :for={%{board: b} <- @ancestry}
        class="hidden min-w-0 items-center gap-1 text-base-content/50 lg:flex"
      >
        <.link
          navigate={~p"/boards/#{b}"}
          class="max-w-40 truncate hover:text-base-content"
          title={b.name}
        >
          {b.name}
        </.link>
        <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
      </span>
      <.link
        :if={@can_manage}
        patch={@paths.settings}
        class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
        title={@board.description || "Board settings"}
      >
        <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
        <span class="truncate font-semibold">{@board.name}</span>
        <span
          :if={@board.code && is_nil(@board.parent_card_id)}
          class="chip chip-line hidden shrink-0 font-mono text-2xs sm:inline-flex"
          title="Board code"
        >
          {@board.code}
        </span>
      </.link>
      <div
        :if={!@can_manage}
        class="flex min-w-0 items-center gap-2 px-2 py-1"
        title={"Shared with you (#{if @can_write, do: "can edit", else: "read only"})"}
      >
        <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
        <span class="truncate font-semibold">{@board.name}</span>
        <span
          :if={@board.code && is_nil(@board.parent_card_id)}
          class="chip chip-line hidden shrink-0 font-mono text-2xs sm:inline-flex"
          title="Board code"
        >
          {@board.code}
        </span>
        <span class="badge badge-ghost badge-xs">{if @can_write, do: "shared", else: "read only"}</span>
      </div>
      <span
        :if={not is_nil(@board.archived_at)}
        class="badge badge-warning badge-xs shrink-0"
        title="This board is archived: it is off the board index and the switcher, but nothing on it is lost."
      >
        archived
      </span>
      <.link
        :for={%{board: pb, card: pc} <- Enum.take(@ancestry, -1)}
        navigate={~p"/boards/#{pb}/cards/#{pc.id}"}
        class="btn btn-ghost btn-xs shrink-0 gap-1"
        title={"Open the parent card: #{pc.title} (on #{pb.name})"}
      >
        <.icon name="hero-arrow-uturn-left" class="size-3.5" />
        <span class="hidden sm:inline">Parent card</span>
      </.link>
      <.link
        :for={%{board: pb} <- Enum.take(@ancestry, -1)}
        navigate={~p"/boards/#{pb}"}
        class="btn btn-ghost btn-xs shrink-0 gap-1"
        title={"Open the board that holds the parent card: #{pb.name}"}
      >
        <.icon name="hero-squares-2x2" class="size-3.5" />
        <span class="hidden sm:inline">Parent board</span>
      </.link>
    </nav>
    """
  end

  attr :board, :any, required: true
  attr :paths, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :can_write, :boolean, required: true
  attr :card_only, :boolean, required: true
  attr :view_only, :boolean, required: true
  attr :sprint_of, :any, required: true
  attr :ai?, :boolean, required: true
  attr :rules, :list, required: true

  attr :meetings_path, :string,
    default: nil,
    doc: "where the menu's Capture a meeting goes, if anywhere"

  @doc "The board's header buttons: sprints, the chat and the board's menu, sharing among it."
  def board_actions(assigns) do
    ~H"""
    <button
      :if={@can_write and !@card_only and Board.sprints?(@board)}
      id="new-sprint"
      type="button"
      class="btn btn-primary btn-sm gap-1.5"
      phx-click="open_new_sprint"
      phx-target="#board-sprints"
      title="Start the next sprint: a dated card with a board of its own"
    >
      <.icon name="hero-rocket-launch" class="size-4" />
      <span class="hidden sm:inline">New sprint</span>
    </button>
    <button
      :if={!@card_only and (Board.sprints?(@board) or @sprint_of)}
      id="sprint-charts"
      type="button"
      class="btn btn-ghost btn-sm gap-1.5"
      phx-click="open_sprint_charts"
      phx-target="#board-sprints"
      title={
        if Board.sprints?(@board),
          do: "Velocity across the sprints, and a sprint's burndown",
          else: "This sprint's burndown"
      }
    >
      <.icon name="hero-chart-bar" class="size-4" />
      <span class="hidden lg:inline">Charts</span>
    </button>
    <button
      :if={@can_write and !@card_only and @sprint_of}
      id="sprint-add-cards"
      type="button"
      class="btn btn-primary btn-sm gap-1.5"
      phx-click="open_sprint_picker"
      phx-target="#board-sprints"
      phx-value-id={@sprint_of.id}
      title={"Pick cards from your boards to add to #{@sprint_of.title}"}
    >
      <.icon name="hero-queue-list" class="size-4" />
      <span class="hidden sm:inline">Add cards…</span>
    </button>
    <button
      :if={@ai? and !@card_only}
      type="button"
      id="board-chat"
      class="btn btn-ghost btn-sm btn-square hidden sm:inline-flex"
      title="Chat about this page with AI"
      aria-label="Chat about this page with AI"
      phx-click="toggle"
      phx-target="#page-ai"
    >
      <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" />
    </button>
    <%!-- On a phone this and the chat are the floating navigation's Menu
          (board_menu/1), leaving the header the room for the board's name. --%>
    <div :if={!@view_only and !@card_only} class="dropdown dropdown-end hidden sm:block">
      <div tabindex="0" role="button" class="btn btn-ghost btn-sm btn-square" title="More">
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </div>
      <ul
        tabindex="0"
        class="menu dropdown-content z-40 mt-2 w-52 rounded-box bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
      >
        <.board_menu_items
          share_id="board-share"
          paths={@paths}
          can_manage={@can_manage}
          rules={@rules}
          meetings_path={@meetings_path}
        />
      </ul>
    </div>
    """
  end

  attr :paths, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :card_only, :boolean, required: true
  attr :view_only, :boolean, required: true
  attr :ai?, :boolean, required: true
  attr :rules, :list, required: true
  attr :meetings_path, :string, default: nil

  @doc """
  The board's entries in the phone's navigation Menu: what the header's
  chat button and `…` menu hold on a wider screen, which a phone hides.
  """
  def board_menu(assigns) do
    ~H"""
    <li :if={@ai? and !@card_only}>
      <button type="button" id="board-chat-menu" phx-click="toggle" phx-target="#page-ai">
        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" /> Chat about this page with AI
      </button>
    </li>
    <.board_menu_items
      :if={!@view_only and !@card_only}
      share_id="board-share-menu"
      paths={@paths}
      can_manage={@can_manage}
      rules={@rules}
      meetings_path={@meetings_path}
    />
    """
  end

  attr :share_id, :string, required: true
  attr :paths, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :rules, :list, required: true
  attr :meetings_path, :string, default: nil

  # The board's own menu, wherever it is drawn: the header's `…` or the
  # phone's Menu, each with its own id on the share link.
  defp board_menu_items(assigns) do
    ~H"""
    <li :if={@can_manage}>
      <.link id={@share_id} patch={@paths.settings}>
        <.icon name="hero-user-plus" class="size-4" /> Share this board
      </.link>
    </li>
    <li>
      <.link patch={@paths.tags}><.icon name="hero-tag" class="size-4" /> Tags</.link>
    </li>
    <li>
      <.link patch={@paths.activity}><.icon name="hero-bolt" class="size-4" /> Activity</.link>
    </li>
    <li>
      <.link patch={@paths.archive}>
        <.icon name="hero-archive-box" class="size-4" /> Archived cards
      </.link>
    </li>
    <li :if={@can_manage}>
      <.link patch={@paths.automations}>
        <.icon name="hero-cpu-chip" class="size-4" /> Automations
        <span :if={@rules != []} class="badge badge-ghost badge-xs">{length(@rules)}</span>
      </.link>
    </li>
    <li :if={@can_manage}>
      <.link patch={@paths.settings}>
        <.icon name="hero-cog-6-tooth" class="size-4" /> Board settings
      </.link>
    </li>
    <%!-- Meeting mode on, but this board has had no capture yet: one way in,
          rather than a tab with nothing behind it (see `Slipdock.Meetings`). --%>
    <li :if={@meetings_path}>
      <.link navigate={@meetings_path} id={@share_id <> "-capture-meeting"}>
        <.icon name="hero-microphone" class="size-4" /> Capture a meeting
      </.link>
    </li>
    """
  end

  attr :board, :any, required: true
  attr :columns, :list, required: true
  attr :filters, :map, required: true
  attr :filtering, :boolean, required: true
  attr :page_hit, :any, default: nil, doc: "the wiki page whose code is in the search box"
  attr :swim, Config, required: true
  attr :swim_view, :any, required: true
  attr :swim_dirty, :boolean, required: true
  attr :form_key, :integer, required: true
  attr :can_write, :boolean, required: true
  attr :can_manage, :boolean, required: true
  attr :view_only, :boolean, required: true
  attr :view_grants, :list, required: true
  attr :groups, :list, required: true
  attr :share_key, :integer, required: true
  attr :favourites, :any, required: true
  attr :narrow?, :boolean, required: true
  attr :meetings, :atom, default: :none, doc: "`Slipdock.Meetings.presence/2` for this board"
  attr :renaming_column, :any, required: true
  attr :focus, :any, required: true
  attr :adding_to, :any, required: true
  attr :adding_column, :boolean, required: true
  attr :uploads, :map, required: true

  @doc "The board view: its toolbar, then the lists side by side."
  def kanban(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <.board_toolbar
        board={@board}
        meetings={@meetings}
        filters={@filters}
        filtering={@filtering}
        columns={@columns}
        config={@swim}
        view={@swim_view}
        dirty={@swim_dirty}
        form_key={@form_key}
        can_write={@can_write}
        can_manage={@can_manage}
        view_only={@view_only}
        view_grants={@view_grants}
        groups={@groups}
        share_key={@share_key}
        marks={@favourites}
      />
      <div
        :if={@filtering}
        class="flex flex-wrap items-center gap-2 border-b border-base-300 bg-base-100/60 px-4 py-2 text-sm"
      >
        <span class="text-base-content/60">Showing cards matching:</span>
        <span :if={@filters.q != ""} class="badge badge-outline gap-1">
          “{@filters.q}”
        </span>
        <.link
          :if={@page_hit}
          id="search-page-hit"
          navigate={~p"/boards/#{@page_hit.board_id}/wiki/#{@page_hit.slug}"}
          class="badge badge-primary badge-outline gap-1 hover:bg-primary/10"
        >
          <.icon name="hero-document-text" class="size-3.5" />
          <span class="font-mono">{@page_hit.code}</span> {@page_hit.title}
          <span :if={@page_hit.board_id != @board.id} class="text-base-content/50">
            · {@page_hit.board.name}
          </span>
        </.link>
        <span :for={kind <- @filters.kinds} class="badge badge-outline">
          {Slipdock.Kinds.label(kind)} only
        </span>
        <span :for={id <- @filters.tags} :if={tag_by_id(@board, id)}>
          <.tag_chip tag={tag_by_id(@board, id)} />
        </span>
        <span :if={@filters.priority} class="badge badge-outline">{priority_label(@filters.priority)} priority</span>
        <span :if={@filters.flag} class="badge badge-outline">{flag_label(@filters.flag)}</span>
        <span :if={@filters.due} class="badge badge-outline">
          {%{"overdue" => "Overdue", "week" => "Due in 7 days", "none" => "No due date"}[
            @filters.due
          ]}
        </span>
        <span :if={@filters.hide_completed} class="badge badge-outline">Completed hidden</span>
        <button class="btn btn-ghost btn-xs" phx-click="clear_filters">
          <.icon name="hero-x-mark" class="size-3.5" /> Clear
        </button>
      </div>

      <.list_pager :if={@narrow? and @columns != []} columns={@columns} />

      <div
        id="board-scroll"
        phx-hook="ScrollEnd"
        class={[
          "kanban-scroll min-h-0 flex-1 overflow-x-auto overflow-y-hidden",
          @narrow? && "snap-x snap-mandatory"
        ]}
      >
        <div
          id="columns"
          phx-hook="Sortable"
          data-group="columns"
          data-draggable=".kanban-column"
          data-handle=".column-handle"
          data-event="move_column"
          data-disabled={to_string(!@can_write)}
          class={["flex h-full items-start", if(@narrow?, do: "gap-0", else: "gap-4 p-4")]}
        >
          <%!-- On a phone one list fills the screen, so it is the page: no
                margin round it, no well behind it, and the cards sit straight
                on the background, edge to edge bar a little breathing room. --%>
          <div
            :for={%{column: column, cards: cards, groups: groups, hidden: hidden} <- @columns}
            id={"column-#{column.id}"}
            data-id={column.id}
            class={[
              "kanban-column flex max-h-full shrink-0 flex-col",
              if(@narrow?,
                do: "w-screen snap-start snap-always",
                else: [list_width(@swim), "rounded-2xl bg-base-300/60 shadow-inner"]
              ),
              @focus && @focus.column_id == column.id && "ring-2 ring-secondary/50"
            ]}
          >
            <div class="column-handle flex cursor-grab items-center gap-2 px-3 pb-1 pt-3 active:cursor-grabbing">
              <span
                :if={column.color}
                class={["size-2.5 shrink-0 rounded-full", Palette.dot(column.color)]}
              ></span>
              <form
                :if={@renaming_column == column.id}
                phx-submit="rename_column"
                class="flex-1"
              >
                <input type="hidden" name="column_id" value={column.id} />
                <input
                  type="text"
                  name="name"
                  value={column.name}
                  class="input input-sm w-full font-semibold"
                  phx-hook="Focus"
                  data-select
                  phx-blur="cancel_rename_column"
                  phx-window-keydown="cancel_rename_column"
                  phx-key="Escape"
                  id={"rename-#{column.id}"}
                />
              </form>
              <h2
                :if={@renaming_column != column.id}
                class={[
                  "min-w-0 flex-1 truncate rounded px-1 text-sm font-semibold",
                  @can_write && "cursor-text hover:bg-base-100/60"
                ]}
                phx-click={@can_write && "start_rename_column"}
                phx-value-id={column.id}
                title={@can_write && "Click to rename"}
              >
                {column.name}
              </h2>
              <span
                :if={Column.horizon?(column)}
                class="chip chip-line max-w-28 shrink-0 truncate text-2xs"
                title={"This list stands for #{Column.horizon_label(column)}"}
              >
                {Column.horizon_label(column)}
              </span>
              <% drifted = Enum.count(cards, &Column.drifted?(column, Card.effective_due(&1))) %>
              <span
                :if={drifted > 0}
                class="chip bg-amber-500/15 text-2xs text-amber-700 dark:text-amber-300"
                title={"#{drifted} #{if drifted == 1, do: "card is", else: "cards are"} due outside this horizon"}
              >
                <.icon name="hero-arrow-uturn-right" class="size-3" /> {drifted}
              </span>
              <span
                :if={ListOrder.label(column)}
                class="shrink-0 text-base-content/50"
                title={"Cards drawn #{ListOrder.label(column)} — set in List settings"}
              >
                <.icon name="hero-bars-arrow-down" class="size-3.5" />
              </span>
              <%!-- Stand-ins are not work in this list, so they are not
                    counted against its limit. --%>
              <% count = Enum.count(column.cards, &(not Card.stand_in?(&1))) %>
              <span
                class={[
                  "badge badge-sm font-mono",
                  cond do
                    column.wip_limit && count > column.wip_limit -> "badge-error"
                    column.wip_limit && count == column.wip_limit -> "badge-warning"
                    true -> "badge-ghost"
                  end
                ]}
                title={
                  if column.wip_limit,
                    do: "WIP limit #{column.wip_limit}",
                    else: "#{count} cards"
                }
              >
                {if column.wip_limit,
                  do: "#{count}/#{column.wip_limit}",
                  else: count}
              </span>
              <.favourite_toggle
                kind="column"
                id={column.id}
                name={column.name}
                marks={@favourites}
                class="p-0.5"
                size="size-3.5"
              />
              <div :if={@can_write} class="dropdown dropdown-end">
                <div
                  tabindex="0"
                  role="button"
                  class="btn btn-ghost btn-xs btn-square"
                  title="List actions"
                >
                  <.icon name="hero-ellipsis-horizontal" class="size-4" />
                </div>
                <ul
                  tabindex="0"
                  class="menu dropdown-content z-30 w-48 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
                >
                  <li>
                    <button phx-click="start_add_card" phx-value-id={column.id}>
                      <.icon name="hero-plus" class="size-4" /> Add card
                    </button>
                  </li>
                  <li>
                    <button
                      phx-click="edit_column"
                      phx-target="#board-column"
                      phx-value-id={column.id}
                    >
                      <.icon name="hero-cog-6-tooth" class="size-4" /> List settings
                    </button>
                  </li>
                  <li>
                    <button
                      class="text-error"
                      phx-click="delete_column"
                      phx-target="#board-column"
                      phx-value-id={column.id}
                      data-confirm={"Delete “#{column.name}” and its #{length(column.cards)} cards?"}
                    >
                      <.icon name="hero-trash" class="size-4" /> Delete list
                    </button>
                  </li>
                </ul>
              </div>
            </div>

            <div
              id={"cards-#{column.id}"}
              data-id={column.id}
              phx-hook="Sortable"
              data-group="cards"
              data-event="move_card"
              data-disabled={to_string(!@can_write)}
              data-draggable=".kanban-card"
              data-sort={to_string(!ListOrder.sorted?(column))}
              class={[
                "kanban-scroll min-h-[2.5rem] flex-1 space-y-2 overflow-y-auto py-1",
                if(@narrow?, do: "px-3", else: "px-2")
              ]}
            >
              <%!-- Cards and placed wiki pages are drawn by the same
                    component: a page carries the card's facets, and the one
                    thing it does differently is the document icon. A list
                    with an order of its own draws them in it, under group
                    headings when it has those; dragging within it then has
                    nothing to rearrange, so only moves between lists. --%>
              <%= for group <- groups do %>
                <h3
                  :if={group.label}
                  class={[
                    "list-group flex items-center gap-1.5 px-1 pt-1 text-2xs font-semibold uppercase tracking-wide",
                    if(group.tone == :past, do: "text-error/80", else: "text-base-content/50")
                  ]}
                >
                  <span :if={group.color} class={["size-2 rounded-full", Palette.dot(group.color)]}></span>
                  {group.label}
                  <span class="font-mono font-normal">{length(group.items)}</span>
                </h3>
                <.card
                  :for={{_kind, item} <- group.items}
                  card={item}
                  compact={@swim.density == "compact"}
                  show={Config.shown(@swim)}
                  focus={@focus && card_focus(@focus, item)}
                  dismiss={@can_write}
                >
                  <:actions :if={@can_write and length(@board.columns) > 1}>
                    <.move_menu card={item} board={@board} />
                  </:actions>
                </.card>
              <% end %>
              <p :if={hidden > 0} class="px-1 py-1 text-center text-2xs text-base-content/60">
                {hidden} hidden by filters
              </p>
            </div>

            <div :if={@can_write} class="p-2">
              <form
                :if={@adding_to == column.id}
                id={"quick-add-#{column.id}-#{@form_key}"}
                phx-submit="quick_add_card"
                class="kanban-pop space-y-2"
              >
                <input type="hidden" name="column_id" value={column.id} />
                <input
                  type="text"
                  name="title"
                  placeholder="Card title; a comment, then Enter"
                  class="input input-sm w-full"
                  phx-hook="Focus"
                  id={"quick-add-input-#{column.id}-#{@form_key}"}
                  phx-window-keydown="cancel_add_card"
                  phx-key="Escape"
                  autocomplete="off"
                  required
                />
                <div class="flex items-center gap-1">
                  <button type="submit" class="btn btn-primary btn-sm">Add card</button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm btn-square"
                    phx-click="cancel_add_card"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
              </form>
              <%!-- The three are shortcuts to the same thing: something new
                    at the foot of this list. One row of icons rather than
                    three rows of words — a list is narrow, and what is in
                    it matters more than how to add to it. Each can be
                    turned off in the board's settings. --%>
              <div :if={@adding_to != column.id} class="flex items-center gap-0.5">
                <button
                  :if={@board.add_card}
                  type="button"
                  class="btn btn-ghost btn-sm gap-1.5 px-2 text-base-content/50 hover:text-base-content"
                  phx-click="start_add_card"
                  phx-value-id={column.id}
                  title="Add a card"
                  aria-label={"Add a card to #{column.name}"}
                >
                  <.icon name="hero-plus" class="size-4" />
                  <span class="text-xs font-normal">Add</span>
                </button>
                <%!-- Straight into the wiki's own editor, carrying the
                      list: a page is written as Markdown, not filled into a
                      card form, and it is placed here when it is saved. --%>
                <.link
                  :if={@board.add_page}
                  navigate={~p"/boards/#{@board}/wiki/new?#{[column: column.id]}"}
                  class="btn btn-ghost btn-sm btn-square text-base-content/50 hover:text-base-content"
                  title="Add a page — a wiki document, written here and placed in this list"
                  aria-label={"Add a page to #{column.name}"}
                >
                  <.icon name="hero-document-text" class="size-4" />
                </.link>
                <%!-- One hidden file input for the whole board (one per
                      list would be a duplicate id), opened from here. The
                      click is dispatched at it rather than reaching it
                      through a label's `for`: that way the same gesture
                      records which list the file belongs to, which the
                      upload that follows has no way of knowing. --%>
                <button
                  :if={@board.add_document}
                  type="button"
                  class="btn btn-ghost btn-sm btn-square text-base-content/50 hover:text-base-content"
                  title="Add a document — a file, on a card of its own"
                  aria-label={"Add a document to #{column.name}"}
                  phx-click={
                    JS.push("aim_document", value: %{id: column.id})
                    |> JS.dispatch("click", to: "##{@uploads.list_document.ref}")
                  }
                >
                  <.icon name="hero-paper-clip" class="size-4" />
                </button>
              </div>
            </div>
          </div>

          <%!-- A `live_file_input` has to sit inside a form with a change
                binding: LiveView picks the file up from the form's change
                event, so a bare input takes the file and does nothing with
                it. One form for the whole board — one per list would be a
                duplicate id — and `aim_document` says which list. --%>
          <form
            :if={@can_write and @board.add_document}
            id="list-document-form"
            phx-change="validate_document"
            phx-submit="validate_document"
          >
            <.live_file_input upload={@uploads.list_document} class="hidden" />
          </form>

          <div
            :if={@can_write}
            class={["shrink-0", if(@narrow?, do: "w-screen snap-start p-3", else: list_width(@swim))]}
          >
            <form
              :if={@adding_column}
              id={"add-column-#{@form_key}"}
              phx-submit="add_column"
              class="kanban-pop space-y-2 rounded-2xl bg-base-300/60 p-2"
            >
              <input
                type="text"
                name="name"
                placeholder="List name"
                class="input input-sm w-full"
                phx-hook="Focus"
                id="add-column-input"
                phx-window-keydown="cancel_add_column"
                phx-key="Escape"
                autocomplete="off"
                required
              />
              <div class="flex items-center gap-1">
                <button type="submit" class="btn btn-primary btn-sm">Add list</button>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm btn-square"
                  phx-click="cancel_add_column"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </form>
            <button
              :if={!@adding_column}
              type="button"
              class="btn btn-ghost w-full justify-start rounded-2xl bg-base-100/40 hover:bg-base-100/80"
              phx-click="start_add_column"
            >
              <.icon name="hero-plus" class="size-4" /> Add another list
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :focus, :map, required: true
  attr :focus_title, :string, default: nil

  @doc "Where the keyboard is on the board, and what the keys do from there."
  def focus_toast(assigns) do
    ~H"""
    <div class="kanban-toast-in pointer-events-none fixed bottom-4 left-1/2 z-50 flex max-w-[calc(100vw-2rem)] -translate-x-1/2 items-center gap-2 rounded-full bg-base-content px-4 py-2 text-xs text-base-100 shadow-xl">
      <.icon
        name={if @focus.holding?, do: "hero-arrows-pointing-out", else: "hero-cursor-arrow-rays"}
        class="size-3.5 shrink-0"
      />
      <span class="truncate font-semibold">
        {if @focus.holding?, do: "Moving", else: "On"} “{@focus_title || "an empty list"}”
      </span>
      <span :if={@focus.holding?} class="shrink-0 opacity-70">
        h l or ← → list · j k or ↑ ↓ order · Enter to drop · Esc to stop
      </span>
      <span :if={!@focus.holding?} class="shrink-0 opacity-70">
        h j k l or arrows move · Enter to open · J to pick up · c to add · Esc to stop
      </span>
    </div>
    """
  end

  # Where the keyboard is, for one card: pointing at it, carrying it, or
  # somewhere else entirely.
  # The keyboard cursor walks cards. A placed wiki page is drawn beside them
  # but is not in `col.cards`, so it is never the cursor — and must not light
  # up because it happens to share a card's number.
  defp card_focus(_focus, %Slipdock.Wiki.Page{}), do: nil

  defp card_focus(%{card_id: id, holding?: true}, %{id: id}), do: :held

  defp card_focus(%{card_id: id}, %{id: id}), do: :cursor

  defp card_focus(_focus, _card), do: nil

  # A list's width on a wide screen, from the Display menu's *List width*.
  defp list_width(%Config{width: "narrow"}), do: "w-60"
  defp list_width(%Config{width: "wide"}), do: "w-96"
  defp list_width(%Config{width: "wider"}), do: "w-[30rem]"
  defp list_width(_), do: "w-72"

  attr :card, :any, required: true
  attr :board, :any, required: true

  @doc false
  # "Move to another list", on the card itself.
  #
  # Dragging is the quick way with a mouse and the only way there was — which
  # on a phone means dragging a card across a board that shows one list at a
  # time, holding it at the screen's edge and waiting. This is two taps, and
  # on a desktop it stays out of the way until the card is hovered.
  #
  # The button carries a `phx-click` of its own so the tap stops here:
  # LiveView fires the binding on the closest element that has one, and the
  # card behind this is one big "open me". Focusing itself is that binding —
  # it does nothing, which is the point.
  #
  # The menu is a native popover, which the browser draws in its top layer:
  # an ordinary dropdown here is clipped by the list's own scrollbox, and
  # came out two rows tall. `AnchoredPopover` puts it beside the button.
  defp move_menu(assigns) do
    page? = SlipdockWeb.SlipdockComponents.page?(assigns.card)
    # `page-7` for a page, a bare number for a card — the same id the
    # drag-and-drop sends, read by `Slipdock.Boards.item_ref/1`. A card keeps
    # the ids it always had, so only the pages need a prefix to stay apart.
    item_id = if page?, do: "page-#{assigns.card.id}", else: to_string(assigns.card.id)

    assigns =
      assign(assigns,
        menu_id: "move-menu-#{item_id}",
        anchor_id: "move-#{item_id}",
        item_id: item_id
      )

    ~H"""
    <button
      id={@anchor_id}
      type="button"
      popovertarget={@menu_id}
      phx-click={JS.focus()}
      class="btn btn-ghost btn-xs btn-square text-base-content/40 opacity-0 transition group-hover:opacity-100 focus:opacity-100 no-hover:opacity-100"
      title="Move to another list"
      aria-label={"Move “#{@card.title}” to another list"}
    >
      <.icon name="hero-arrow-right-circle" class="size-4" />
    </button>
    <div
      id={@menu_id}
      popover
      phx-hook="AnchoredPopover"
      data-anchor={@anchor_id}
      class="pop-menu"
    >
      <ul class="menu max-h-[60vh] w-48 flex-nowrap overflow-y-auto rounded-xl bg-base-100 p-1 text-sm shadow-xl ring-1 ring-base-content/10">
        <li class="menu-title px-2 py-1 text-2xs">Move to</li>
        <li :for={column <- @board.columns}>
          <button
            type="button"
            popovertarget={@menu_id}
            popovertargetaction="hide"
            phx-click="move_card"
            phx-value-id={@item_id}
            phx-value-to={column.id}
            disabled={column.id == @card.column_id}
            class={[
              "flex items-center gap-2",
              column.id == @card.column_id && "text-base-content/40"
            ]}
          >
            <span
              :if={column.color}
              class={["size-2 shrink-0 rounded-full", Palette.dot(column.color)]}
            ></span>
            <span class="min-w-0 flex-1 truncate text-left">{column.name}</span>
            <.icon :if={column.id == @card.column_id} name="hero-check" class="size-3.5 shrink-0" />
          </button>
        </li>
        <li class="border-t border-base-content/10 pt-1">
          <button
            type="button"
            popovertarget={@menu_id}
            popovertargetaction="hide"
            phx-click="open_move_board"
            phx-target="#board-move"
            phx-value-id={@card.id}
            class="flex items-center gap-2"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-3.5 shrink-0" />
            <span class="min-w-0 flex-1 truncate text-left">Another board…</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :columns, :list, required: true

  @doc false
  # The phone's list strip. The board is one list wide on a 390pt screen, so
  # this is the map: every list, how full it is, and which one you are on.
  # Tapping one slides the board to it (see the `ListPager` hook); swiping
  # the board moves the highlight back. Nothing here reaches the server.
  defp list_pager(assigns) do
    ~H"""
    <div
      id="list-pager"
      phx-hook="ListPager"
      role="tablist"
      aria-label="Lists"
      class="kanban-scroll flex shrink-0 gap-1 overflow-x-auto border-b border-base-300 bg-base-100/70 px-3 py-1.5"
    >
      <button
        :for={%{column: column, cards: cards} <- @columns}
        type="button"
        role="tab"
        data-column={column.id}
        class="pager-tab flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium text-base-content/60"
      >
        <span
          :if={column.color}
          class={["size-2 shrink-0 rounded-full", Palette.dot(column.color)]}
        ></span>
        <span class="max-w-32 truncate">{column.name}</span>
        <span class="font-mono text-2xs opacity-60">{length(cards)}</span>
      </button>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :filters, :map, required: true
  attr :filtering, :boolean, required: true
  attr :columns, :list, required: true
  attr :config, Config, required: true
  attr :view, :any, default: nil
  attr :dirty, :boolean, default: false
  attr :form_key, :integer, required: true
  attr :can_write, :boolean, default: true
  attr :can_manage, :boolean, default: false
  attr :view_only, :boolean, required: true
  attr :view_grants, :list, default: []
  attr :groups, :list, default: []
  attr :share_key, :integer, default: 0
  attr :marks, :any, default: nil, doc: "the reader's favourites (`Slipdock.Favourites.marks/1`)"
  attr :meetings, :atom, default: :none

  # Board view's toolbar: the view switcher, search, filters, display options,
  # saved views and the count, laid out like `swim_toolbar/1` so nothing
  # moves when switching views.
  defp board_toolbar(assigns) do
    shown = Enum.sum(for %{cards: cards} <- assigns.columns, do: length(cards))
    hidden = Enum.sum(for %{hidden: hidden} <- assigns.columns, do: hidden)
    assigns = assign(assigns, shown: shown, hidden: hidden)

    ~H"""
    <div class="flex flex-wrap items-center gap-x-2 gap-y-2 border-b border-base-300 bg-base-100/70 px-3 py-2 text-sm">
      <.view_tabs
        :if={!@view_only}
        board={@board}
        meetings={@meetings}
        mode={:board}
        config={@config}
        view={@view}
        marks={@marks}
      />
      <span class="hidden h-5 w-px bg-base-300 sm:block"></span>

      <.search_box id="board-search-box" q={@filters.q}>
        <form id="board-search" phx-change="search" phx-submit="search" class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
          />
          <input
            type="search"
            name="q"
            value={@filters.q}
            placeholder="Search cards…"
            phx-debounce="200"
            class="input input-sm w-40 rounded-full pl-8 transition-[width] focus:w-64"
            autocomplete="off"
          />
        </form>
      </.search_box>

      <.filter_menu board={@board} filters={@filters} filtering={@filtering} />

      <form id="swim-config" phx-change="swim_config" phx-submit="swim_config" class="contents">
        <.display_menu mode={:board} config={@config} />
      </form>

      <div class="ml-auto flex items-center gap-2">
        <span class="hidden text-xs text-base-content/50 lg:inline" title="Cards shown">
          {@shown} {if @shown == 1, do: "card", else: "cards"}<span :if={@hidden > 0}> · {@hidden} hidden</span>
        </span>
        <.view_controls
          board={@board}
          mode={:board}
          view={@view}
          dirty={@dirty}
          can_write={@can_write}
          can_manage={@can_manage}
          view_only={@view_only}
          view_grants={@view_grants}
          groups={@groups}
          share_key={@share_key}
          form_key={@form_key}
          favourites={@marks}
        />
      </div>
    </div>
    """
  end
end
