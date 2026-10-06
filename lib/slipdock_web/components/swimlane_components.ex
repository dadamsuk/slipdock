defmodule SlipdockWeb.SwimlaneComponents do
  @moduledoc """
  The swimlane view: a configuration toolbar (axes, date grouping, sorting,
  filters, display options, saved views) and the grid itself.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ShareComponents
  alias Slipdock.Palette
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Table

  @section_title "text-2xs font-semibold uppercase tracking-wide text-base-content/60"

  ## Toolbar ---------------------------------------------------------------

  attr :board, :any, required: true
  attr :config, Config, required: true
  attr :view, :any, default: nil, doc: "the saved view currently loaded, if any"
  attr :dirty, :boolean, default: false, doc: "config differs from the loaded saved view"
  attr :grid, :map, required: true
  attr :form_key, :integer, required: true
  attr :mode, :atom, default: :swimlanes, doc: ":swimlanes, :table, :timeline or :calendar"
  attr :nav, :map, default: nil, doc: "timeline/calendar: %{title, prev, next}"
  attr :can_write, :boolean, default: true
  attr :can_manage, :boolean, default: false, doc: "board owner: may share views"
  attr :view_only, :boolean, default: false, doc: "access only through granted views"
  attr :allowed_views, :list, default: []
  attr :view_grants, :list, default: []
  attr :groups, :list, default: []
  attr :share_key, :integer, default: 0

  attr :favourites, :any,
    default: nil,
    doc: "the reader's favourites, from `Slipdock.Favourites.marks/1`"

  slot :leading, doc: "rendered first, before the view's own controls: the view switcher"

  def swim_toolbar(assigns) do
    assigns = assign(assigns, section_title: @section_title)

    ~H"""
    <div class="flex flex-wrap items-center gap-x-2 gap-y-2 border-b border-base-300 bg-base-100/70 px-3 py-2 text-sm">
      {render_slot(@leading)}
      <span :if={@leading != []} class="hidden h-5 w-px bg-base-300 sm:block"></span>
      <div :if={@view_only} class="flex items-center gap-2 text-sm">
        <.icon name="hero-lock-closed" class="size-4 text-base-content/50" />
        <span class="text-base-content/60">Shared view</span>
        <span class="font-semibold">{@view && @view.name}</span>
        <span :if={length(@allowed_views) > 1} class="dropdown">
          <div tabindex="0" role="button" class="btn btn-ghost btn-xs">
            Switch <.icon name="hero-chevron-down" class="size-3" />
          </div>
          <ul
            tabindex="0"
            class="menu dropdown-content z-30 mt-1 w-56 rounded-xl bg-base-100 p-1 shadow-lg ring-1 ring-base-content/10"
          >
            <li :for={v <- @allowed_views}><.link patch={view_path(@board, v)}>{v.name}</.link></li>
          </ul>
        </span>
      </div>
      <form
        :if={!@view_only}
        id="swim-config"
        phx-change="swim_config"
        phx-submit="swim_config"
        class="contents"
      >
        <div :if={@nav} class="toolbar-nav flex items-center gap-1">
          <div class="join">
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-square join-item"
              phx-click="swim_set"
              phx-value-key="date"
              phx-value-value={@nav.prev}
              value={@nav.prev}
              title="Earlier"
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-sm join-item"
              phx-click="swim_set"
              phx-value-key="date"
              phx-value-value=""
              value=""
              title="Back to today"
            >
              Today
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-square join-item"
              phx-click="swim_set"
              phx-value-key="date"
              phx-value-value={@nav.next}
              value={@nav.next}
              title="Later"
            >
              <.icon name="hero-chevron-right" class="size-4" />
            </button>
          </div>
          <span id="swim-nav-title" class="whitespace-nowrap text-sm font-semibold">{@nav.title}</span>
        </div>

        <div class="dropdown">
          <div
            tabindex="0"
            role="button"
            class={["btn btn-ghost btn-sm gap-1", Config.filtering?(@config) && "text-primary"]}
            title="Filter"
          >
            <.icon name="hero-funnel" class="size-4" />
            <span class="hidden sm:inline">Filter</span>
            <span :if={Config.filtering?(@config)} class="badge badge-primary badge-xs">
              {Config.active_filter_count(@config)}
            </span>
          </div>
          <div
            tabindex="0"
            class="dropdown-content z-30 mt-2 w-80 space-y-4 rounded-2xl bg-base-100 p-4 shadow-xl ring-1 ring-base-content/10"
          >
            <%!-- Cards, documents (a card whose whole content is its file) and
                  wiki pages placed in a list. See `Slipdock.Kinds`. --%>
            <div>
              <p class={["mb-1.5", @section_title]}>Kind</p>
              <div class="flex flex-wrap gap-1">
                <label :for={{kind, label} <- Slipdock.Kinds.all()} class="cursor-pointer">
                  <input
                    type="checkbox"
                    name="kinds[]"
                    value={kind}
                    checked={kind in @config.kinds}
                    class="peer sr-only"
                  />
                  <span class="btn btn-xs btn-ghost peer-checked:btn-primary">
                    <.icon name={kind_icon(kind)} class="size-3.5" /> {label}
                  </span>
                </label>
              </div>
            </div>
            <div :if={@board.tags != []}>
              <p class={["mb-1.5", @section_title]}>Tags</p>
              <div class="flex flex-wrap gap-1.5">
                <label :for={tag <- @board.tags} class="cursor-pointer">
                  <input
                    type="checkbox"
                    name="tags[]"
                    value={tag.id}
                    checked={tag.id in @config.tags}
                    class="peer sr-only"
                  />
                  <span class="block rounded-md opacity-60 ring-2 ring-transparent ring-offset-1 ring-offset-base-100 transition hover:opacity-100 peer-checked:opacity-100 peer-checked:ring-primary">
                    <.tag_chip tag={tag} />
                  </span>
                </label>
              </div>
            </div>
            <div>
              <p class={["mb-1.5", @section_title]}>Priority</p>
              <div class="flex flex-wrap gap-1">
                <label :for={p <- ~w(critical high medium low none)} class="cursor-pointer">
                  <input
                    type="checkbox"
                    name="priorities[]"
                    value={p}
                    checked={p in @config.priorities}
                    class="peer sr-only"
                  />
                  <span class="btn btn-xs btn-ghost peer-checked:btn-primary">
                    <.priority_badge priority={p} /> {priority_label(p)}
                  </span>
                </label>
              </div>
            </div>
            <div>
              <p class={["mb-1.5", @section_title]}>Flags</p>
              <div class="flex flex-wrap gap-1">
                <label :for={{flag, label, icon, _, _} <- flags()} class="cursor-pointer">
                  <input
                    type="checkbox"
                    name="flags[]"
                    value={flag}
                    checked={flag in @config.flags}
                    class="peer sr-only"
                  />
                  <span class="btn btn-xs btn-ghost peer-checked:btn-primary">
                    <.icon name={icon} class="size-3.5" /> {label}
                  </span>
                </label>
              </div>
            </div>
            <div>
              <p class={["mb-1.5", @section_title]}>Lists</p>
              <div class="flex flex-wrap gap-1">
                <label :for={col <- @board.columns} class="cursor-pointer">
                  <input
                    type="checkbox"
                    name="columns[]"
                    value={col.id}
                    checked={col.id in @config.columns}
                    class="peer sr-only"
                  />
                  <span class="btn btn-xs btn-ghost peer-checked:btn-primary">{col.name}</span>
                </label>
              </div>
            </div>
            <div>
              <p class={["mb-1.5", @section_title]}>Due</p>
              <div class="flex flex-wrap gap-1">
                <label :for={{value, label} <- Config.dues()} class="cursor-pointer">
                  <input
                    type="radio"
                    name="due"
                    value={value}
                    checked={(@config.due || "") == value}
                    class="peer sr-only"
                  />
                  <span class="btn btn-xs btn-ghost peer-checked:btn-primary">{label}</span>
                </label>
              </div>
            </div>
            <div>
              <p class={["mb-1.5", @section_title]}>Status</p>
              <div class="flex flex-wrap gap-1">
                <label :for={{value, label} <- Config.dones()} class="cursor-pointer">
                  <input
                    type="radio"
                    name="done"
                    value={value}
                    checked={@config.done == value}
                    class="peer sr-only"
                  />
                  <span class="btn btn-xs btn-ghost peer-checked:btn-primary">{label}</span>
                </label>
              </div>
            </div>
            <div>
              <p class={["mb-1.5", @section_title]}>Dependencies</p>
              <div class="flex flex-wrap gap-1">
                <label :for={{value, label} <- Config.deps()} class="cursor-pointer">
                  <input
                    type="radio"
                    name="deps"
                    value={value}
                    checked={(@config.deps || "") == value}
                    class="peer sr-only"
                  />
                  <span class="btn btn-xs btn-ghost peer-checked:btn-primary">{label}</span>
                </label>
              </div>
            </div>
            <div>
              <p class={["mb-1.5", @section_title]}>Cover colour</p>
              <div class="flex flex-wrap gap-1.5">
                <label :for={{name, label} <- Palette.all()} class="cursor-pointer" title={label}>
                  <input
                    type="checkbox"
                    name="colors[]"
                    value={name}
                    checked={name in @config.colors}
                    class="peer sr-only"
                  />
                  <span class={[
                    "block size-5 rounded-full opacity-60 ring-offset-2 ring-offset-base-100 transition hover:opacity-100 peer-checked:opacity-100 peer-checked:ring-2 peer-checked:ring-base-content",
                    Palette.dot(name)
                  ]}></span>
                </label>
                <label class="cursor-pointer" title="No cover">
                  <input
                    type="checkbox"
                    name="colors[]"
                    value="none"
                    checked={"none" in @config.colors}
                    class="peer sr-only"
                  />
                  <span class="flex size-5 items-center justify-center rounded-full opacity-60 ring-1 ring-base-content/30 ring-offset-2 ring-offset-base-100 peer-checked:opacity-100 peer-checked:ring-2 peer-checked:ring-base-content">
                    <.icon name="hero-no-symbol" class="size-3 opacity-60" />
                  </span>
                </label>
              </div>
            </div>
            <button
              :if={Config.filtering?(@config)}
              type="button"
              class="btn btn-ghost btn-xs w-full"
              phx-click="swim_clear_filters"
            >
              Clear all filters
            </button>
          </div>
        </div>

        <div id="swim-tools" class="tools">
          <%= cond do %>
            <% @mode == :swimlanes -> %>
              <.axis_select
                board={@board}
                name="rows"
                label="Rows"
                value={@config.rows}
                icon="hero-bars-3"
              />
              <.axis_select
                board={@board}
                name="cols"
                label="Columns"
                value={@config.cols}
                icon="hero-view-columns"
              />
            <% @mode == :calendar -> %>
              <label class="flex items-center gap-1.5">
                <.icon name="hero-calendar-days" class="size-4 text-base-content/50" />
                <span class="sr-only">Span</span>
                <select name="unit" class="select select-sm w-auto" title="Show a month or a week">
                  <option
                    :for={{value, label} <- Slipdock.Calendar.units()}
                    value={value}
                    selected={value == Slipdock.Calendar.unit(@config)}
                  >
                    {label}
                  </option>
                </select>
              </label>
            <% @mode in [:outline, :prioritise] -> %>
              <span></span>
            <% @mode == :narrative -> %>
              <.axis_select
                board={@board}
                name="rows"
                label="Group by"
                value={@config.rows}
                icon="hero-bars-3"
              />
              <label class="flex items-center gap-1.5">
                <.icon name="hero-clock" class="size-4 text-base-content/50" />
                <span class="sr-only">Span</span>
                <select name="span" class="select select-sm w-auto" title="How far back to look">
                  <option
                    :for={{value, label} <- Slipdock.Narrative.spans()}
                    value={value}
                    selected={value == @config.span}
                  >
                    {label}
                  </option>
                </select>
              </label>
              <label
                class="flex items-center gap-1 text-xs text-base-content/60"
                title="Start of the range (leave empty for the span)"
              >
                from
                <input type="date" name="from" value={@config.from} class="input input-sm w-36" />
              </label>
              <label
                class="flex items-center gap-1 text-xs text-base-content/60"
                title="End of the range (leave empty for today)"
              >
                to <input type="date" name="to" value={@config.to} class="input input-sm w-36" />
              </label>
            <% true -> %>
              <.axis_select
                board={@board}
                name="rows"
                label="Group by"
                value={@config.rows}
                icon="hero-bars-3"
              />
          <% end %>

          <label
            :if={@mode == :outline or (@mode == :timeline and (@grid[:levels] || 1) > 1)}
            class="flex items-center gap-1.5"
          >
            <.icon name="hero-bars-arrow-down" class="size-4 text-base-content/50" />
            <span class="sr-only">Levels</span>
            <select
              name="depth"
              class="select select-sm w-auto"
              title="How many levels of subcards to show"
            >
              <option
                :for={
                  {value, label} <-
                    Slipdock.Outline.depths(@grid[:levels] || 1, depth_int(@config.depth))
                }
                value={value}
                selected={value == @config.depth}
              >
                {label}
              </option>
            </select>
          </label>

          <label
            :if={
              @mode == :timeline or
                (Enum.member?([:swimlanes, :table], @mode) and Config.uses_dates?(@config))
            }
            class="flex items-center gap-1.5"
          >
            <.icon
              name={
                if @mode == :timeline, do: "hero-magnifying-glass-plus", else: "hero-calendar-days"
              }
              class="size-4 text-base-content/50"
            />
            <span class="sr-only">{if @mode == :timeline, do: "Zoom", else: "Group dates by"}</span>
            <select
              name="unit"
              class="select select-sm w-auto"
              title={if @mode == :timeline, do: "Zoom: the size of one step", else: "Group dates by"}
            >
              <option
                :for={{value, label} <- Config.units()}
                value={value}
                selected={value == @config.unit}
              >
                {label}
              </option>
            </select>
          </label>

          <span class="hidden h-5 w-px bg-base-300 sm:block"></span>

          <label class="flex items-center gap-1.5">
            <.icon name="hero-arrows-up-down" class="size-4 text-base-content/50" />
            <span class="sr-only">Sort by</span>
            <select name="sort" class="select select-sm w-auto" title="Sort cards within each cell">
              <option
                :for={{value, label} <- Config.sorts(@board)}
                value={value}
                selected={value == @config.sort}
              >
                {label}
              </option>
            </select>
          </label>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="swim_set"
            phx-value-key="dir"
            phx-value-value={if @config.dir == "asc", do: "desc", else: "asc"}
            value={if @config.dir == "asc", do: "desc", else: "asc"}
            title={
              if @config.dir == "asc",
                do: "Ascending — click for descending",
                else: "Descending — click for ascending"
            }
          >
            <.icon
              name={if @config.dir == "asc", do: "hero-bars-arrow-up", else: "hero-bars-arrow-down"}
              class="size-4"
            />
          </button>

          <span class="hidden h-5 w-px bg-base-300 sm:block"></span>

          <.search_box id="swim-search" q={@config.q} class="relative min-w-0 flex-1 sm:flex-none">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
            />
            <input
              type="search"
              name="q"
              value={@config.q}
              placeholder="Search…"
              phx-debounce="300"
              class="input input-sm w-full rounded-full pl-8 transition-[width] sm:w-36 sm:focus:w-56"
              autocomplete="off"
            />
          </.search_box>

          <.display_menu mode={@mode} config={@config} board={@board} />
          <a
            :if={@mode == :table}
            href={
              ~p"/boards/#{@board}/export.csv?#{if(@view, do: [view: @view.id], else: []) ++ Config.to_query(@config, Config.defaults("table"))}"
            }
            class="btn btn-ghost btn-sm gap-1"
            title="Download these rows as CSV"
            download
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> CSV
          </a>
          <div
            :if={Enum.member?([:timeline, :swimlanes], @mode) and @config.color_by != "cover"}
            id="color-legend"
            class="flex flex-wrap items-center gap-x-2.5 gap-y-1 rounded-full bg-base-200/70 px-2.5 py-1 text-2xs text-base-content/70"
            title={"Coloured by #{String.downcase(Config.coloring_label(@config.color_by))}"}
          >
            <span
              :for={{color, label} <- Slipdock.Coloring.legend(@board, @config.color_by)}
              class="flex items-center gap-1"
            >
              <span class={["size-2.5 rounded-full", Slipdock.Palette.dot(color)]}></span>{label}
            </span>
            <span :if={Slipdock.Coloring.legend(@board, @config.color_by) == []} class="italic">
              Nothing to colour yet
            </span>
          </div>
        </div>
      </form>

      <.tools_toggle target="#swim-tools" />

      <div class="ml-auto flex items-center gap-2">
        <span class="hidden text-xs text-base-content/50 lg:inline" title="Cards shown">
          {@grid.shown} {if @grid.shown == 1, do: "card", else: "cards"}<span :if={@grid.hidden > 0}> · {@grid.hidden} hidden</span>
        </span>

        <.view_controls
          board={@board}
          mode={@mode}
          view={@view}
          dirty={@dirty}
          can_write={@can_write}
          can_manage={@can_manage}
          view_only={@view_only}
          view_grants={@view_grants}
          groups={@groups}
          share_key={@share_key}
          form_key={@form_key}
          favourites={@favourites}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true, doc: "the box's id; its button's is this plus `-toggle`"
  attr :q, :string, default: nil, doc: "the current query: a box with one in it stays open"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc """
  A toolbar's search box which, on a phone, folds away behind a one-tap
  magnifying glass: a full-width input is a whole row of a toolbar on a
  screen with room for a few. Tapping it opens the box and puts the cursor
  in it. A box with a query in it is never folded, so a filter is never
  hidden. From `sm` up the box is simply there and the button is gone.
  """
  def search_box(assigns) do
    open =
      JS.add_class("search-open", to: "##{assigns.id}")
      |> JS.hide(to: "##{assigns.id}-toggle")
      |> JS.focus(to: "##{assigns.id} input")

    assigns = assign(assigns, open: open, query?: assigns.q not in [nil, ""])

    ~H"""
    <button
      :if={!@query?}
      id={"#{@id}-toggle"}
      type="button"
      phx-click={@open}
      class="btn btn-ghost btn-sm btn-square shrink-0 sm:hidden"
      title="Search cards"
      aria-label="Search cards"
      aria-controls={@id}
    >
      <.icon name="hero-magnifying-glass" class="size-5" />
    </button>
    <div id={@id} class={["search-box", @query? && "search-open", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :target, :string, required: true, doc: "the `.tools` group this button opens"

  @doc false
  # The "Options" button: on a phone it reveals the toolbar's second rank of
  # controls, which would otherwise be four rows of selects above a board you
  # are trying to read. Client-side — which controls are showing is no
  # business of the server's, and a round trip per tap would feel like one.
  defp tools_toggle(assigns) do
    click =
      JS.toggle_class("tools-open", to: assigns.target)
      |> JS.toggle_class("btn-active", to: "#tools-toggle")

    assigns = assign(assigns, click: click)

    ~H"""
    <button
      id="tools-toggle"
      type="button"
      phx-click={@click}
      class="btn btn-ghost btn-sm btn-square shrink-0 sm:hidden"
      title="More view options"
      aria-label="More view options"
    >
      <.icon name="hero-adjustments-horizontal" class="size-4" />
    </button>
    """
  end

  attr :mode, :atom, required: true
  attr :config, Config, required: true

  @doc """
  The Display dropdown: card size, then what a card shows (or which columns a
  table has) at that size. Comfortable and compact each keep their own set,
  so the chooser edits the one currently in use.
  """
  attr :board, :any, default: %{}

  def display_menu(assigns) do
    compact? = assigns.config.density == "compact"

    assigns =
      assign(assigns,
        section_title: @section_title,
        compact?: compact?,
        size_label: if(compact?, do: "compact", else: "comfortable"),
        facets:
          Enum.reject(Config.facets(assigns.mode), fn {k, _} -> k in assigns.config.hidden end),
        shown: Config.shown(assigns.config),
        table_fields: Config.table_fields(assigns.config)
      )

    ~H"""
    <div id="display-menu" class="dropdown" phx-hook="DropdownAlign">
      <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-1" title="Display options">
        <.icon name="hero-adjustments-horizontal" class="size-4" /> Display
      </div>
      <div
        tabindex="0"
        class="dropdown-content z-30 mt-2 w-72 max-w-[calc(100vw-1rem)] space-y-4 rounded-2xl bg-base-100 p-4 shadow-xl ring-1 ring-base-content/10"
      >
        <div :if={@mode != :narrative}>
          <p class={["mb-1.5", @section_title]}>Card size</p>
          <div class="flex gap-1">
            <label :for={{value, label} <- Config.densities()} class="cursor-pointer">
              <input
                type="radio"
                name="density"
                value={value}
                checked={@config.density == value}
                class="peer sr-only"
              />
              <span class="btn btn-xs btn-ghost peer-checked:btn-primary">{label}</span>
            </label>
          </div>
        </div>
        <div :if={@mode == :calendar}>
          <p class={["mb-1.5", @section_title]}>Place cards on</p>
          <div class="flex gap-1">
            <label :for={{value, label} <- Slipdock.Calendar.places()} class="cursor-pointer">
              <input
                type="radio"
                name="place"
                value={value}
                checked={Slipdock.Calendar.place(@config) == value}
                class="peer sr-only"
              />
              <span class="btn btn-xs btn-ghost peer-checked:btn-primary">{label}</span>
            </label>
          </div>
          <p class="mt-1 text-xs text-base-content/60">
            A card with only one date sits on that date either way.
          </p>
        </div>
        <div :if={@mode in [:timeline, :swimlanes]}>
          <p class={["mb-1.5", @section_title]}>Colour by</p>
          <select name="color_by" class="select select-sm w-full" title="What colours each card">
            <option
              :for={{key, label} <- Config.colorings()}
              value={key}
              selected={@config.color_by == key}
            >
              {label}
            </option>
          </select>
        </div>
        <div :if={@mode == :table} id={"display-fields-#{@size_label}"}>
          <p class={["mb-1.5", @section_title]}>Columns · {@size_label}</p>
          <input
            type="hidden"
            name={if @compact?, do: "fields_compact[]", else: "fields[]"}
            value="title"
          />
          <div class="grid grid-cols-2 gap-x-2 gap-y-1">
            <label
              :for={{key, label, _} <- Table.fields(@board)}
              :if={key != "title"}
              class="flex cursor-pointer items-center gap-2 text-sm"
            >
              <input
                type="checkbox"
                name={if @compact?, do: "fields_compact[]", else: "fields[]"}
                value={key}
                checked={key in @table_fields}
                class="checkbox checkbox-xs"
              />
              {label}
            </label>
          </div>
          <p class="mt-1.5 text-xs text-base-content/60">
            Comfortable and compact tables each keep their own columns.
          </p>
        </div>
        <div :if={@mode == :narrative} id="display-tell">
          <p class={["mb-1.5", @section_title]}>Tell</p>
          <input type="hidden" name="tell[]" value="" />
          <div class="grid grid-cols-2 gap-x-2 gap-y-1">
            <label
              :for={{key, label} <- Config.tell_events()}
              class={[
                "flex cursor-pointer items-center gap-2 text-sm",
                key == "comment_text" && "pl-5"
              ]}
            >
              <input
                type="checkbox"
                name="tell[]"
                value={key}
                checked={key in @config.tell}
                class="checkbox checkbox-xs"
              />
              {label}
            </label>
          </div>
          <p class={["mb-1.5 mt-3", @section_title]}>Also show</p>
          <div class="grid grid-cols-1 gap-y-1">
            <label
              :for={{key, label} <- Config.tell_sections()}
              class="flex cursor-pointer items-center gap-2 text-sm"
            >
              <input
                type="checkbox"
                name="tell[]"
                value={key}
                checked={key in @config.tell}
                class="checkbox checkbox-xs"
              />
              {label}
            </label>
          </div>
        </div>
        <div :if={not Enum.member?([:table, :narrative], @mode)} id={"display-show-#{@size_label}"}>
          <p class={["mb-1.5", @section_title]}>Show on cards · {@size_label}</p>
          <input type="hidden" name={if @compact?, do: "show_compact[]", else: "show[]"} value="" />
          <div class="grid grid-cols-2 gap-x-2 gap-y-1">
            <label
              :for={{key, label} <- @facets}
              class="flex cursor-pointer items-center gap-2 text-sm"
            >
              <input
                type="checkbox"
                name={if @compact?, do: "show_compact[]", else: "show[]"}
                value={key}
                checked={MapSet.member?(@shown, key)}
                class="checkbox checkbox-xs"
              />
              {label}
            </label>
          </div>
          <p class="mt-1.5 text-xs text-base-content/60">
            Comfortable and compact cards each keep their own set.
          </p>
        </div>
        <label
          :if={not Enum.member?([:board, :calendar, :outline], @mode)}
          class="flex cursor-pointer items-center gap-2"
        >
          <input type="hidden" name="empty" value="hide" />
          <input
            type="checkbox"
            name="empty"
            value="show"
            checked={@config.empty == "show"}
            class="toggle toggle-sm"
          />
          <span>
            Show empty groups
            <span class="block text-xs text-base-content/50">Also fills gaps between dates</span>
          </span>
        </label>
      </div>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :view, :any, default: nil
  attr :dirty, :boolean, default: false
  attr :can_write, :boolean, default: true
  attr :can_manage, :boolean, default: false
  attr :view_only, :boolean, default: false
  attr :view_grants, :list, default: []
  attr :groups, :list, default: []
  attr :share_key, :integer, default: 0
  attr :form_key, :integer, required: true
  attr :mode, :atom, default: :swimlanes, doc: "the mode whose defaults Reset returns to"

  attr :favourites, :any,
    default: nil,
    doc: "the reader's favourites, from `Slipdock.Favourites.marks/1`"

  @doc "The loaded-view pill (with update/revert) and the Views dropdown."
  def view_controls(assigns) do
    assigns = assign(assigns, section_title: @section_title)

    ~H"""
    <div
      :if={@view}
      class="flex items-center gap-1 rounded-full bg-base-200 py-0.5 pl-3 pr-1 text-xs"
    >
      <.icon name="hero-bookmark-solid" class="size-3.5 text-primary" />
      <span class="max-w-40 truncate font-medium">{@view.name}</span>
      <span :if={@dirty} class="badge badge-warning badge-xs">modified</span>
      <button
        :if={@dirty and @can_write}
        type="button"
        class="btn btn-primary btn-xs"
        phx-click="swim_update_view"
        title="Save these settings to the view"
      >
        Update
      </button>
      <.link
        :if={@dirty}
        patch={view_path(@board, @view)}
        class="btn btn-ghost btn-xs"
        title="Discard changes"
      >
        Revert
      </.link>
    </div>

    <div :if={!@view_only} class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-1" title="Saved views">
        <.icon name="hero-bookmark" class="size-4" />
        <span class="hidden sm:inline">Views</span>
        <.icon name="hero-chevron-down" class="size-3" />
      </div>
      <div
        tabindex="0"
        class="dropdown-content z-30 mt-2 w-72 space-y-3 rounded-2xl bg-base-100 p-3 shadow-xl ring-1 ring-base-content/10"
      >
        <p :if={@board.saved_views == []} class="px-1 text-xs text-base-content/60">
          No saved views yet. Configure the grid, then save it below.
        </p>
        <ul :if={@board.saved_views != []} class="menu p-0 text-sm">
          <li :for={v <- @board.saved_views} class="flex-row items-center">
            <.link
              patch={view_path(@board, v)}
              class={["min-w-0 flex-1", @view && @view.id == v.id && "menu-active"]}
            >
              <.icon name={mode_icon(v.config["mode"])} class="size-4 shrink-0" />
              <span class="truncate">{v.name}</span>
            </.link>
            <.favourite_toggle kind="view" id={v.id} name={v.name} marks={@favourites} class="p-1.5" />
          </li>
        </ul>
        <.link
          patch={view_mode_path(@board, @mode)}
          class="btn btn-ghost btn-xs w-full justify-start gap-1.5 font-normal"
          title="Put every option back to this view's defaults"
        >
          <.icon name="hero-arrow-uturn-left" class="size-3.5" /> Reset to defaults
        </.link>
        <div
          :if={@can_manage and not is_nil(@view)}
          class="space-y-2 border-t border-base-content/10 pt-3"
        >
          <p class={["px-1", @section_title]}>Share “{@view.name}”</p>
          <p class="px-1 text-xs text-base-content/50">
            People who only have this view see the cards it selects, nothing else.
          </p>
          <.share_panel
            resource="view"
            grants={@view_grants}
            groups={@groups}
            can_manage={true}
            form_key={@share_key}
            compact
          />
          <div class="space-y-1 px-1 pt-1">
            <p class={@section_title}>Public link</p>
            <button
              :if={is_nil(@view.public_token)}
              type="button"
              class="btn btn-xs gap-1"
              phx-click="swim_publish_view"
              title="Anyone with the link can read this view, without signing in"
            >
              <.icon name="hero-globe-alt" class="size-3.5" /> Publish read-only link
            </button>
            <div :if={@view.public_token} class="flex items-center gap-1">
              <input
                type="text"
                readonly
                value={url(~p"/p/#{@view.public_token}")}
                class="input input-xs min-w-0 flex-1 font-mono"
                onclick="this.select()"
                aria-label="Public link"
              />
              <a
                href={~p"/p/#{@view.public_token}"}
                target="_blank"
                class="btn btn-ghost btn-xs btn-square"
                title="Open the public page"
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
              </a>
              <button
                type="button"
                class="btn btn-ghost btn-xs text-error"
                phx-click="swim_unpublish_view"
                data-confirm="Withdraw the public link? Anyone using it will lose access."
              >
                Unpublish
              </button>
            </div>
            <p :if={@view.public_token} class="text-xs text-base-content/50">
              Readers see the cards this view selects, live, and nothing else.
            </p>
          </div>
        </div>
        <div
          :if={@can_write and not is_nil(@view)}
          class="space-y-2 border-t border-base-content/10 pt-3"
        >
          <p class={["px-1", @section_title]}>Current view</p>
          <form phx-submit="swim_rename_view" class="flex gap-1">
            <input
              type="text"
              name="name"
              value={@view.name}
              class="input input-xs flex-1"
              aria-label="View name"
              required
            />
            <button type="submit" class="btn btn-xs">Rename</button>
          </form>
          <div class="flex items-center gap-1">
            <button
              :if={@dirty}
              type="button"
              class="btn btn-primary btn-xs"
              phx-click="swim_update_view"
            >
              Update with current settings
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              phx-click="swim_delete_view"
              data-confirm={"Delete view “#{@view.name}”?"}
            >
              <.icon name="hero-trash" class="size-3.5" /> Delete
            </button>
          </div>
        </div>
        <form
          :if={@can_write}
          id={"swim-save-view-#{@form_key}"}
          phx-submit="swim_save_view"
          class="space-y-2 border-t border-base-content/10 pt-3"
        >
          <p class={["px-1", @section_title]}>Save current settings as a view</p>
          <div class="flex gap-1">
            <input
              type="text"
              name="name"
              placeholder="View name"
              class="input input-xs flex-1"
              autocomplete="off"
              required
            />
            <button type="submit" class="btn btn-primary btn-xs">Save</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  @doc "The URL that opens a saved view in the mode it was saved from."
  def view_path(board, view), do: view_mode_path(board, view.config["mode"], view: view.id)

  @doc """
  The URL of a view mode (an atom or the string stored in a saved view) with
  a query; with none, the mode at its defaults.
  """
  def view_mode_path(board, mode, query \\ [])

  def view_mode_path(board, mode, query) when is_atom(mode),
    do: view_mode_path(board, Atom.to_string(mode), query)

  def view_mode_path(board, "board", query), do: ~p"/boards/#{board}?#{query}"
  def view_mode_path(board, "table", query), do: ~p"/boards/#{board}/table?#{query}"
  def view_mode_path(board, "outline", query), do: ~p"/boards/#{board}/outline?#{query}"
  def view_mode_path(board, "narrative", query), do: ~p"/boards/#{board}/narrative?#{query}"
  def view_mode_path(board, "prioritise", query), do: ~p"/boards/#{board}/prioritise?#{query}"
  def view_mode_path(board, "timeline", query), do: ~p"/boards/#{board}/timeline?#{query}"
  def view_mode_path(board, "calendar", query), do: ~p"/boards/#{board}/calendar?#{query}"
  def view_mode_path(board, _, query), do: ~p"/boards/#{board}/swimlanes?#{query}"

  @doc "The icon for a view mode (an atom or the string stored in a saved view)."
  def mode_icon(mode) when is_atom(mode), do: mode |> Atom.to_string() |> mode_icon()
  def mode_icon("table"), do: "hero-table-cells"
  def mode_icon("timeline"), do: "hero-chart-bar"
  def mode_icon("calendar"), do: "hero-calendar-days"
  def mode_icon("board"), do: "hero-view-columns"
  def mode_icon("outline"), do: "hero-queue-list"
  def mode_icon("narrative"), do: "hero-book-open"
  def mode_icon(_), do: "hero-squares-2x2"

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true

  attr :board, :any, default: %{}

  defp axis_select(assigns) do
    ~H"""
    <label class="flex items-center gap-1.5">
      <.icon name={@icon} class="size-4 text-base-content/50" />
      <span class="text-xs text-base-content/60">{@label}</span>
      <select name={@name} class="select select-sm w-auto" title={"#{@label} axis"}>
        <option :for={{value, label} <- Config.axes(@board)} value={value} selected={value == @value}>
          {label}
        </option>
      </select>
    </label>
    """
  end

  ## Grid ------------------------------------------------------------------

  attr :board, :any, required: true
  attr :grid, :map, required: true
  attr :config, Config, required: true
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed row keys"
  attr :adding, :string, default: nil, doc: "the cell (\"row:col\") with an open quick-add form"
  attr :form_key, :integer, required: true
  attr :can_write, :boolean, default: true
  attr :narrow, :boolean, default: false, doc: "stack the grid instead of laying it out"

  def swim_grid(%{narrow: true} = assigns), do: swim_stack(assigns)

  def swim_grid(assigns) do
    assigns =
      assign(assigns,
        show: Config.shown(assigns.config),
        row_headers?: assigns.config.rows != "none",
        col_headers?: assigns.config.cols != "none",
        can_add?:
          assigns.can_write and Config.movable?(assigns.config.rows) and
            Config.movable?(assigns.config.cols),
        template: grid_template(assigns.grid, assigns.config)
      )

    ~H"""
    <div id="swim-scroll" class="kanban-scroll h-full overflow-auto">
      <div
        :if={@grid.rows == [] or @grid.cols == []}
        class="flex h-full flex-col items-center justify-center gap-2 p-8 text-center text-base-content/60"
      >
        <.icon name="hero-table-cells" class="size-10 opacity-40" />
        <p :if={@grid.shown == 0 and @grid.hidden > 0}>No cards match the current filters.</p>
        <p :if={@grid.shown == 0 and @grid.hidden == 0}>This board has no cards yet.</p>
        <p :if={@grid.shown > 0}>Nothing to show on these axes.</p>
        <button
          :if={Config.filtering?(@config)}
          type="button"
          class="btn btn-sm"
          phx-click="swim_clear_filters"
        >
          Clear filters
        </button>
      </div>

      <div
        :if={@grid.rows != [] and @grid.cols != []}
        id="swim-grid"
        class="swim-grid"
        style={@template}
      >
        <%= if @col_headers? do %>
          <div
            :if={@row_headers?}
            class="sticky left-0 top-0 z-30 border-b border-r border-base-300 bg-base-100"
          >
          </div>
          <div
            :for={col <- @grid.cols}
            class={[
              "sticky top-0 z-20 flex items-center gap-2 border-b border-r border-base-300 bg-base-100 px-3 py-2",
              header_tone(col.tone)
            ]}
          >
            <span :if={col.color} class={["size-2.5 shrink-0 rounded-full", Palette.dot(col.color)]}></span>
            <span class="truncate text-sm font-semibold" title={col.label}>{col.label}</span>
            <span :if={col.tone == :current} class="badge badge-primary badge-xs">now</span>
            <span class="badge badge-ghost badge-sm ml-auto font-mono">{col.count}</span>
          </div>
        <% end %>

        <%= for {row, ri} <- Enum.with_index(@grid.rows) do %>
          <% collapsed = MapSet.member?(@collapsed, row.key) %>
          <div
            :if={@row_headers?}
            class={[
              "sticky left-0 z-10 border-b border-r border-base-300 bg-base-100",
              header_tone(row.tone)
            ]}
            style={collapsed && "grid-column: 1 / -1"}
          >
            <button
              type="button"
              class="flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-base-200/60"
              phx-click="swim_toggle_row"
              phx-value-key={row.key}
              title={if collapsed, do: "Expand row", else: "Collapse row"}
            >
              <.icon
                name={if collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
                class="size-3.5 shrink-0 text-base-content/50"
              />
              <span :if={row.color} class={["size-2.5 shrink-0 rounded-full", Palette.dot(row.color)]}></span>
              <span class="truncate text-sm font-semibold" title={row.label}>{row.label}</span>
              <span :if={row.tone == :current} class="badge badge-primary badge-xs">now</span>
              <span class="badge badge-ghost badge-sm ml-auto font-mono">{row.count}</span>
            </button>
          </div>

          <%= if not collapsed do %>
            <div
              :for={{cards, ci} <- Enum.with_index(row.cells)}
              id={"swim-cell-#{ri}-#{ci}"}
              data-id={"#{ri}:#{ci}"}
              phx-hook="Sortable"
              data-group="swim"
              data-draggable=".kanban-card"
              data-event="swim_move"
              data-disabled={to_string(!@can_write)}
              class="swim-cell group/cell space-y-2 border-b border-r border-base-300/70 bg-base-200/40 p-2"
            >
              <.card
                :for={card <- cards}
                card={card}
                id={"swim-#{ri}-#{ci}-card-#{card.id}"}
                compact={@config.density == "compact"}
                show={@show}
                cover={Slipdock.Coloring.color(card, @config.color_by, @board)}
              />
              <form
                :if={@adding == "#{ri}:#{ci}"}
                id={"swim-add-#{ri}-#{ci}-#{@form_key}"}
                phx-submit="swim_quick_add"
                class="kanban-pop space-y-2"
              >
                <input type="hidden" name="cell" value={"#{ri}:#{ci}"} />
                <input
                  type="text"
                  name="title"
                  placeholder="Card title, then Enter"
                  class="input input-sm w-full"
                  phx-hook="Focus"
                  id={"swim-add-input-#{ri}-#{ci}-#{@form_key}"}
                  phx-window-keydown="swim_cancel_add"
                  phx-key="Escape"
                  autocomplete="off"
                  required
                />
                <div class="flex items-center gap-1">
                  <button type="submit" class="btn btn-primary btn-xs">Add card</button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="swim_cancel_add"
                  >
                    <.icon name="hero-x-mark" class="size-3.5" />
                  </button>
                </div>
              </form>
              <button
                :if={@can_add? and @adding != "#{ri}:#{ci}"}
                type="button"
                class="btn btn-ghost btn-xs w-full justify-start text-base-content/50 opacity-0 transition group-hover/cell:opacity-100 focus:opacity-100 no-hover:opacity-100"
                phx-click="swim_start_add"
                phx-value-cell={"#{ri}:#{ci}"}
              >
                <.icon name="hero-plus" class="size-3.5" /> Add
              </button>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # The swimlane grid as a phone reads it: stacked, not crossed.
  #
  # A matrix wants both axes on screen at once, and a phone has room for
  # neither — a 13rem row header plus one 17rem cell is already wider than
  # the device, so the desktop grid shows you a column of labels next to a
  # column of nothing. Stacked, the two axes become nesting: each row is a
  # section you can collapse, each column a heading inside it.
  #
  # Every cell keeps its `swim-cell-<ri>-<ci>` id, its `data-id` of
  # "ri:ci", its sortable and its quick-add form, so dragging a card between
  # cells and adding one to a cell work exactly as they do on the grid.
  defp swim_stack(assigns) do
    assigns =
      assign(assigns,
        show: Config.shown(assigns.config),
        row_headers?: assigns.config.rows != "none",
        col_headers?: assigns.config.cols != "none",
        can_add?:
          assigns.can_write and Config.movable?(assigns.config.rows) and
            Config.movable?(assigns.config.cols)
      )

    ~H"""
    <div id="swim-scroll" class="kanban-scroll h-full overflow-y-auto">
      <div
        :if={@grid.rows == [] or @grid.cols == []}
        class="flex h-full flex-col items-center justify-center gap-2 p-8 text-center text-base-content/60"
      >
        <.icon name="hero-table-cells" class="size-10 opacity-40" />
        <p :if={@grid.shown == 0 and @grid.hidden > 0}>No cards match the current filters.</p>
        <p :if={@grid.shown == 0 and @grid.hidden == 0}>This board has no cards yet.</p>
        <p :if={@grid.shown > 0}>Nothing to show on these axes.</p>
        <button
          :if={Config.filtering?(@config)}
          type="button"
          class="btn btn-sm"
          phx-click="swim_clear_filters"
        >
          Clear filters
        </button>
      </div>

      <div :if={@grid.rows != [] and @grid.cols != []} id="swim-grid">
        <%= for {row, ri} <- Enum.with_index(@grid.rows) do %>
          <% collapsed = @row_headers? and MapSet.member?(@collapsed, row.key) %>
          <section class="border-b border-base-300">
            <button
              :if={@row_headers?}
              type="button"
              class={[
                "sticky top-0 z-20 flex w-full items-center gap-2 border-b border-base-300 bg-base-100 px-3 py-2 text-left",
                header_tone(row.tone)
              ]}
              phx-click="swim_toggle_row"
              phx-value-key={row.key}
              aria-expanded={to_string(!collapsed)}
            >
              <.icon
                name={if collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
                class="size-4 shrink-0 text-base-content/50"
              />
              <span :if={row.color} class={["size-2.5 shrink-0 rounded-full", Palette.dot(row.color)]}></span>
              <span class="truncate text-sm font-semibold">{row.label}</span>
              <span :if={row.tone == :current} class="badge badge-primary badge-xs">now</span>
              <span class="badge badge-ghost badge-sm ml-auto font-mono">{row.count}</span>
            </button>

            <div :if={not collapsed} class="divide-y divide-base-300/60">
              <div
                :for={{cards, ci} <- Enum.with_index(row.cells)}
                :if={cards != [] or @can_add?}
                class="bg-base-200/40 px-2 py-2"
              >
                <% col = Enum.at(@grid.cols, ci) %>
                <div
                  :if={@col_headers? and col}
                  class={["mb-1.5 flex items-center gap-1.5 px-1", header_tone(col.tone)]}
                >
                  <span
                    :if={col.color}
                    class={["size-2 shrink-0 rounded-full", Palette.dot(col.color)]}
                  ></span>
                  <span class="truncate text-2xs font-semibold uppercase tracking-wide text-base-content/60">
                    {col.label}
                  </span>
                  <span :if={col.tone == :current} class="badge badge-primary badge-xs">now</span>
                  <span class="ml-auto font-mono text-2xs text-base-content/40">{length(cards)}</span>
                </div>

                <div
                  id={"swim-cell-#{ri}-#{ci}"}
                  data-id={"#{ri}:#{ci}"}
                  phx-hook="Sortable"
                  data-group="swim"
                  data-draggable=".kanban-card"
                  data-event="swim_move"
                  data-disabled={to_string(!@can_write)}
                  class="swim-cell swim-cell-stacked space-y-2"
                >
                  <.card
                    :for={card <- cards}
                    card={card}
                    id={"swim-#{ri}-#{ci}-card-#{card.id}"}
                    compact={@config.density == "compact"}
                    show={@show}
                    cover={Slipdock.Coloring.color(card, @config.color_by, @board)}
                  />
                </div>

                <form
                  :if={@adding == "#{ri}:#{ci}"}
                  id={"swim-add-#{ri}-#{ci}-#{@form_key}"}
                  phx-submit="swim_quick_add"
                  class="kanban-pop mt-2 space-y-2"
                >
                  <input type="hidden" name="cell" value={"#{ri}:#{ci}"} />
                  <input
                    type="text"
                    name="title"
                    placeholder="Card title, then Enter"
                    class="input input-sm w-full"
                    phx-hook="Focus"
                    id={"swim-add-input-#{ri}-#{ci}-#{@form_key}"}
                    phx-window-keydown="swim_cancel_add"
                    phx-key="Escape"
                    autocomplete="off"
                    required
                  />
                  <div class="flex items-center gap-1">
                    <button type="submit" class="btn btn-primary btn-xs">Add card</button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs btn-square"
                      phx-click="swim_cancel_add"
                    >
                      <.icon name="hero-x-mark" class="size-3.5" />
                    </button>
                  </div>
                </form>
                <button
                  :if={@can_add? and @adding != "#{ri}:#{ci}"}
                  type="button"
                  class="btn btn-ghost btn-xs mt-1 w-full justify-start text-base-content/50"
                  phx-click="swim_start_add"
                  phx-value-cell={"#{ri}:#{ci}"}
                >
                  <.icon name="hero-plus" class="size-3.5" /> Add
                </button>
              </div>
            </div>
          </section>
        <% end %>
      </div>
    </div>
    """
  end

  defp grid_template(grid, config) do
    row_header = if config.rows != "none", do: "13rem ", else: ""
    cell = if config.density == "compact", do: "minmax(15rem, 1fr)", else: "minmax(17rem, 1fr)"
    "grid-template-columns: #{row_header}repeat(#{length(grid.cols)}, #{cell});"
  end

  defp header_tone(:current), do: "border-t-2 border-t-primary text-primary"
  defp header_tone(:past), do: "text-error/80"
  defp header_tone(_), do: nil

  defp depth_int("all"), do: 1
  defp depth_int(d), do: String.to_integer(d)
end
