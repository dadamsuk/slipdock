defmodule SlipdockWeb.BoardLive.BoardView.Kanban do
  @moduledoc """
  The parts of the board view's template
  (`SlipdockWeb.BoardLive.BoardView.kanban/1`): its toolbar, the banner and
  the list of matches while searching, the phone's list strip, and the lists
  side by side, each with its header, its cards, its snoozed cards and its
  footer. Each part is given the assigns it reads, by name. Their events go
  to the board's LiveView, as they did in the one template.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.SwimlaneComponents
  import SlipdockWeb.BoardLive.Helpers, only: [tag_by_id: 2]

  alias Slipdock.{ListOrder, Palette}
  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.BoardLive.SearchResults

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
  attr :select_mode, :boolean, default: false
  attr :card_view_names, :list, default: []
  slot :inner_block, doc: "the board's own buttons, last, right of Views"

  @doc false
  # Board view's toolbar: the same `view_toolbar/1` as every other view
  # (#1711), so nothing moves when switching views. The board has no
  # controls of its own to fold; it has Select, right of the count.
  def board_toolbar(assigns) do
    shown = Enum.sum(for %{cards: cards} <- assigns.columns, do: length(cards))
    hidden = Enum.sum(for %{hidden: hidden} <- assigns.columns, do: hidden)
    assigns = assign(assigns, shown: shown, hidden: hidden)

    ~H"""
    <.view_toolbar id="board-toolbar" mode={:board} shown={@shown} hidden={@hidden}>
      <:switcher :if={!@view_only}>
        <.view_tabs board={@board} mode={:board} view={@view} marks={@marks} />
      </:switcher>
      <:search>
        <.search_box
          id="board-search-box"
          q={@filters.q}
          clear={JS.push("search", value: %{q: ""})}
        >
          <form id="board-search" phx-change="search" phx-submit="search" class="relative">
            <.search_input
              value={@filters.q}
              placeholder="Quick search…"
              phx-debounce="200"
              trail={1}
              class="w-44"
              autocomplete="off"
            />
          </form>
        </.search_box>
      </:search>
      <:filter>
        <.filter_menu board={@board} filters={@filters} filtering={@filtering} states />
      </:filter>
      <:display>
        <form id="swim-config" phx-change="swim_config" phx-submit="swim_config" class="contents">
          <.display_menu
            mode={:board}
            config={@config}
            board={@board}
            card_view_names={@card_view_names}
          />
        </form>
      </:display>
      <:select :if={@can_write}>
        <button
          id="select-mode-toggle"
          type="button"
          phx-click="toggle_select_mode"
          class={["btn btn-sm gap-1", if(@select_mode, do: "btn-primary", else: "btn-ghost")]}
          aria-pressed={to_string(@select_mode)}
          title="Select several cards and change them all at once"
          aria-label="Select several cards"
        >
          <.icon name="hero-check-circle" class="size-4" />
          <span class="hidden sm:inline">{if @select_mode, do: "Selecting", else: "Select"}</span>
        </button>
      </:select>
      <:views>
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
      </:views>
      <:actions :if={@inner_block != []}>{render_slot(@inner_block)}</:actions>
    </.view_toolbar>
    """
  end

  attr :board, :any, required: true
  attr :columns, :list, required: true
  attr :filters, :map, required: true
  attr :filtering, :boolean, required: true
  attr :page_hit, :any, required: true
  attr :card_hit, :any, required: true
  attr :search_layout, :atom, required: true

  @doc "What is searched or filtered for, how many cards match, and the way out."
  def search_banner(assigns) do
    ~H"""
    <div
      :if={@filtering}
      id="search-results-banner"
      class="flex flex-wrap items-center gap-2 border-b border-base-300 bg-base-100/60 px-4 py-2 text-sm"
    >
      <span id="search-summary" class="font-medium">{SearchResults.summary(@columns)}</span>
      <span class="text-base-content/60">matching:</span>
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
      <.link
        :if={@card_hit}
        id="search-card-hit"
        navigate={~p"/boards/#{@card_hit.board_id}/cards/#{@card_hit.id}"}
        class="badge badge-primary badge-outline gap-1 hover:bg-primary/10"
      >
        <.icon name="hero-rectangle-stack" class="size-3.5" />
        <span class="font-mono">{"#" <> to_string(@card_hit.id)}</span> {@card_hit.title}
        <span class="text-base-content/50">· {@card_hit.board.name}</span>
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
      <SearchResults.layout_toggle layout={@search_layout} />
    </div>
    """
  end

  attr :board, :any, required: true
  attr :columns, :list, required: true
  attr :filtering, :boolean, required: true
  attr :search_layout, :atom, required: true
  attr :result_folds, :any, required: true
  attr :narrow?, :boolean, required: true
  attr :select_mode, :boolean, required: true
  attr :selected, :any, required: true
  attr :swim, Config, required: true
  attr :focus, :any, required: true
  attr :can_write, :boolean, required: true
  attr :favourites, :any, required: true
  attr :zone, :string, required: true

  @doc "The matches as one list down the page, grouped by list."
  def search_list(assigns) do
    ~H"""
    <%!-- Searched or filtered, the matches are one list down the page,
            grouped by list (#2809), unless the reader asked for the columns:
            on a wide board the lists with matches were off to the right. --%>
    <SearchResults.search_results
      :if={@filtering and @search_layout == :list}
      columns={@columns}
      folds={@result_folds}
      narrow?={@narrow?}
      select_mode={@select_mode}
      selected={@selected}
    >
      <:row :let={{column, {_kind, item}}}>
        <.card
          card={item}
          compact
          show={list_show(@swim, column)}
          handoff_label={Slipdock.Boards.Board.handoff_label(@board)}
          focus={@focus && card_focus(@focus, item)}
          dismiss={@can_write}
          selected={@select_mode && card_selected?(@selected, item)}
          marks={@favourites}
          zone={@zone}
        >
          <:actions :if={@can_write and length(@board.columns) > 1}>
            <.move_menu card={item} board={@board} />
          </:actions>
        </.card>
      </:row>
    </SearchResults.search_results>
    """
  end

  attr :columns, :list, required: true

  @doc false
  # The phone's list strip. The board is one list wide on a 390pt screen, so
  # this is the map: every list, how full it is, and which one you are on.
  # Tapping one slides the board to it (see the `ListPager` hook); swiping
  # the board moves the highlight back. Nothing here reaches the server.
  def list_pager(assigns) do
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
  attr :columns, :list, required: true
  attr :filtering, :boolean, required: true
  attr :search_layout, :atom, required: true
  attr :swim, Config, required: true
  attr :form_key, :integer, required: true
  attr :can_write, :boolean, required: true
  attr :favourites, :any, required: true
  attr :narrow?, :boolean, required: true
  attr :renaming_column, :any, required: true
  attr :focus, :any, required: true
  attr :adding_to, :any, required: true
  attr :adding_column, :boolean, required: true
  attr :uploads, :map, required: true
  attr :select_mode, :boolean, required: true
  attr :zone, :string, required: true
  attr :revealed_snoozed, :any, required: true
  attr :selected, :any, required: true

  @doc "The lists side by side, in the scroller they are dragged about in, and Add another list."
  def lists(assigns) do
    ~H"""
    <div
      :if={not (@filtering and @search_layout == :list)}
      id="board-scroll"
      phx-hook="ScrollEnd"
      data-drop-area
      class={
        [
          "kanban-scroll min-h-0 flex-1 overflow-x-auto overflow-y-hidden",
          @narrow? && "snap-x snap-mandatory",
          # A shift-click picks a run of cards; without this it also
          # highlights the text between them.
          @select_mode && "select-none"
        ]
      }
    >
      <div
        id="columns"
        phx-hook="Sortable"
        data-group="columns"
        data-draggable=".kanban-column"
        data-handle=".column-handle"
        data-event="move_column"
        data-disabled={to_string(!@can_write)}
        class={
          [
            "flex h-full items-start",
            # w-max: a flex row narrower than its lists loses its right
            # padding in the scroller, leaving the last one on the edge.
            if(@narrow?, do: "gap-0", else: "w-max min-w-full gap-4 p-4")
          ]
        }
      >
        <%!-- On a phone one list fills the screen, so it is the page: no
                margin round it, no well behind it, and the cards sit straight
                on the background, edge to edge bar a little breathing room. --%>
        <div
          :for={
            %{column: column, cards: cards, groups: groups, hidden: hidden, snoozed: snoozed} <-
              @columns
          }
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
          <.list_header
            column={column}
            cards={cards}
            groups={groups}
            renaming_column={@renaming_column}
            can_write={@can_write}
            select_mode={@select_mode}
            selected={@selected}
            favourites={@favourites}
          />

          <.list_cards
            column={column}
            groups={groups}
            hidden={hidden}
            board={@board}
            swim={@swim}
            focus={@focus}
            can_write={@can_write}
            narrow?={@narrow?}
            select_mode={@select_mode}
            selected={@selected}
            favourites={@favourites}
            zone={@zone}
          />

          <.list_snoozed
            column={column}
            snoozed={snoozed}
            revealed_snoozed={@revealed_snoozed}
            board={@board}
            swim={@swim}
            narrow?={@narrow?}
            select_mode={@select_mode}
            selected={@selected}
            favourites={@favourites}
            zone={@zone}
          />

          <.list_footer
            :if={@can_write}
            column={column}
            board={@board}
            adding_to={@adding_to}
            form_key={@form_key}
            uploads={@uploads}
          />
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

        <.add_list
          :if={@can_write}
          narrow?={@narrow?}
          swim={@swim}
          adding_column={@adding_column}
          form_key={@form_key}
        />
      </div>
    </div>
    """
  end

  attr :column, :any, required: true
  attr :cards, :list, required: true
  attr :groups, :list, required: true, doc: "the list's cards as drawn, under their headings"
  attr :renaming_column, :any, required: true
  attr :can_write, :boolean, required: true
  attr :select_mode, :boolean, required: true
  attr :selected, :any, required: true
  attr :favourites, :any, required: true

  @doc "A list's header: its name, its marks and count, and its menu."
  def list_header(assigns) do
    ~H"""
    <div class="column-handle flex cursor-grab items-center gap-2 px-3 pb-1 pt-3 active:cursor-grabbing">
      <span
        :if={@column.color}
        class={["size-2.5 shrink-0 rounded-full", Palette.dot(@column.color)]}
      ></span>
      <form
        :if={@renaming_column == @column.id}
        phx-submit="rename_column"
        class="flex-1"
      >
        <input type="hidden" name="column_id" value={@column.id} />
        <input
          type="text"
          name="name"
          value={@column.name}
          class="input field w-full font-semibold"
          phx-hook="Focus"
          data-select
          phx-blur="cancel_rename_column"
          phx-window-keydown="cancel_rename_column"
          phx-key="Escape"
          id={"rename-#{@column.id}"}
        />
      </form>
      <h2
        :if={@renaming_column != @column.id}
        class={[
          "min-w-0 flex-1 truncate rounded px-1 text-sm font-semibold",
          @can_write && "cursor-text hover:bg-base-100/60"
        ]}
        phx-click={@can_write && "start_rename_column"}
        phx-value-id={@column.id}
        title={@can_write && "Click to rename"}
      >
        {@column.name}
      </h2>
      <span
        :if={Column.horizon?(@column)}
        class="chip chip-line max-w-28 shrink-0 truncate text-2xs"
        title={"This list stands for #{Column.horizon_label(@column)}"}
      >
        {Column.horizon_label(@column)}
      </span>
      <% drifted = Enum.count(@cards, &Column.drifted?(@column, Card.effective_due(&1))) %>
      <span
        :if={drifted > 0}
        class="chip bg-amber-500/15 text-2xs text-amber-700 dark:text-amber-300"
        title={"#{drifted} #{if drifted == 1, do: "card is", else: "cards are"} due outside this horizon"}
      >
        <.icon name="hero-arrow-uturn-right" class="size-3" /> {drifted}
      </span>
      <span
        :if={ListOrder.label(@column)}
        class="shrink-0 text-base-content/50"
        title={"Cards drawn #{ListOrder.label(@column)} — set in List settings"}
      >
        <.icon name="hero-bars-arrow-down" class="size-3.5" />
      </span>
      <%!-- Stand-ins are not work in this list, so they are not
                    counted against its limit. --%>
      <% count = Enum.count(@column.cards, &(not Card.stand_in?(&1))) %>
      <span
        data-role="list-count"
        class={[
          "badge badge-sm tabular-nums",
          cond do
            @column.wip_limit && count > @column.wip_limit -> "badge-error"
            @column.wip_limit && count == @column.wip_limit -> "badge-warning"
            true -> "badge-ghost"
          end
        ]}
        title={
          if @column.wip_limit,
            do: "WIP limit #{@column.wip_limit}",
            else: "#{count} cards"
        }
      >
        {if @column.wip_limit,
          do: "#{count}/#{@column.wip_limit}",
          else: count}
      </span>
      <%!-- Select mode's select-all for the list (#2690): every
                    card it shows, or none once they are all picked. --%>
      <% all? =
        @select_mode &&
          SlipdockWeb.BoardLive.Selection.all_selected?(@selected, %{groups: @groups}) %>
      <button
        :if={@select_mode}
        type="button"
        id={"select-list-#{@column.id}"}
        class={["btn btn-xs btn-square", if(all?, do: "btn-primary", else: "btn-ghost")]}
        phx-click="select_list"
        phx-value-id={@column.id}
        aria-pressed={to_string(all?)}
        title={if all?, do: "Deselect this list's cards", else: "Select every card in this list"}
      >
        <.icon
          name={if all?, do: "hero-check-circle-solid", else: "hero-check-circle"}
          class="size-4"
        />
      </button>
      <%!-- The heart only on a list that is a favourite: on every
                    header it was one more mark to read past. Favouriting
                    is in the ⋯ menu, which a reader gets too, since a
                    favourite needs only the right to see the list. --%>
      <% favourite? =
        Slipdock.Favourites.favourite?(@favourites || MapSet.new(), :column, @column.id) %>
      <.favourite_toggle
        :if={favourite?}
        kind="column"
        id={@column.id}
        name={@column.name}
        marks={@favourites}
        class="p-0.5"
        size="size-3.5"
      />
      <div class="dropdown dropdown-end">
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
          <li :if={@can_write}>
            <button phx-click="start_add_card" phx-value-id={@column.id}>
              <.icon name="hero-plus" class="size-4" /> Add card
            </button>
          </li>
          <li :if={@can_write}>
            <button
              id={"select-all-list-#{@column.id}"}
              phx-click="select_all_in_list"
              phx-value-id={@column.id}
            >
              <.icon name="hero-check-circle" class="size-4" /> Select all
            </button>
          </li>
          <li>
            <button
              id={"favourite-list-#{@column.id}"}
              data-role="favourite-list"
              phx-click="toggle_favourite"
              phx-value-kind="column"
              phx-value-id={@column.id}
              aria-pressed={to_string(favourite?)}
            >
              <.icon
                name={if favourite?, do: "hero-heart-solid", else: "hero-heart"}
                class={["size-4", favourite? && "text-rose-500"]}
              />
              {if favourite?, do: "Remove from favourites", else: "Favourite this list"}
            </button>
          </li>
          <li>
            <.link
              id={"card-view-list-#{@column.id}"}
              navigate={~p"/card-views?#{[board: @column.board_id, list: @column.id]}"}
            >
              <.icon name="hero-rectangle-stack" class="size-4" /> Card view…
            </.link>
          </li>
          <li :if={@can_write}>
            <button
              phx-click="edit_column"
              phx-target="#board-column"
              phx-value-id={@column.id}
            >
              <.icon name="hero-cog-6-tooth" class="size-4" /> List settings
            </button>
          </li>
          <li :if={@can_write}>
            <button
              class="text-error"
              phx-click="delete_column"
              phx-target="#board-column"
              phx-value-id={@column.id}
              data-confirm={"Delete “#{@column.name}” and its #{length(@column.cards)} cards?"}
            >
              <.icon name="hero-trash" class="size-4" /> Delete list
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :column, :any, required: true
  attr :groups, :list, required: true
  attr :hidden, :integer, required: true
  attr :board, :any, required: true
  attr :swim, Config, required: true
  attr :focus, :any, required: true
  attr :can_write, :boolean, required: true
  attr :narrow?, :boolean, required: true
  attr :select_mode, :boolean, required: true
  attr :selected, :any, required: true
  attr :favourites, :any, required: true
  attr :zone, :string, required: true

  @doc "A list's cards and placed pages, in the box they are dragged within."
  def list_cards(assigns) do
    ~H"""
    <div
      id={"cards-#{@column.id}"}
      data-id={@column.id}
      phx-hook="Sortable"
      data-group="cards"
      data-event="move_card"
      data-disabled={to_string(!@can_write)}
      data-draggable=".kanban-card"
      data-sort={to_string(!ListOrder.sorted?(@column))}
      data-column-drop=".kanban-column"
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
      <%= for group <- @groups do %>
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
          show={list_show(@swim, @column)}
          handoff_label={Slipdock.Boards.Board.handoff_label(@board)}
          focus={@focus && card_focus(@focus, item)}
          dismiss={@can_write}
          selected={@select_mode && card_selected?(@selected, item)}
          marks={@favourites}
          zone={@zone}
        >
          <:actions :if={@can_write and length(@board.columns) > 1}>
            <.move_menu card={item} board={@board} />
          </:actions>
        </.card>
      <% end %>
      <p :if={@hidden > 0} class="px-1 py-1 text-center text-2xs text-base-content/60">
        {@hidden} hidden by filters
      </p>
    </div>
    """
  end

  attr :column, :any, required: true
  attr :snoozed, :list, required: true
  attr :revealed_snoozed, :any, required: true
  attr :board, :any, required: true
  attr :swim, Config, required: true
  attr :narrow?, :boolean, required: true
  attr :select_mode, :boolean, required: true
  attr :selected, :any, required: true
  attr :favourites, :any, required: true
  attr :zone, :string, required: true

  @doc "A list's snoozed cards: counted, and shown faded on request."
  def list_snoozed(assigns) do
    ~H"""
    <%!-- Snoozed cards (W-1803): counted here, and shown in place,
                  faded, on request. Outside the sortable list, so they are
                  not dragged about while asleep. --%>
    <div :if={@snoozed != []} class={["space-y-2", if(@narrow?, do: "px-3", else: "px-2")]}>
      <div
        :if={MapSet.member?(@revealed_snoozed, @column.id)}
        id={"snoozed-cards-#{@column.id}"}
        class="space-y-2"
      >
        <.card
          :for={item <- @snoozed}
          card={item}
          id={"snoozed-card-#{item.id}"}
          compact={@swim.density == "compact"}
          show={list_show(@swim, @column)}
          handoff_label={Slipdock.Boards.Board.handoff_label(@board)}
          selected={@select_mode && card_selected?(@selected, item)}
          marks={@favourites}
          zone={@zone}
        />
      </div>
      <SlipdockWeb.BoardLive.SnoozeEvents.snoozed_footer
        column={@column}
        snoozed={@snoozed}
        revealed={MapSet.member?(@revealed_snoozed, @column.id)}
      />
    </div>
    """
  end

  attr :column, :any, required: true
  attr :board, :any, required: true
  attr :adding_to, :any, required: true
  attr :form_key, :integer, required: true
  attr :uploads, :map, required: true

  @doc "A list's foot, for someone who can write: the quick-add form, or the buttons that add a card, a page or a file."
  def list_footer(assigns) do
    ~H"""
    <div class="p-2">
      <form
        :if={@adding_to == @column.id}
        id={"quick-add-#{@column.id}-#{@form_key}"}
        phx-submit="quick_add_card"
        class="kanban-pop space-y-2"
      >
        <input type="hidden" name="column_id" value={@column.id} />
        <input
          type="text"
          name="title"
          placeholder="Title; description;; comment, then Enter"
          class="input field w-full"
          phx-hook="Focus"
          id={"quick-add-input-#{@column.id}-#{@form_key}"}
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
                    at the foot of this list. "Add card" says what it adds;
                    the page and file icons, being the rarer two, stay
                    icons with a tooltip — a list is narrow, and what is in
                    it matters more than how to add to it. Each can be
                    turned off in the board's settings. --%>
      <div
        :if={@adding_to != @column.id}
        data-role="list-footer"
        class="flex items-center gap-0.5"
      >
        <button
          :if={@board.add_card}
          type="button"
          class="btn btn-ghost btn-sm gap-1.5 px-2 text-base-content/50 hover:text-base-content"
          phx-click="start_add_card"
          phx-value-id={@column.id}
          title="Add a card to this list"
          aria-label={"Add a card to #{@column.name}"}
        >
          <.icon name="hero-plus" class="size-4" />
          <span class="text-xs font-normal">Add card</span>
        </button>
        <%!-- Straight into the wiki's own editor, carrying the
                      list: a page is written as Markdown, not filled into a
                      card form, and it is placed here when it is saved. --%>
        <.link
          :if={@board.add_page}
          navigate={~p"/boards/#{@board}/wiki/new?#{[column: @column.id]}"}
          class="btn btn-ghost btn-sm btn-square text-base-content/50 hover:text-base-content"
          title="Add page: a wiki page, written here and placed in this list"
          aria-label={"Add a page to #{@column.name}"}
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
          title="Attach file: a file, on a card of its own in this list"
          aria-label={"Add a document to #{@column.name}"}
          phx-click={
            JS.push("aim_document", value: %{id: @column.id})
            |> JS.dispatch("click", to: "##{@uploads.list_document.ref}")
          }
        >
          <.icon name="hero-paper-clip" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :narrow?, :boolean, required: true
  attr :swim, Config, required: true
  attr :adding_column, :boolean, required: true
  attr :form_key, :integer, required: true

  @doc "The place of one more list, for someone who can write: its form, or the ghost list that opens it."
  def add_list(assigns) do
    ~H"""
    <div class={["shrink-0", if(@narrow?, do: "w-screen snap-start p-3", else: list_width(@swim))]}>
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
          class="input field w-full"
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
      <%!-- A ghost list: the width of a list and as quiet as its
                  footer, so it reads as "one more of these", not a button
                  shouting beside them. --%>
      <button
        :if={!@adding_column}
        type="button"
        data-role="add-list"
        class="flex w-full items-center gap-1.5 rounded-2xl border border-dashed border-base-content/15 bg-base-300/30 px-3 py-3 text-sm text-base-content/60 transition hover:border-base-content/30 hover:bg-base-300/60 hover:text-base-content"
        phx-click="start_add_column"
      >
        <.icon name="hero-plus" class="size-4" /> Add another list
      </button>
    </div>
    """
  end

  # Where the keyboard is, for one card: pointing at it, carrying it, or
  # somewhere else entirely.
  # The keyboard cursor walks cards. A placed wiki page is drawn beside them
  # but is not in `col.cards`, so it is never the cursor — and must not light
  # up because it happens to share a card's number.
  # The display's facets for one list's cards: without the age chip or the
  # front image when the list's settings turn them off.
  # The reader's card views for the list (#2031) already have them off
  # (`State.assign_swim_state/4`); a config without them still drops them.
  defp list_show(swim, column) do
    swim
    |> Config.shown(column.id)
    |> MapSet.difference(MapSet.new(Slipdock.CardViews.list_hidden(column)))
  end

  defp card_focus(_focus, %Slipdock.Wiki.Page{}), do: nil

  defp card_focus(%{card_id: id, holding?: true}, %{id: id}), do: :held

  defp card_focus(%{card_id: id}, %{id: id}), do: :cursor

  defp card_focus(_focus, _card), do: nil

  # A placed page is never selected, whatever number it shares with a card.
  defp card_selected?(_selected, %Slipdock.Wiki.Page{}), do: false
  defp card_selected?(selected, %{id: id}), do: MapSet.member?(selected, id)

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
    # drag-and-drop sends, read by `Slipdock.Boards.Columns.item_ref/1`. A card keeps
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
            phx-value-from={@card.column_id}
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
end
