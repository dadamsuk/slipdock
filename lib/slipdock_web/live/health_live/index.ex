defmodule SlipdockWeb.HealthLive.Index do
  @moduledoc """
  A board tree's Health page (W-2310, see `Slipdock.Health`): what the health
  monitor found stuck and has not cleared — open while it tries a fix,
  flagged once it needs a person — then what it fixed or saw clear lately,
  and when it last ran.

  Anyone who can read the board can look. Running it now needs write access.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Boards, Health}
  alias SlipdockWeb.Dates

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with %Boards.Board{} = board <- Boards.get_board(id),
         perm = Access.board_permission(user, board),
         true <- Access.can_read?(perm) do
      if connected?(socket), do: Health.subscribe(board)

      {:ok,
       socket
       |> assign(
         board: board,
         can_write: Access.can_write?(perm),
         page_title: "Health · #{board.name}",
         page_jumps: []
       )
       |> load()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: "/")}
    end
  end

  defp load(socket) do
    board = socket.assigns.board

    labels =
      Map.new(Health.detectors(), &{&1.key(), &1.label()})

    assign(socket,
      active: Health.list_active(board),
      recent: Health.list_recent(board, 20),
      last_run: Health.last_run(),
      labels: labels
    )
  end

  @impl true
  def handle_info({:health_changed, _root_id}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("run", _params, %{assigns: %{can_write: false}} = socket),
    do: {:noreply, put_flash(socket, :error, "You have read-only access to this board.")}

  def handle_event("run", _params, socket) do
    {:ok, counts} = Health.run(socket.assigns.board)

    message =
      case counts do
        %{"found" => 0} -> "Looked the tree over: nothing stuck."
        %{"found" => n, "flagged" => f} -> "Looked the tree over: #{n} stuck, #{f} newly flagged."
      end

    {:noreply, socket |> put_flash(:info, message) |> load()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp label(labels, key), do: Map.get(labels, key, key)

  defp when_text(nil), do: "never"
  defp when_text(%DateTime{} = at), do: Dates.exact(at)

  defp status_class("flagged"), do: "badge-warning"
  defp status_class("open"), do: "badge-info"
  defp status_class("fixed"), do: "badge-success"
  defp status_class(_), do: "badge-ghost"

  attr :incident, :map, required: true
  attr :labels, :map, required: true

  defp incident(assigns) do
    ~H"""
    <li
      id={"incident-#{@incident.id}"}
      class="space-y-1 rounded-xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/10"
    >
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class={["badge badge-sm", status_class(@incident.status)]}>{@incident.status}</span>
        <span class="font-medium">{label(@labels, @incident.detector)}</span>
        <span class="text-base-content/50">#{@incident.id}</span>
        <.link
          :if={@incident.card}
          navigate={~p"/boards/#{@incident.card.board_id}/cards/#{@incident.card.id}"}
          class="link"
        >
          #{@incident.card.id} {@incident.card.title}
        </.link>
      </div>
      <p class="text-sm">{@incident.summary}</p>
      <ul class="text-xs text-base-content/60">
        <li :for={entry <- @incident.log}>{entry["what"]}</li>
      </ul>
    </li>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      waiting_count={@waiting_count}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:boards}
      page_jumps={@page_jumps}
    >
      <:subnav>
        <SlipdockWeb.AgenticLive.Nav.subnav board={@board} />
      </:subnav>
      <:subactions>
        <button
          :if={@can_write}
          id="health-run"
          type="button"
          phx-click="run"
          phx-disable-with="Looking…"
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-lifebuoy" class="size-4" />
          <span class="hidden sm:inline">Look it over now</span>
        </button>
      </:subactions>

      <div id="health-shell" class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard" class="space-y-6">
          <.page_header id="health-title" title="Health">
            <:meta>
              Work the health monitor found stuck on this board and the boards beneath it: what it fixed, and what it flagged for a person.
              <span class="mt-1 block text-xs">
                Last run: <span id="health-last-run">{when_text(@last_run)}</span>.
              </span>
            </:meta>
          </.page_header>

          <.empty_state
            :if={@active == []}
            id="health-empty"
            icon="hero-lifebuoy"
            title="Nothing stuck"
          >
            The monitor looks every few minutes for jobs nobody takes, deadlocks, verification and merges that stall, and cards nobody is moving.
          </.empty_state>

          <section :if={@active != []} id="health-active" class="space-y-2">
            <h2 class="section-title">
              Stuck now <span class="badge badge-ghost badge-sm">{length(@active)}</span>
            </h2>
            <ul class="space-y-2">
              <.incident :for={i <- @active} incident={i} labels={@labels} />
            </ul>
          </section>

          <section :if={@recent != []} id="health-recent" class="space-y-2">
            <h2 class="section-title">Lately</h2>
            <ul class="space-y-2">
              <.incident :for={i <- @recent} incident={i} labels={@labels} />
            </ul>
          </section>
        </.page>
      </div>
    </Layouts.app>
    """
  end
end
