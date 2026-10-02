defmodule SlipdockWeb.OutlineComponents do
  @moduledoc """
  The outline view of a board: its cards as a collapsible tree with the
  subcards beneath each one, progress, dates and health rolled up at every
  level.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  alias Slipdock.Boards.Card
  alias Slipdock.Palette
  alias Slipdock.Swimlanes.Config

  attr :board, :any, required: true
  attr :config, Config, required: true
  attr :outline, :map, required: true, doc: "from Slipdock.Outline.build/4"
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed keys (card-<id>)"
  attr :can_write, :boolean, default: true
  attr :quick_preview, :map, default: %{}, doc: "quick-add previews by form id"

  def outline_view(assigns) do
    assigns =
      assign(assigns,
        compact?: assigns.config.density == "compact",
        show: Config.shown(assigns.config)
      )

    ~H"""
    <div id="outline-scroll" class="kanban-scroll h-full overflow-auto">
      <div
        :if={@outline.nodes == []}
        class="flex h-full flex-col items-center justify-center gap-2 p-8 text-center text-base-content/60"
      >
        <.icon name="hero-queue-list" class="size-10 opacity-40" />
        <p :if={@outline.hidden > 0}>No cards match the current filters.</p>
        <p :if={@outline.hidden == 0}>This board has no cards yet.</p>
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
        :if={@outline.nodes != []}
        id="outline"
        class={["min-w-0 sm:min-w-[60rem]", if(@compact?, do: "text-2xs", else: "text-xs")]}
      >
        <div class="ol-row ol-head sticky top-0 z-10 border-b border-base-300 bg-base-100 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          <div class="flex items-center gap-2 px-3 py-2">
            Card
            <span class="badge badge-ghost badge-sm font-mono normal-case tracking-normal">
              {@outline.done}/{@outline.total} done
            </span>
          </div>
          <div class="px-2 py-2">List</div>
          <div class="px-2 py-2">Progress</div>
          <div class="px-2 py-2">Schedule</div>
          <div class="px-2 py-2">Health</div>
          <div></div>
        </div>
        <.outline_rows
          nodes={@outline.nodes}
          board={@board}
          collapsed={@collapsed}
          can_write={@can_write}
          compact={@compact?}
          show={@show}
          quick_preview={@quick_preview}
        />
        <.quick_add_row
          :if={@can_write and @board.columns != []}
          id="outline-add"
          placeholder="Add a card…"
          preview={@quick_preview["outline-add"]}
          class="border-b border-base-300/60 py-1 pl-3 pr-2 text-sm"
        />
      </div>
      <.quick_add_row
        :if={@outline.nodes == [] and @can_write and @board.columns != []}
        id="outline-add"
        placeholder="Add the first card…"
        preview={@quick_preview["outline-add"]}
        class="px-6 py-3 text-sm"
      />
    </div>
    """
  end

  attr :nodes, :list, required: true
  attr :board, :any, required: true
  attr :collapsed, :any, required: true
  attr :can_write, :boolean, required: true
  attr :compact, :boolean, required: true
  attr :show, :any, required: true, doc: "MapSet of facet keys to render on each row"
  attr :quick_preview, :map, default: %{}

  defp outline_rows(assigns) do
    ~H"""
    <%= for node <- @nodes do %>
      <% key = "card-#{node.card.id}" %>
      <% collapsed = MapSet.member?(@collapsed, key) %>
      <% foreign = node.card.board_id != @board.id %>
      <div
        id={"ol-#{node.card.id}"}
        class={[
          "ol-row group/row border-b border-base-300/60 hover:bg-base-200/40",
          node.card.completed && "opacity-60",
          !node.match && "opacity-50"
        ]}
        data-level={node.level}
      >
        <div
          class="flex min-w-0 items-center gap-1.5 py-1.5 pr-2"
          style={"padding-left: #{0.5 + node.level * 1.5}rem"}
        >
          <button
            :if={node.children != []}
            type="button"
            class="btn btn-ghost btn-xs btn-square shrink-0"
            phx-click="swim_toggle_row"
            phx-value-key={key}
            title={if collapsed, do: "Expand", else: "Collapse"}
          >
            <.icon
              name={if collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
              class="size-3.5 text-base-content/50"
            />
          </button>
          <.link
            :if={node.children == [] and node.more and node.sub_board_id}
            navigate={~p"/boards/#{node.sub_board_id}/outline"}
            class="btn btn-ghost btn-xs btn-square shrink-0"
            title={"#{node.stats.children} more beneath — open"}
          >
            <.icon name="hero-ellipsis-horizontal" class="size-3.5 text-base-content/50" />
          </.link>
          <span :if={node.children == [] and not node.more} class="size-6 shrink-0"></span>
          <button
            :if={MapSet.member?(@show, "status")}
            type="button"
            class={[
              "shrink-0 rounded-full transition",
              if(node.card.completed,
                do: "text-success",
                else: "text-base-content/25 hover:text-success"
              )
            ]}
            phx-click={JS.push("toggle_complete", value: %{id: node.card.id})}
            disabled={!@can_write}
            title={if node.card.completed, do: "Mark incomplete", else: "Mark complete"}
          >
            <.icon
              name={if node.card.completed, do: "hero-check-circle-solid", else: "hero-check-circle"}
              class="size-4"
            />
          </button>
          <span
            :if={not is_nil(node.card.color) and MapSet.member?(@show, "cover")}
            class={["size-2 shrink-0 rounded-full", Palette.dot(node.card.color)]}
          ></span>
          <.link
            :if={foreign}
            navigate={~p"/boards/#{node.card.board_id}/outline/cards/#{node.card.id}"}
            class={[
              "min-w-0 truncate font-medium hover:underline",
              node.card.completed && "text-base-content/50"
            ]}
            title={node.card.title}
          >
            {node.card.title}
          </.link>
          <span
            :if={!foreign}
            role="link"
            tabindex="0"
            class={[
              "min-w-0 cursor-pointer truncate font-medium hover:underline",
              node.card.completed && "text-base-content/50"
            ]}
            phx-click="open_card"
            phx-value-id={node.card.id}
            title={node.card.title}
          >
            {node.card.title}
          </span>
          <span
            :if={node.card.tags != [] and MapSet.member?(@show, "tags")}
            class="flex shrink-0 items-center gap-1"
          >
            <.tag_chip :for={tag <- node.card.tags} tag={tag} size="xs" />
          </span>
          <.flag_icon
            :for={flag <- node.card.flags}
            :if={MapSet.member?(@show, "flags")}
            flag={flag}
            class="size-3"
          />
          <.priority_badge
            :if={MapSet.member?(@show, "priority")}
            priority={node.card.priority}
          />
          <.assignee_chip
            :if={not is_nil(node.card.assignee) and MapSet.member?(@show, "assignee")}
            user={node.card.assignee}
            size="xs"
          />
        </div>
        <div class="flex items-center px-2 text-xs text-base-content/60">
          <span class="truncate" title={node.list}>{node.list}</span>
        </div>
        <div class="flex items-center gap-2 px-2">
          <%= if node.stats.children > 0 do %>
            <progress
              class={[
                "progress h-1.5 w-20",
                cond do
                  node.stats.done == node.stats.total -> "progress-success"
                  node.stats.health == :blocked -> "progress-error"
                  node.stats.health == :late -> "progress-warning"
                  true -> "progress-primary"
                end
              ]}
              value={node.stats.done}
              max={max(node.stats.total, 1)}
            ></progress>
            <span class="font-mono text-xs text-base-content/70">
              {node.stats.done}/{node.stats.total}
            </span>
          <% end %>
        </div>
        <div class="flex flex-wrap items-center gap-1 px-2 text-xs">
          <.schedule_range card={node.card} />
        </div>
        <div class="flex items-center gap-1 px-2">
          <.health_pill :if={node.stats.health != :ok} health={node.stats.health} />
          <.stated_pill :if={node.stats.stated} health={node.stats.stated} with_label={false} />
        </div>
        <div class="flex items-center justify-end pr-2 opacity-0 transition group-hover/row:opacity-100 focus-within:opacity-100 no-hover:opacity-100">
          <.link
            :if={node.sub_board_id}
            navigate={~p"/boards/#{node.sub_board_id}/outline"}
            class="btn btn-ghost btn-xs"
            title="Open this card's board"
          >
            <.icon name="hero-arrow-right-circle" class="size-4" />
          </.link>
        </div>
      </div>
      <.outline_rows
        :if={node.children != [] and not collapsed}
        nodes={node.children}
        board={@board}
        collapsed={@collapsed}
        can_write={@can_write}
        compact={@compact}
        show={@show}
        quick_preview={@quick_preview}
      />
      <.quick_add_row
        :if={@can_write and not is_nil(node.sub_board_id) and not collapsed}
        id={"outline-add-#{node.card.id}"}
        params={%{"parent_card" => node.card.id}}
        placeholder={"Add a subcard to #{node.card.title}…"}
        preview={@quick_preview["outline-add-#{node.card.id}"]}
        class="border-b border-base-300/60 py-0.5 pr-2 text-xs"
        style={"padding-left: #{0.5 + (node.level + 1) * 1.5}rem"}
      />
    <% end %>
    """
  end

  attr :card, :map, required: true

  # "5 Jan → 20 Jan", each end muted and marked when it comes from subcards,
  # with the slip when the subcards run past the card's own due date.
  defp schedule_range(assigns) do
    card = assigns.card

    assigns =
      assign(assigns,
        start: Card.effective_start(card),
        due: Card.effective_due(card),
        ds: Card.start_derived?(card),
        de: Card.due_derived?(card),
        state: due_state(Card.effective_due(card), card.completed)
      )

    ~H"""
    <span :if={is_nil(@start) and is_nil(@due)} class="ol-nodate text-base-content/40">—</span>
    <span
      :if={@start}
      class={[@ds && "italic text-base-content/50"]}
      title={if @ds, do: "Start rolled up from subcards"}
    >
      {fmt(@start)}
    </span>
    <span :if={@start && @due && @start != @due} class="text-base-content/40">→</span>
    <span
      :if={@due && @due != @start}
      class={[
        "font-medium",
        @de && "italic",
        @state == :overdue && "text-error",
        @state == :soon && "text-amber-700 dark:text-amber-300",
        @state == :done && "text-success",
        @de && @state in [:later, nil] && "text-base-content/50"
      ]}
      title={if @de, do: "Due date rolled up from subcards", else: "Due #{fmt(@due)}"}
    >
      {fmt(@due)}
    </span>
    <.slip_chips
      card={@card}
      class="inline-flex items-center gap-0.5 rounded-md bg-warning/20 px-1 py-0.5 text-2xs font-medium text-warning-content dark:text-warning"
    />
    """
  end

  defp fmt(%Date{} = d), do: Calendar.strftime(d, "%-d %b")
  defp fmt(_), do: ""
end
