defmodule SlipdockWeb.BoardLive.SearchResults do
  @moduledoc """
  A searched or filtered board, drawn as one list down the page (#2809).

  While a search or filter is on, the board view's lists keep their width,
  so the lists with matches could sit off the right of the screen with
  nothing to say so. Instead the matches are drawn as one list, grouped by
  the list each is in, in board order: a heading per list (its name and
  how many match, a click folds or unfolds it), a row per match (the
  compact card, which opens the panel, with the move menu), and the lists
  with no matches named on one dim line at the end.

  A list of the `done` category, and any group over #{10} matches, starts
  folded. The banner's **Board** button puts the columns back for this
  search (`search_layout: :board`); the layout and the folds go back to
  their defaults once nothing is filtered (`reset/1`, from
  `State.assign_columns/1`). It is drawn from the board's filtered
  `@columns`, so it shows what the columns would.

  `BoardLive.Show` hands these events over: they change nothing stored.
  """
  use Phoenix.Component

  import SlipdockWeb.CoreComponents, only: [icon: 1]

  alias Slipdock.Boards.Column
  alias Slipdock.Palette
  alias SlipdockWeb.BoardLive.Selection

  @read_events ~w(toggle_result_group search_layout)

  # A group longer than this starts folded.
  @fold_over 10

  @doc "Events that change nothing stored."
  def read_events, do: @read_events

  @doc "Every event handled here."
  def events, do: @read_events

  @doc "The assigns this module keeps on the board view."
  def mount_assigns, do: [search_layout: :list, result_folds: MapSet.new()]

  @doc "Back to the list layout and the default folds: for when nothing is filtered."
  def reset(socket), do: assign(socket, mount_assigns())

  @doc "Handles one of `events/0`."
  def handle_event("toggle_result_group", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        folds = socket.assigns.result_folds

        folds =
          if MapSet.member?(folds, id), do: MapSet.delete(folds, id), else: MapSet.put(folds, id)

        {:noreply, assign(socket, result_folds: folds)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("search_layout", %{"layout" => layout}, socket)
      when layout in ~w(list board),
      do: {:noreply, assign(socket, search_layout: String.to_existing_atom(layout))}

  def handle_event("search_layout", _params, socket), do: {:noreply, socket}

  @doc """
  Whether a group starts folded: a `done` list with matches, or any group
  over #{@fold_over}.
  """
  def folded_by_default?(%Column{} = column, count),
    do: count > @fold_over or (Column.done?(column) and count > 0)

  @doc """
  Whether a group is folded now: its default, flipped by each click on its
  heading (`folds` holds the list ids clicked an odd number of times).
  """
  def folded?(column, count, folds),
    do: folded_by_default?(column, count) != MapSet.member?(folds, column.id)

  @doc """
  The banner's count: "20 cards match in 4 lists", from the filtered
  columns.
  """
  def summary(columns) do
    counts = Enum.map(columns, &length(&1.items))
    total = Enum.sum(counts)
    lists = Enum.count(counts, &(&1 > 0))

    "#{total} #{plural(total, "card matches", "cards match")} in #{lists} #{plural(lists, "list", "lists")}"
  end

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  attr :layout, :atom, required: true

  @doc "The banner's switch between the grouped list and the columns."
  def layout_toggle(assigns) do
    ~H"""
    <button
      :if={@layout == :list}
      id="search-layout-toggle"
      type="button"
      class="btn btn-ghost btn-xs"
      phx-click="search_layout"
      phx-value-layout="board"
      title="Show the matches in their lists, as columns"
    >
      <.icon name="hero-view-columns" class="size-3.5" /> Board
    </button>
    <button
      :if={@layout == :board}
      id="search-layout-toggle"
      type="button"
      class="btn btn-ghost btn-xs"
      phx-click="search_layout"
      phx-value-layout="list"
      title="Show the matches as one list, grouped by list"
    >
      <.icon name="hero-queue-list" class="size-3.5" /> List
    </button>
    """
  end

  attr :columns, :list, required: true
  attr :folds, :any, required: true
  attr :narrow?, :boolean, default: false
  attr :select_mode, :boolean, default: false
  attr :selected, :any, default: MapSet.new()

  slot :row,
    required: true,
    doc: "one match, given `{column, {kind, item}}`; the board's compact card"

  @doc "The matches, grouped by list in board order, then the lists with none."
  def search_results(assigns) do
    {matched, empty} = Enum.split_with(assigns.columns, &(&1.items != []))
    assigns = assign(assigns, matched: matched, empty: empty)

    ~H"""
    <div
      id="search-results"
      class={["min-h-0 flex-1 overflow-y-auto", if(@narrow?, do: "px-2 py-2", else: "px-4 py-3")]}
    >
      <div class="mx-auto max-w-4xl space-y-2">
        <section
          :for={%{column: column, items: items, groups: groups} <- @matched}
          id={"result-group-#{column.id}"}
          data-role="result-group"
          data-folded={to_string(folded?(column, length(items), @folds))}
        >
          <% folded = folded?(column, length(items), @folds) %>
          <div class="flex items-center gap-1">
            <button
              type="button"
              id={"result-heading-#{column.id}"}
              class="flex min-w-0 flex-1 items-center gap-2 rounded-lg px-2 py-1.5 text-left text-xs font-semibold uppercase tracking-wide text-base-content/70 hover:bg-base-200"
              phx-click="toggle_result_group"
              phx-value-id={column.id}
              aria-expanded={to_string(!folded)}
              aria-controls={"result-rows-#{column.id}"}
            >
              <.icon
                name={if folded, do: "hero-chevron-right", else: "hero-chevron-down"}
                class="size-3.5 shrink-0"
              />
              <span
                :if={column.color}
                class={["size-2.5 shrink-0 rounded-full", Palette.dot(column.color)]}
              ></span>
              <span class="min-w-0 flex-1 truncate">{column.name}</span>
              <span data-role="result-count" class="badge badge-sm badge-ghost tabular-nums">
                {length(items)}
              </span>
              <span :if={folded} class="text-2xs font-normal normal-case text-base-content/50">
                show ›
              </span>
            </button>
            <%!-- Select mode's select-all for the list (#2690), as on its
                  column: every match it shows, or none once all are picked. --%>
            <% all? = @select_mode && Selection.all_selected?(@selected, %{groups: groups}) %>
            <button
              :if={@select_mode}
              type="button"
              id={"select-list-#{column.id}"}
              class={["btn btn-xs btn-square", if(all?, do: "btn-primary", else: "btn-ghost")]}
              phx-click="select_list"
              phx-value-id={column.id}
              aria-pressed={to_string(all?)}
              title={
                if all?, do: "Deselect this list's cards", else: "Select every card in this list"
              }
            >
              <.icon
                name={if all?, do: "hero-check-circle-solid", else: "hero-check-circle"}
                class="size-4"
              />
            </button>
          </div>
          <div
            :if={!folded}
            id={"result-rows-#{column.id}"}
            class="ml-3 space-y-1 border-l border-base-300 py-1 pl-3"
          >
            <%= for item <- items do %>
              {render_slot(@row, {column, item})}
            <% end %>
          </div>
        </section>

        <p
          :if={@empty != []}
          id="search-no-matches"
          class="px-2 py-2 text-center text-xs text-base-content/50"
        >
          ─ {Enum.map_join(@empty, ", ", & &1.column.name)}: no matches ─
        </p>
      </div>
    </div>
    """
  end
end
