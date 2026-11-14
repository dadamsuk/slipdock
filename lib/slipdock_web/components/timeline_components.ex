defmodule SlipdockWeb.TimelineComponents do
  @moduledoc """
  The timeline view of a board: a scrolling window of days with a bar per
  scheduled card, grouped and collapsible, plus the tray of unscheduled cards
  shared with the calendar. With a depth above one, a card's subcards hang
  beneath its bar as indented rows.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  alias Slipdock.Boards.Card
  alias Slipdock.Dates
  alias Slipdock.Palette
  alias Slipdock.Swimlanes.Config

  attr :board, :any, required: true
  attr :config, Config, required: true
  attr :timeline, :map, required: true, doc: "from Slipdock.Timeline.build/3"
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed group keys"
  attr :can_write, :boolean, default: true
  attr :narrow, :boolean, default: false, doc: "render the phone's schedule instead of the chart"

  def timeline_view(%{narrow: true} = assigns), do: timeline_schedule(assigns)

  def timeline_view(assigns) do
    %{window: window} = assigns.timeline

    # With nothing scheduled, the grid still renders (empty) when there are
    # unscheduled cards to drag onto it.
    droppable? = assigns.can_write and assigns.timeline.unscheduled != []

    assigns =
      assign(assigns,
        show: Config.shown(assigns.config),
        window: window,
        grid?: assigns.timeline.groups != [] or droppable?,
        compact?: assigns.config.density == "compact",
        style:
          "--tl-day: #{window.px}px; --tl-track: repeat(#{window.days}, var(--tl-day)); " <>
            "--tl-cols: var(--tl-label-width, 16rem) var(--tl-track);"
      )

    ~H"""
    <div class="flex h-full flex-col">
      <%!-- Sized to its rows (up to the height there is), so the Unscheduled
      tray follows the last row instead of sitting at the window's foot. --%>
      <div
        id="timeline-scroll"
        class={["kanban-scroll min-h-0 overflow-auto", if(@grid?, do: "shrink", else: "flex-1")]}
      >
        <.view_empty
          :if={!@grid?}
          icon="hero-chart-bar"
          shown={@timeline.shown}
          hidden={@timeline.hidden}
          config={@config}
        >
          <:line>
            Nothing is scheduled in this range
            <span :if={@timeline.earlier > 0}>· {@timeline.earlier} earlier</span>
            <span :if={@timeline.later > 0}>· {@timeline.later} later</span>
          </:line>
        </.view_empty>

        <div
          :if={@grid?}
          id="timeline"
          phx-hook="Timeline"
          data-px={@window.px}
          data-days={@window.days}
          data-from={@window.from}
          data-disabled={to_string(!@can_write)}
          data-links={Jason.encode!(@timeline.links)}
          class={["tl relative min-w-max", @compact? && "tl-compact"]}
          style={@style}
        >
          <%!-- Column highlight while a tray card is dragged over the grid --%>
          <div id="tl-drop" class="tl-drop" hidden></div>
          <%!-- Dependency connectors, drawn by the Timeline hook from data-links --%>
          <svg id="tl-links" class="tl-links" aria-hidden="true"></svg>
          <%!-- Header rows: the coarser unit, then the zoom unit --%>
          <div :if={@window.header != []} class="tl-row tl-head sticky top-0 z-30 bg-base-100">
            <div class="tl-corner sticky left-0 z-10 border-b border-r border-base-300 bg-base-100">
            </div>
            <div
              :for={cell <- @window.header}
              class="truncate border-b border-r border-base-300 px-2 py-1 text-xs font-semibold text-base-content/70"
              style={"grid-column: #{cell.from + 2} / span #{cell.span}"}
            >
              {if cell.span * @window.px >= 56, do: cell.label}
            </div>
          </div>
          <div class={[
            "tl-row tl-head sticky z-30 bg-base-100",
            if(@window.header != [], do: "top-7", else: "top-0")
          ]}>
            <div
              class="tl-corner sticky left-0 z-10 flex items-center justify-between border-b border-r border-base-300 bg-base-100 px-3 text-xs text-base-content/60"
              title="Cards scheduled before or after this range"
            >
              <span :if={@timeline.earlier > 0}>◀ {@timeline.earlier} earlier</span>
              <span class="flex-1"></span>
              <span :if={@timeline.later > 0}>{@timeline.later} later ▶</span>
              <%!-- The title column's width: a reader's preference for this
              browser, kept on <html> by assets/js/timeline_labels.js. --%>
              <div
                id="tl-resize"
                class="tl-resize"
                phx-hook="TimelineLabelResize"
                role="separator"
                aria-orientation="vertical"
                aria-label="Title column width"
                tabindex="0"
                title="Drag to widen the titles · double-click to reset"
              >
              </div>
            </div>
            <div
              :for={cell <- @window.units}
              class={[
                "tl-units truncate border-b border-r border-base-300/70 px-1 text-2xs",
                cell.tone == :current && "bg-primary/10 font-semibold text-primary",
                cell.tone == :past && "text-base-content/40",
                is_nil(cell.tone) && "text-base-content/70"
              ]}
              style={"grid-column: #{cell.from + 2} / span #{cell.span}"}
              title={cell.label}
            >
              {cell.label}
            </div>
          </div>

          <div :if={@timeline.milestones != []} class="tl-row tl-milestones">
            <div class="sticky left-0 z-20 flex items-center gap-2 border-b border-r border-base-300 bg-base-100 px-3 text-xs font-semibold text-base-content/60">
              <.icon name="hero-flag" class="size-3.5" /> Milestones
            </div>
            <div class="tl-track border-b border-base-300/60">
              <.today_line window={@window} milestones={@timeline.milestones} />
              <span
                :for={m <- @timeline.milestones}
                class="tl-ms-label"
                style={"grid-column: #{m.idx + 1} / span 1"}
                title={"#{m.name} · #{SlipdockWeb.Dates.weekday(m.date)}"}
              >
                <span class={["tl-ms-diamond", Palette.dot(m.color || "indigo")]}></span>
                <span class="tl-ms-name">{m.name}</span>
              </span>
            </div>
          </div>

          <div :if={@timeline.groups == []} class="tl-row tl-card-row">
            <div class="sticky left-0 z-20 flex items-center border-b border-r border-base-300 bg-base-100 px-3 text-xs text-base-content/50">
              Drop a card here
            </div>
            <div class="tl-track border-b border-base-300/60">
              <span
                :for={i <- @window.weekends}
                class="tl-weekend"
                style={"grid-column: #{i + 1} / span 1"}
              ></span>
              <.today_line window={@window} milestones={@timeline.milestones} />
              <span
                class="px-3 text-xs text-base-content/50"
                style={"grid-column: 1 / span #{@window.days}"}
              >
                Nothing is scheduled in this range
                <span :if={@timeline.earlier > 0}>· {@timeline.earlier} earlier</span>
                <span :if={@timeline.later > 0}>· {@timeline.later} later</span>
              </span>
            </div>
          </div>

          <%= for group <- @timeline.groups do %>
            <% collapsed = MapSet.member?(@collapsed, group.key) %>
            <div :if={@timeline.grouped} class="tl-row tl-group">
              <div class="sticky left-0 z-20 border-b border-r border-base-300 bg-base-200/90">
                <button
                  type="button"
                  class={[
                    "flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm font-semibold hover:bg-base-200",
                    group.tone == :current && "text-primary",
                    group.tone == :past && "text-error/80"
                  ]}
                  phx-click="swim_toggle_row"
                  phx-value-key={group.key}
                  title={if collapsed, do: "Expand group", else: "Collapse group"}
                >
                  <.icon
                    name={if collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
                    class="size-3.5 shrink-0 text-base-content/50"
                  />
                  <span
                    :if={group.color}
                    class={["size-2.5 shrink-0 rounded-full", Palette.dot(group.color)]}
                  ></span>
                  <span class="truncate" title={group.label}>{group.label}</span>
                  <span class="badge badge-ghost badge-sm ml-auto font-mono">{group.count}</span>
                </button>
              </div>
              <div class="tl-track border-b border-base-300 bg-base-200/50">
                <.today_line window={@window} milestones={@timeline.milestones} />
              </div>
            </div>

            <.bar_rows
              :if={not collapsed}
              bars={group.bars}
              group_key={group.key}
              window={@window}
              board={@board}
              collapsed={@collapsed}
              can_write={@can_write}
              show={@show}
              milestones={@timeline.milestones}
              color_by={@config.color_by}
            />
          <% end %>
        </div>
      </div>

      <.dateless_tray
        :if={@timeline.unscheduled != []}
        cards={@timeline.unscheduled}
        collapsed={MapSet.member?(@collapsed, "unscheduled")}
        can_write={@can_write}
        label="Unscheduled"
        hint="Drag a card onto the timeline, or pick a due date."
        drag={:timeline}
      />
    </div>
    """
  end

  # The timeline as a phone reads it: a schedule, not a chart.
  #
  # A Gantt needs a label column and a month of days side by side. On 390
  # points the desktop chart gives 16rem to labels and leaves four days
  # visible, so the shape of the plan — the thing a timeline is *for* — is
  # off the right-hand edge. Here every card is a full-width row with its
  # dates in words and a bar drawn in percentages of the same window, so the
  # overlaps and the gaps are still legible, just one above the other.
  #
  # Dragging a bar to reschedule is a chart gesture and does not survive the
  # change; the card's own start and due dates do the same job on a phone,
  # and the tray of unscheduled cards is still there underneath.
  defp timeline_schedule(assigns) do
    assigns =
      assign(assigns,
        show: Config.shown(assigns.config),
        window: assigns.timeline.window
      )

    ~H"""
    <div class="flex h-full flex-col">
      <div id="timeline-scroll" class="kanban-scroll min-h-0 flex-1 overflow-y-auto">
        <.view_empty
          :if={@timeline.groups == []}
          icon="hero-chart-bar"
          shown={@timeline.shown}
          hidden={@timeline.hidden}
          config={@config}
        >
          <:line>
            Nothing is scheduled in this range
            <span :if={@timeline.earlier > 0}>· {@timeline.earlier} earlier</span>
            <span :if={@timeline.later > 0}>· {@timeline.later} later</span>
          </:line>
        </.view_empty>

        <div :if={@timeline.groups != []} id="timeline">
          <%= for group <- @timeline.groups do %>
            <% collapsed = MapSet.member?(@collapsed, group.key) %>
            <section class="border-b border-base-300">
              <button
                :if={@timeline.grouped}
                type="button"
                class={[
                  "sticky top-0 z-20 flex w-full items-center gap-2 border-b border-base-300 bg-base-100 px-3 py-2 text-left text-sm font-semibold",
                  group.tone == :current && "text-primary",
                  group.tone == :past && "text-error/80"
                ]}
                phx-click="swim_toggle_row"
                phx-value-key={group.key}
                aria-expanded={to_string(!collapsed)}
              >
                <.icon
                  name={if collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
                  class="size-4 shrink-0 text-base-content/50"
                />
                <span
                  :if={group.color}
                  class={["size-2.5 shrink-0 rounded-full", Palette.dot(group.color)]}
                ></span>
                <span class="truncate">{group.label}</span>
                <span class="badge badge-ghost badge-sm ml-auto font-mono">{group.count}</span>
              </button>

              <ul :if={not collapsed} class="divide-y divide-base-300/60">
                <.schedule_rows
                  bars={group.bars}
                  window={@window}
                  board={@board}
                  collapsed={@collapsed}
                  show={@show}
                  color_by={@config.color_by}
                />
              </ul>
            </section>
          <% end %>
        </div>
      </div>

      <.dateless_tray
        :if={@timeline.unscheduled != []}
        cards={@timeline.unscheduled}
        collapsed={MapSet.member?(@collapsed, "unscheduled")}
        can_write={@can_write}
        label="Unscheduled"
        hint="Open a card to give it a start or due date."
        drag={:calendar}
      />
    </div>
    """
  end

  # The click that opens a row's item. A timeline draws an epic's subcards from
  # their own sub-board, and a card from another board can't open in this
  # board's panel, so it goes to its own board's timeline; a page or a card
  # here opens as everywhere else (`open_item/1`).
  defp open_bar(item, board) do
    if not page?(item) and item.board_id != board.id,
      do: JS.navigate(~p"/boards/#{item.board_id}/timeline/cards/#{item.id}"),
      else: open_item(item)
  end

  attr :bars, :list, required: true
  attr :window, :map, required: true
  attr :board, :any, required: true
  attr :collapsed, :any, required: true
  attr :show, :any, required: true
  attr :color_by, :string, default: "cover"

  # One row per bar, subcards indented beneath it — the chart's nesting,
  # without the chart.
  defp schedule_rows(assigns) do
    ~H"""
    <%= for bar <- @bars do %>
      <% key = "card-#{bar.card.id}" %>
      <% collapsed = MapSet.member?(@collapsed, key) %>
      <% page? = SlipdockWeb.SlipdockComponents.page?(bar.card) %>
      <% open = open_bar(bar.card, @board) %>
      <li
        id={"tl-row-#{SlipdockWeb.SlipdockComponents.item_id(bar.card)}"}
        class={[
          "px-3 py-2",
          (bar.card.completed or Slipdock.Boards.Card.snoozed?(bar.card)) && "opacity-60"
        ]}
        style={bar.level > 0 && "padding-left: #{0.75 + bar.level * 1}rem"}
      >
        <div class="flex items-center gap-1.5">
          <button
            :if={bar.children != []}
            type="button"
            class="btn btn-ghost btn-xs btn-square -ml-1 shrink-0"
            phx-click="swim_toggle_row"
            phx-value-key={key}
            aria-label={if collapsed, do: "Show subcards", else: "Hide subcards"}
          >
            <.icon
              name={if collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
              class="size-3.5 text-base-content/50"
            />
          </button>
          <span
            :if={not is_nil(bar.card.color) and MapSet.member?(@show, "cover")}
            class={["size-2 shrink-0 rounded-full", Palette.dot(bar.card.color)]}
          ></span>
          <SlipdockWeb.SlipdockComponents.doc_link
            :if={page?}
            path={SlipdockWeb.SlipdockComponents.page_path(bar.card)}
            class="size-3.5"
          />
          <span
            role="link"
            tabindex="0"
            phx-click={open}
            class={[
              "min-w-0 flex-1 cursor-pointer truncate text-sm",
              bar.card.completed && "text-base-content/50 line-through"
            ]}
          >
            {bar.card.title}
          </span>
          <.flag_icon
            :for={flag <- Enum.take(bar.card.flags, 2)}
            :if={MapSet.member?(@show, "flags")}
            flag={flag}
            card={bar.card}
            class="size-3"
          />
          <.priority_badge :if={MapSet.member?(@show, "priority")} priority={bar.card.priority} />
        </div>

        <div class="mt-1 flex items-center gap-2">
          <span class="w-36 shrink-0 truncate text-2xs text-base-content/55">
            {schedule_dates(bar)}
          </span>
          <span
            class="relative h-1.5 min-w-0 flex-1 rounded-full bg-base-content/10"
            title={bar_title(bar)}
          >
            <span
              :if={@window.today}
              class="absolute top-[-2px] h-[calc(100%+4px)] w-px bg-primary/70"
              style={"left: #{pct(@window.today, @window.days)}%"}
            ></span>
            <span
              class={["absolute inset-y-0 rounded-full", bar_color(bar.card, @color_by, @board)]}
              style={"left: #{pct(bar.from, @window.days)}%; width: max(3px, #{pct(bar.to - bar.from, @window.days)}%)"}
            ></span>
          </span>
        </div>
      </li>

      <.schedule_rows
        :if={not collapsed and bar.children != []}
        bars={bar.children}
        window={@window}
        board={@board}
        collapsed={@collapsed}
        show={@show}
        color_by={@color_by}
      />
    <% end %>
    """
  end

  defp pct(_n, 0), do: 0
  defp pct(n, days), do: Float.round(n * 100 / days, 2)

  # The dates in words, since there is no axis to read them off.
  defp schedule_dates(%{card: card, kind: kind}) do
    start = Card.effective_start(card)
    due = Card.effective_due(card)

    case kind do
      :span -> "#{short(start)} → #{short(due)}"
      :due -> "Due #{short(due)}"
      :start -> "Starts #{short(start)}"
    end
  end

  defp short(%Date{} = d), do: SlipdockWeb.Dates.short(d)
  defp short(_), do: "—"

  attr :bars, :list, required: true
  attr :group_key, :string, required: true
  attr :window, :map, required: true
  attr :board, :any, required: true
  attr :collapsed, :any, required: true
  attr :can_write, :boolean, required: true
  attr :show, :any, required: true, doc: "MapSet of facet keys to render beside each label"
  attr :milestones, :list, default: []
  attr :color_by, :string, default: "cover"

  # One row per bar, then (unless collapsed) the rows of its subcards' bars,
  # indented by their level. Subcards live on other boards, so their rows
  # navigate there instead of opening a modal here.
  defp bar_rows(assigns) do
    ~H"""
    <%= for bar <- @bars do %>
      <% key = "card-#{bar.card.id}" %>
      <% collapsed = MapSet.member?(@collapsed, key) %>
      <% page? = SlipdockWeb.SlipdockComponents.page?(bar.card) %>
      <% open = open_bar(bar.card, @board) %>
      <% place = label_place(bar, @window) %>
      <div
        id={"tl-#{@group_key}-#{SlipdockWeb.SlipdockComponents.item_id(bar.card)}"}
        class={[
          "tl-row tl-card-row group/row",
          (bar.card.completed or Slipdock.Boards.Card.snoozed?(bar.card)) && "tl-row-dim"
        ]}
        data-level={bar.level}
      >
        <div
          class="sticky left-0 z-20 flex min-w-0 items-center gap-1.5 border-b border-r border-base-300 bg-base-100 pr-3 group-hover/row:bg-base-200/60"
          style={"padding-left: #{0.75 + bar.level * 1.25}rem"}
        >
          <button
            :if={bar.children != []}
            type="button"
            class="btn btn-ghost btn-xs btn-square -ml-1 shrink-0"
            phx-click="swim_toggle_row"
            phx-value-key={key}
            title={if collapsed, do: "Show subcards", else: "Hide subcards"}
          >
            <.icon
              name={if collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
              class="size-3.5 text-base-content/50"
            />
          </button>
          <.link
            :if={bar.more > 0 and bar.sub_board_id}
            navigate={~p"/boards/#{bar.sub_board_id}/timeline"}
            class="btn btn-ghost btn-xs btn-square -ml-1 shrink-0"
            title={"#{bar.more} subcards not shown here — open their timeline"}
          >
            <.icon name="hero-ellipsis-horizontal" class="size-3.5 text-base-content/50" />
          </.link>
          <span
            :if={not is_nil(bar.card.color) and MapSet.member?(@show, "cover")}
            class={["size-2 shrink-0 rounded-full", Palette.dot(bar.card.color)]}
          ></span>
          <SlipdockWeb.SlipdockComponents.doc_link
            :if={page?}
            path={SlipdockWeb.SlipdockComponents.page_path(bar.card)}
            class="size-3"
          />
          <span
            role="link"
            tabindex="0"
            class={[
              "min-w-0 flex-1 cursor-pointer truncate text-xs hover:underline",
              bar.card.completed && "text-base-content/50"
            ]}
            phx-click={open}
            title={bar.card.title}
          >
            {bar.card.title}
          </span>
          <span
            :if={bar.children != [] and MapSet.member?(@show, "subcards")}
            class="badge badge-ghost badge-xs font-mono"
            title="Scheduled subcards shown beneath"
          >
            {length(bar.children)}
          </span>
          <.flag_icon
            :for={flag <- Enum.take(bar.card.flags, 2)}
            :if={MapSet.member?(@show, "flags")}
            flag={flag}
            card={bar.card}
            class="size-3"
          />
          <.priority_badge
            :if={MapSet.member?(@show, "priority")}
            priority={bar.card.priority}
          />
          <.stated_pill
            :if={Card.stated_health(bar.card)}
            health={Card.stated_health(bar.card)}
            with_label={false}
          />
        </div>
        <div class="tl-track border-b border-base-300/60">
          <span
            :for={i <- @window.weekends}
            class="tl-weekend"
            style={"grid-column: #{i + 1} / span 1"}
          ></span>
          <.today_line window={@window} milestones={@milestones} />
          <div
            id={"tl-bar-#{@group_key}-#{SlipdockWeb.SlipdockComponents.item_id(bar.card)}"}
            class={[
              "tl-bar bg-gradient-to-r",
              "tl-bar-#{bar.kind}",
              bar.clipped_start && "tl-clip-start",
              bar.clipped_end && "tl-clip-end",
              (bar.derived_start or bar.derived_end) && "tl-bar-derived",
              Card.fuzzy?(bar.card) && "tl-bar-fuzzy",
              place.side != :inside && "tl-label-out tl-label-#{place.side}",
              bar_color(bar.card, @color_by, @board)
            ]}
            style={"grid-column: #{bar.from + 1} / #{bar.to + 1}"}
            data-id={SlipdockWeb.SlipdockComponents.item_id(bar.card)}
            data-kind={bar.kind}
            data-locked={to_string(bar.derived_start or bar.derived_end)}
            title={bar_title(bar)}
            phx-click={open}
          >
            <span
              :if={@can_write and bar.kind == :span and not bar.derived_start and not bar.derived_end}
              class="tl-handle tl-handle-start"
              data-edge="start"
            ></span>
            <span class="tl-bar-label" style={place.max && "max-width: #{place.max}px"}>
              <.icon
                :if={bar.derived_start or bar.derived_end}
                name="hero-arrow-up-on-square-stack"
                class="mr-0.5 inline size-3 align-[-2px]"
              />{bar.card.title}
            </span>
            <span
              :if={@can_write and not bar.derived_start and not bar.derived_end}
              class="tl-handle tl-handle-end"
              data-edge="end"
            ></span>
          </div>
        </div>
      </div>
      <.bar_rows
        :if={bar.children != [] and not collapsed}
        bars={bar.children}
        group_key={@group_key}
        window={@window}
        board={@board}
        collapsed={@collapsed}
        can_write={@can_write}
        show={@show}
        milestones={@milestones}
        color_by={@color_by}
      />
    <% end %>
    """
  end

  # Where a bar's title goes. It is drawn inside the bar when it fits there,
  # and beside the bar when it doesn't (a due-only or start-only bar has no
  # inside to speak of): on the right, or on the left when the window ends
  # too soon after the bar, as it does for a bar clipped at the right edge.
  # When neither side has room for all of it, the roomier side gets as much
  # as fits. Whether it fits is estimated here, from the title's length and
  # the bar's width in pixels, so the page never jumps after it is drawn.
  @label_char_px 6.5
  @label_icon_px 16
  @label_padding_px 14
  @label_gap_px 6
  @label_min_px 48

  @doc """
  Where `bar`'s title goes in `window`: `%{side: :inside | :right | :left,
  max: nil | pixels}`, `max` set only when the title has to be cut short.
  """
  def label_place(bar, window) do
    need = label_px(bar)
    inside = (bar.to - bar.from) * window.px - 2 - @label_padding_px
    right = (window.days - bar.to) * window.px - @label_gap_px
    left = bar.from * window.px - @label_gap_px

    cond do
      bar.kind == :span and need <= inside -> %{side: :inside, max: nil}
      need <= right and not bar.clipped_end -> %{side: :right, max: nil}
      need <= left -> %{side: :left, max: nil}
      bar.kind == :span and inside >= max(left, right) -> %{side: :inside, max: nil}
      max(left, right) < @label_min_px and bar.kind == :span -> %{side: :inside, max: nil}
      left > right -> %{side: :left, max: trunc(left)}
      true -> %{side: :right, max: trunc(max(right, @label_min_px))}
    end
  end

  defp label_px(bar) do
    icon = if bar.derived_start or bar.derived_end, do: @label_icon_px, else: 0
    String.length(bar.card.title) * @label_char_px + icon
  end

  attr :window, :map, required: true
  attr :milestones, :list, default: []

  # The vertical markers every row carries: today, and each milestone.
  defp today_line(assigns) do
    ~H"""
    <span :if={@window.today} class="tl-today" style={"grid-column: #{@window.today + 1} / span 1"}></span>
    <span
      :for={m <- @milestones}
      class="tl-ms-line"
      style={"grid-column: #{m.idx + 1} / span 1"}
    ></span>
    """
  end

  defp bar_color(%{completed: true}, "cover", _board), do: "tl-bar-done"

  defp bar_color(card, color_by, board) do
    case Slipdock.Coloring.color(card, color_by, board) do
      nil -> "tl-bar-default"
      color -> Palette.gradient(color)
    end
  end

  defp bar_title(%{card: card, kind: kind} = bar) do
    start = Card.effective_start(card)
    due = Card.effective_due(card)

    dates =
      case kind do
        :span ->
          "#{SlipdockWeb.Dates.weekday_long(start)} → #{SlipdockWeb.Dates.weekday_long(due)}"

        :due ->
          "Due #{SlipdockWeb.Dates.weekday_long(due)}"

        :start ->
          "Starts #{SlipdockWeb.Dates.weekday_long(start)}"
      end

    note =
      cond do
        bar.derived_start and bar.derived_end -> "\nDates rolled up from subcards"
        bar.derived_start -> "\nStart rolled up from subcards"
        bar.derived_end -> "\nDue date rolled up from subcards"
        true -> ""
      end

    precision =
      if Card.fuzzy?(card),
        do:
          "\nScheduled by #{String.downcase(Dates.precision_label(card.date_precision))}: #{Dates.range_label(start || due, due || start, card.date_precision)}",
        else: ""

    "#{card.title}\n#{dates}#{note}#{precision}"
  end

  ## Dateless tray -----------------------------------------------------------------

  attr :cards, :list, required: true
  attr :collapsed, :boolean, default: false
  attr :can_write, :boolean, default: true
  attr :label, :string, default: "No date"
  attr :hint, :string, default: nil

  attr :drag, :atom,
    default: nil,
    values: [nil, :calendar, :timeline],
    doc: "how cards can be dragged out: onto calendar days (Sortable) or timeline columns"

  @doc "Cards that have no dates, collapsible, each with a due-date picker to schedule it."
  def dateless_tray(assigns) do
    ~H"""
    <div class="max-h-48 shrink-0 overflow-y-auto border-t border-base-300 bg-base-100">
      <button
        type="button"
        class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm font-semibold hover:bg-base-200/60"
        phx-click="swim_toggle_row"
        phx-value-key="unscheduled"
      >
        <.icon
          name={if @collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
          class="size-3.5 shrink-0 text-base-content/50"
        />
        <.icon name="hero-calendar" class="size-4 text-base-content/50" />
        {@label}
        <span class="badge badge-ghost badge-sm font-mono">{length(@cards)}</span>
        <span :if={@hint} class="hidden text-xs font-normal text-base-content/50 md:inline">· {@hint}</span>
      </button>
      <div
        :if={!@collapsed}
        id="dateless-cards"
        phx-hook={tray_hook(@drag)}
        data-id="none"
        data-group="cal"
        data-event="cal_move"
        data-draggable=".cal-chip"
        data-disabled={to_string(!@can_write)}
        class="flex flex-wrap gap-2 px-3 pb-3"
      >
        <div
          :for={card <- @cards}
          id={"dateless-#{SlipdockWeb.SlipdockComponents.item_id(card)}"}
          data-id={SlipdockWeb.SlipdockComponents.item_id(card)}
          class={[
            "cal-chip flex items-center gap-2 rounded-lg bg-base-200/70 py-1 pl-2 pr-1 text-xs ring-1 ring-base-content/5",
            @drag && @can_write && "cursor-grab active:cursor-grabbing"
          ]}
        >
          <span :if={card.color} class={["size-2 shrink-0 rounded-full", Palette.dot(card.color)]}></span>
          <span
            role="link"
            tabindex="0"
            class={[
              "max-w-56 cursor-pointer truncate hover:underline",
              card.completed && "opacity-60"
            ]}
            phx-click={SlipdockWeb.SlipdockComponents.open_item(card)}
            title={card.title}
          >
            {card.title}
          </span>
          <.priority_badge priority={card.priority} />
          <form
            :if={@can_write}
            phx-change="table_update"
            id={"schedule-#{SlipdockWeb.SlipdockComponents.item_id(card)}"}
            title="Set a due date"
          >
            <input
              type="hidden"
              name="card_id"
              value={SlipdockWeb.SlipdockComponents.item_id(card)}
            />
            <input type="hidden" name="field" value="due_date" />
            <.date_field
              id={"schedule-date-#{SlipdockWeb.SlipdockComponents.item_id(card)}"}
              name="value"
              placeholder="Set due date"
              aria-label="Due date"
            />
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp tray_hook(:calendar), do: "Sortable"
  defp tray_hook(:timeline), do: "TimelineTray"
  defp tray_hook(nil), do: nil
end
