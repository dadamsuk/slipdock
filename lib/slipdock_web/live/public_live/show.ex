defmodule SlipdockWeb.PublicLive.Show do
  @moduledoc """
  A published saved view: anyone with the link sees the board through that
  view, live and read-only, without an account. Only the timeline and
  calendar anchor date can be changed from the URL; everything else is
  pinned to what the view saved.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SwimlaneComponents
  import SlipdockWeb.TableComponents
  import SlipdockWeb.TimelineComponents
  import SlipdockWeb.CalendarComponents
  import SlipdockWeb.OutlineComponents
  import SlipdockWeb.NarrativeComponents

  alias Slipdock.{Boards, Narrative, Outline, Swimlanes, Table, Timeline}
  alias Slipdock.Swimlanes.Config

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Boards.get_published_view(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That link is no longer published.")
         |> redirect(to: ~p"/login")}

      view ->
        if connected?(socket), do: Boards.subscribe(view.board_id)

        {:ok,
         assign(socket,
           token: token,
           view: view,
           board: view.board,
           page_title: "#{view.name} · #{view.board.name}",
           collapsed: MapSet.new(),
           expanded: MapSet.new(),
           form_key: 0
         )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(date: params["date"], from: params["from"], to: params["to"])
     |> assign_view()}
  end

  defp assign_view(%{assigns: %{view: view, board: board, date: date} = a} = socket) do
    base = Config.from_map(view.config)

    config =
      %{"date" => date || "", "from" => a[:from] || "", "to" => a[:to] || ""}
      |> Config.from_query(base)
      |> Config.sanitize(board)

    # A board-mode view is shown as a grid of lists.
    {mode, config} =
      case config.mode do
        "board" -> {:swimlanes, %{config | rows: "none", cols: "column"}}
        m -> {String.to_existing_atom(m), config}
      end

    socket
    |> assign(mode: mode, config: config)
    |> assign_grid()
  end

  defp assign_grid(%{assigns: %{mode: :swimlanes, board: board, config: config}} = socket),
    do: assign(socket, grid: Swimlanes.grid(board, config))

  defp assign_grid(%{assigns: %{mode: :table, board: board, config: config}} = socket),
    do: assign(socket, table_rows: Table.rows(board, config))

  defp assign_grid(%{assigns: %{mode: :timeline, board: board, config: config}} = socket),
    do: assign(socket, timeline: Timeline.build(board, config))

  defp assign_grid(%{assigns: %{mode: :calendar, board: board, config: config}} = socket),
    do: assign(socket, calendar: Slipdock.Calendar.build(board, config))

  defp assign_grid(%{assigns: %{mode: :outline, board: board, config: config}} = socket),
    do: assign(socket, outline: Outline.build(board, board.rollup, config))

  defp assign_grid(%{assigns: %{mode: :narrative, board: board, config: config}} = socket),
    do: assign(socket, narrative: Narrative.build(board, config))

  @impl true
  def handle_info({:board_changed, _id}, %{assigns: %{view: view}} = socket) do
    case Boards.get_published_view(socket.assigns.token) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This view is no longer published.")
         |> redirect(to: ~p"/login")}

      fresh ->
        {:noreply,
         socket
         |> assign(view: %{fresh | board: fresh.board}, board: fresh.board)
         |> assign_view()}
    end
    |> tap(fn _ -> view end)
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("swim_toggle_row", %{"key" => key}, socket) do
    {:noreply, update(socket, :collapsed, &toggle_member(&1, key))}
  end

  def handle_event("narrative_range", params, socket) do
    query = for {k, v} <- Map.take(params, ~w(from to)), v not in [nil, ""], do: {k, v}
    {:noreply, push_patch(socket, to: ~p"/p/#{socket.assigns.token}?#{query}")}
  end

  def handle_event("cal_toggle_day", %{"key" => key}, socket) do
    {:noreply, update(socket, :expanded, &toggle_member(&1, key))}
  end

  # Everything else a component might push (opening a card, dragging) is read-only here.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp toggle_member(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  defp nav(%{mode: :timeline, timeline: t}), do: %{title: t.title, prev: t.prev, next: t.next}
  defp nav(%{mode: :calendar, calendar: c}), do: %{title: c.title, prev: c.prev, next: c.next}
  defp nav(_), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, nav: nav(assigns))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} viewport={@viewport}>
      <div class="flex h-full flex-col">
        <div class="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-base-300 bg-base-100/70 px-4 py-2 text-sm">
          <span class={["size-3 rounded-full", Slipdock.Palette.dot(@board.color)]}></span>
          <span class="font-semibold">{@board.name}</span>
          <span class="text-base-content/40">›</span>
          <span class="flex items-center gap-1.5">
            <.icon name={mode_icon(@mode)} class="size-4 text-base-content/60" />
            {@view.name}
          </span>
          <span
            class="chip chip-line text-2xs"
            title="A read-only view published by the board's owner"
          >
            <.icon name="hero-globe-alt" class="size-3" /> Published view
          </span>
          <span :if={Config.filtering?(@config)} class="chip chip-line text-2xs">
            <.icon name="hero-funnel" class="size-3" /> Filtered
          </span>
          <form
            :if={@mode == :narrative}
            class="ml-auto flex items-center gap-1 text-xs text-base-content/60"
            phx-change="narrative_range"
            phx-submit="narrative_range"
          >
            from <input type="date" name="from" value={@config.from} class="input input-xs w-32" /> to
            <input type="date" name="to" value={@config.to} class="input input-xs w-32" />
          </form>
          <div :if={@nav} class="ml-auto flex items-center gap-1">
            <.link
              patch={~p"/p/#{@token}?date=#{@nav.prev}"}
              class="btn btn-ghost btn-xs btn-square"
              title="Earlier"
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </.link>
            <span class="min-w-32 text-center text-xs font-semibold">{@nav.title}</span>
            <.link
              patch={~p"/p/#{@token}?date=#{@nav.next}"}
              class="btn btn-ghost btn-xs btn-square"
              title="Later"
            >
              <.icon name="hero-chevron-right" class="size-4" />
            </.link>
            <.link patch={~p"/p/#{@token}"} class="btn btn-ghost btn-xs">Today</.link>
          </div>
          <div
            :if={@mode in [:timeline, :swimlanes] and @config.color_by != "cover"}
            class="flex flex-wrap items-center gap-x-2.5 gap-y-1 rounded-full bg-base-200/70 px-2.5 py-1 text-2xs text-base-content/70"
          >
            <span
              :for={{color, label} <- Slipdock.Coloring.legend(@board, @config.color_by)}
              class="flex items-center gap-1"
            >
              <span class={["size-2.5 rounded-full", Slipdock.Palette.dot(color)]}></span>{label}
            </span>
          </div>
        </div>
        <div class="min-h-0 flex-1">
          <%= case @mode do %>
            <% :swimlanes -> %>
              <.swim_grid
                narrow={@narrow?}
                board={@board}
                grid={@grid}
                config={@config}
                collapsed={@collapsed}
                form_key={@form_key}
                can_write={false}
              />
            <% :table -> %>
              <.table_view
                narrow={@narrow?}
                board={@board}
                config={@config}
                rows={@table_rows}
                collapsed={@collapsed}
                form_key={@form_key}
                can_write={false}
              />
            <% :timeline -> %>
              <.timeline_view
                narrow={@narrow?}
                board={@board}
                config={@config}
                timeline={@timeline}
                collapsed={@collapsed}
                form_key={@form_key}
                can_write={false}
              />
            <% :calendar -> %>
              <.calendar_view
                narrow={@narrow?}
                board={@board}
                config={@config}
                calendar={@calendar}
                expanded={@expanded}
                collapsed={@collapsed}
                form_key={@form_key}
                can_write={false}
              />
            <% :outline -> %>
              <.outline_view
                board={@board}
                config={@config}
                outline={@outline}
                collapsed={@collapsed}
                can_write={false}
              />
            <% :narrative -> %>
              <.narrative_view
                board={@board}
                config={@config}
                narrative={@narrative}
                collapsed={@collapsed}
                can_write={false}
                view_name={@view.name}
              />
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
