defmodule SlipdockWeb.CalendarComponents do
  @moduledoc """
  The calendar view of a board: a month or week of days with a chip per card,
  drag and drop between days, quick add on a day, and the tray of undated cards.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.TimelineComponents, only: [dateless_tray: 1]
  alias Slipdock.Palette
  alias Slipdock.Swimlanes.Config

  attr :board, :any, required: true
  attr :config, Config, required: true
  attr :calendar, :map, required: true, doc: "from Slipdock.Calendar.build/3"
  attr :expanded, :any, required: true, doc: "MapSet of day keys showing every card"
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed group keys (the tray)"
  attr :adding, :string, default: nil, doc: "the day key with an open quick-add form"
  attr :form_key, :integer, required: true
  attr :can_write, :boolean, default: true
  attr :narrow, :boolean, default: false, doc: "render the phone's agenda instead of the grid"

  def calendar_view(%{narrow: true} = assigns), do: calendar_agenda(assigns)

  def calendar_view(assigns) do
    compact? = assigns.config.density == "compact"

    assigns =
      assign(assigns,
        compact?: compact?,
        limit: if(compact?, do: 8, else: 4),
        week?: assigns.calendar.unit == "week",
        start?: assigns.calendar.place == "start",
        show: Config.shown(assigns.config),
        first_column: List.first(assigns.board.columns)
      )

    ~H"""
    <div class="flex h-full flex-col">
      <div id="calendar-scroll" class="kanban-scroll min-h-0 flex-1 overflow-auto">
        <div
          id="calendar"
          class="grid min-w-[52rem]"
          style={
            "grid-template-columns: repeat(7, minmax(0, 1fr)); " <>
              "grid-template-rows: auto repeat(#{length(@calendar.weeks)}, minmax(#{if @week?, do: "22rem", else: "6.5rem"}, 1fr)); " <>
              "min-height: 100%;"
          }
        >
          <div
            :for={name <- @calendar.weekdays}
            class="sticky top-0 z-20 border-b border-r border-base-300 bg-base-100 px-2 py-1.5 text-center text-xs font-semibold uppercase tracking-wide text-base-content/60"
          >
            {name}
          </div>

          <%= for week <- @calendar.weeks, day <- week do %>
            <% expanded = MapSet.member?(@expanded, day.key) %>
            <% visible = if expanded, do: day.cards, else: Enum.take(day.cards, @limit) %>
            <% more = length(day.cards) - length(visible) %>
            <div
              id={"cal-day-#{day.key}"}
              class={[
                "cal-day group/day flex min-h-0 flex-col border-b border-r border-base-300/70 p-1.5",
                !day.in_period? && "bg-base-200/40 text-base-content/40",
                day.today? && "bg-primary/5"
              ]}
            >
              <div class="mb-1 flex items-center justify-between">
                <span
                  class={[
                    "flex h-6 min-w-6 items-center justify-center whitespace-nowrap rounded-full px-1.5 text-xs font-semibold",
                    day.today? && "bg-primary text-primary-content",
                    (!day.today? and day.date.day == 1) && "text-base-content"
                  ]}
                  title={Calendar.strftime(day.date, "%A, %-d %B %Y")}
                >
                  {if day.date.day == 1 and not @week?,
                    do: Calendar.strftime(day.date, "%-d %b"),
                    else: day.date.day}
                </span>
                <button
                  :if={@can_write and @adding != day.key and not is_nil(@first_column)}
                  type="button"
                  class="btn btn-ghost btn-xs btn-square opacity-0 transition group-hover/day:opacity-100 focus:opacity-100 no-hover:opacity-100"
                  phx-click="swim_start_add"
                  phx-value-cell={day.key}
                  title={"Add a card #{if @start?, do: "starting", else: "due"} #{Calendar.strftime(day.date, "%-d %b")}"}
                >
                  <.icon name="hero-plus" class="size-3.5" />
                </button>
              </div>
              <div
                :for={m <- Map.get(@calendar.milestones, day.key, [])}
                class="mb-1 flex items-center gap-1.5 truncate text-2xs font-semibold"
                title={"Milestone: #{m.name}"}
              >
                <span class={["size-2 shrink-0 rotate-45", Palette.dot(m.color || "indigo")]}></span>
                <span class="truncate">{m.name}</span>
              </div>
              <div
                id={"cal-cards-#{day.key}"}
                data-id={day.key}
                phx-hook="Sortable"
                data-group="cal"
                data-event="cal_move"
                data-draggable=".cal-chip"
                data-disabled={to_string(!@can_write)}
                class="cal-cards min-h-6 flex-1 space-y-1"
              >
                <.chip
                  :for={card <- visible}
                  card={card}
                  day={day}
                  compact={@compact?}
                  start={@start?}
                  show={@show}
                  can_write={@can_write}
                />
              </div>
              <button
                :if={more > 0 or (expanded and length(day.cards) > @limit)}
                type="button"
                class="mt-1 self-start text-2xs font-medium text-primary hover:underline"
                phx-click="cal_toggle_day"
                phx-value-key={day.key}
              >
                {if expanded, do: "Show less", else: "+#{more} more"}
              </button>
              <form
                :if={@adding == day.key}
                id={"cal-add-#{day.key}-#{@form_key}"}
                phx-submit="cal_quick_add"
                class="kanban-pop mt-1 space-y-1"
              >
                <input type="hidden" name="date" value={day.key} />
                <input
                  type="text"
                  name="title"
                  placeholder="Card title, then Enter"
                  class="input input-xs w-full"
                  phx-hook="Focus"
                  id={"cal-add-input-#{day.key}-#{@form_key}"}
                  phx-window-keydown="swim_cancel_add"
                  phx-key="Escape"
                  autocomplete="off"
                  required
                />
                <div class="flex items-center gap-1">
                  <button type="submit" class="btn btn-primary btn-xs">Add</button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="swim_cancel_add"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </div>
              </form>
            </div>
          <% end %>
        </div>
      </div>

      <div
        :if={@calendar.shown == 0}
        class="flex flex-col items-center gap-2 border-t border-base-300 p-4 text-center text-sm text-base-content/60"
      >
        <p :if={@calendar.hidden > 0}>No cards match the current filters.</p>
        <p :if={@calendar.hidden == 0}>This board has no cards yet.</p>
        <button
          :if={Config.filtering?(@config)}
          type="button"
          class="btn btn-sm"
          phx-click="swim_clear_filters"
        >
          Clear filters
        </button>
      </div>

      <.dateless_tray
        :if={@calendar.undated != []}
        cards={@calendar.undated}
        collapsed={MapSet.member?(@collapsed, "unscheduled")}
        can_write={@can_write}
        label="No date"
        hint={"Drag a card onto a day, or pick a #{if @start?, do: "start", else: "due"} date."}
        drag={:calendar}
      />
    </div>
    """
  end

  # The calendar as a phone reads it: an agenda, not a grid.

  #
  # Seven columns across 390 points gives each day 50 — too narrow for a
  # date, let alone a card — so the month is turned on its side. Days run
  # down the page, only the ones with something on them (and today, always,
  # so there is somewhere to add to), and each card gets a full-width row it
  # can actually be read and tapped on.
  #
  # Every day keeps its `cal-cards-<key>` sortable and its quick-add form, so
  # dragging a card from one day to another and adding one to a day work
  # exactly as they do on the grid — the same events, the same keys.
  defp calendar_agenda(assigns) do
    days =
      for week <- assigns.calendar.weeks,
          day <- week,
          day.in_period? and (day.cards != [] or day.today? or milestones?(assigns, day)),
          do: day

    assigns =
      assign(assigns,
        days: days,
        start?: assigns.calendar.place == "start",
        show: Config.shown(assigns.config),
        first_column: List.first(assigns.board.columns)
      )

    ~H"""
    <div class="flex h-full flex-col">
      <div id="calendar-scroll" class="kanban-scroll min-h-0 flex-1 overflow-y-auto">
        <div id="calendar" class="divide-y divide-base-300/70">
          <section
            :for={day <- @days}
            id={"cal-day-#{day.key}"}
            class={["px-3 py-2.5", day.today? && "bg-primary/5"]}
          >
            <div class="mb-1.5 flex items-center gap-2">
              <h3 class={[
                "text-sm font-semibold",
                day.past? && !day.today? && "text-base-content/50"
              ]}>
                <span :if={day.today?} class="text-primary">Today · </span>
                {Calendar.strftime(day.date, "%a %-d %b")}
              </h3>
              <span
                :if={day.cards != []}
                class="font-mono text-2xs text-base-content/40"
                title={"#{length(day.cards)} cards"}
              >
                {length(day.cards)}
              </span>
              <button
                :if={@can_write and @adding != day.key and not is_nil(@first_column)}
                type="button"
                class="btn btn-ghost btn-xs btn-square ml-auto"
                phx-click="swim_start_add"
                phx-value-cell={day.key}
                title={"Add a card #{if @start?, do: "starting", else: "due"} #{Calendar.strftime(day.date, "%-d %b")}"}
              >
                <.icon name="hero-plus" class="size-4" />
              </button>
            </div>

            <div
              :for={m <- Map.get(@calendar.milestones, day.key, [])}
              class="mb-1.5 flex items-center gap-1.5 text-xs font-semibold"
              title={"Milestone: #{m.name}"}
            >
              <span class={["size-2 shrink-0 rotate-45", Palette.dot(m.color || "indigo")]}></span>
              <span class="truncate">{m.name}</span>
            </div>

            <div
              id={"cal-cards-#{day.key}"}
              data-id={day.key}
              phx-hook="Sortable"
              data-group="cal"
              data-event="cal_move"
              data-draggable=".cal-chip"
              data-disabled={to_string(!@can_write)}
              class="cal-cards min-h-2 space-y-1.5"
            >
              <.chip
                :for={card <- day.cards}
                card={card}
                day={day}
                compact={false}
                start={@start?}
                show={@show}
                can_write={@can_write}
              />
            </div>
            <p :if={day.cards == [] and day.today?} class="text-xs text-base-content/45">
              Nothing scheduled today.
            </p>

            <form
              :if={@adding == day.key}
              id={"cal-add-#{day.key}-#{@form_key}"}
              phx-submit="cal_quick_add"
              class="kanban-pop mt-1.5 space-y-1"
            >
              <input type="hidden" name="date" value={day.key} />
              <input
                type="text"
                name="title"
                placeholder="Card title, then Enter"
                class="input input-sm w-full"
                phx-hook="Focus"
                id={"cal-add-input-#{day.key}-#{@form_key}"}
                phx-window-keydown="swim_cancel_add"
                phx-key="Escape"
                autocomplete="off"
                required
              />
              <div class="flex items-center gap-1">
                <button type="submit" class="btn btn-primary btn-xs">Add</button>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs btn-square"
                  phx-click="swim_cancel_add"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </div>
            </form>
          </section>

          <p :if={@days == []} class="px-3 py-8 text-center text-sm text-base-content/50">
            Nothing on the board {@calendar.title}.
          </p>
        </div>
      </div>

      <.dateless_tray
        :if={@calendar.undated != []}
        cards={@calendar.undated}
        collapsed={MapSet.member?(@collapsed, "unscheduled")}
        can_write={@can_write}
        label="No date"
        hint={"Open a card to give it a #{if @start?, do: "start", else: "due"} date."}
        drag={:calendar}
      />
    </div>
    """
  end

  defp milestones?(assigns, day), do: Map.get(assigns.calendar.milestones, day.key, []) != []

  attr :card, :map, required: true
  attr :day, :map, required: true
  attr :compact, :boolean, default: false
  attr :start, :boolean, default: false, doc: "the chip sits on the card's start date"
  attr :show, :any, default: nil, doc: "MapSet of facet keys to render; nil shows all"
  attr :can_write, :boolean, default: true

  defp chip(assigns) do
    show = show_set(assigns.show)
    page? = SlipdockWeb.SlipdockComponents.page?(assigns.card)

    # A card placed by its start date is not overdue just because that day has passed.
    assigns =
      assign(assigns,
        overdue?: not assigns.start and assigns.day.past? and not assigns.card.completed,
        on: &MapSet.member?(show, &1),
        page?: page?,
        item_id: if(page?, do: "page-#{assigns.card.id}", else: to_string(assigns.card.id)),
        page_path: page? && "/boards/#{assigns.card.board_id}/wiki/#{assigns.card.slug}"
      )

    ~H"""
    <div
      id={"cal-#{@day.key}-#{@item_id}"}
      data-id={@item_id}
      class={[
        "cal-chip group/chip flex min-w-0 items-center gap-1.5 rounded-md border-l-[3px] bg-base-100 pl-1.5 pr-1 shadow-sm ring-1 ring-base-content/5 transition hover:ring-primary/40",
        if(@compact, do: "py-0.5 text-2xs", else: "py-1 text-xs"),
        @can_write && "cursor-grab active:cursor-grabbing",
        @card.completed && "opacity-60",
        @overdue? && "ring-error/40",
        chip_border(if @on.("cover"), do: @card, else: %{color: nil})
      ]}
      phx-click={if @page?, do: "open_page", else: "open_card"}
      phx-value-id={@card.id}
      title={chip_title(@card)}
    >
      <SlipdockWeb.SlipdockComponents.doc_link :if={@page?} path={@page_path} class="size-3.5" />
      <button
        :if={!@compact and @on.("status") and not @page?}
        type="button"
        class={[
          "shrink-0 rounded-full",
          if(@card.completed, do: "text-success", else: "text-base-content/25 hover:text-success")
        ]}
        phx-click={JS.push("toggle_complete", value: %{id: @card.id})}
        title={if @card.completed, do: "Mark incomplete", else: "Mark complete"}
      >
        <.icon
          name={if @card.completed, do: "hero-check-circle-solid", else: "hero-check-circle"}
          class="size-3.5"
        />
      </button>
      <span class={["min-w-0 flex-1 truncate font-medium", @card.completed && "text-base-content/50"]}>
        {@card.title}
      </span>
      <span
        :if={
          @card.start_date && @card.due_date && @card.start_date != @card.due_date &&
            (@on.("start_date") or @on.("due_date"))
        }
        class="shrink-0 text-base-content/40"
        title={
          if @start,
            do: "Due #{Calendar.strftime(@card.due_date, "%-d %b")}",
            else: "Started #{Calendar.strftime(@card.start_date, "%-d %b")}"
        }
      >
        <.icon name="hero-arrow-long-right" class="size-3" />
      </span>
      <.flag_icon
        :for={flag <- Enum.take(@card.flags, if(@compact, do: 1, else: 2))}
        :if={@on.("flags")}
        flag={flag}
        class="size-3"
      />
      <span
        :if={@card.tags != [] and !@compact and @on.("tags")}
        class="flex shrink-0 items-center gap-0.5"
      >
        <span
          :for={tag <- Enum.take(@card.tags, 3)}
          class={["size-1.5 rounded-full", Palette.dot(tag.color)]}
        ></span>
      </span>
      <.priority_badge :if={@on.("priority")} priority={@card.priority} />
    </div>
    """
  end

  defp chip_border(%{color: nil}), do: "border-base-content/20"
  defp chip_border(%{color: color}), do: Palette.border(color)

  defp chip_title(card) do
    dates =
      case {card.start_date, card.due_date} do
        {%Date{} = s, %Date{} = d} -> "#{fmt(s)} → #{fmt(d)}"
        {nil, %Date{} = d} -> "Due #{fmt(d)}"
        {%Date{} = s, nil} -> "Starts #{fmt(s)}"
        _ -> "No date"
      end

    "#{card.title}\n#{dates}"
  end

  defp fmt(d), do: Calendar.strftime(d, "%a %-d %b %Y")
end
