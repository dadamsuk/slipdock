defmodule SlipdockWeb.MeetingLive.Index do
  @moduledoc """
  A board's Meetings tab: the captures made on it (see `Slipdock.Meetings`).

  Not there at all while meeting mode is off — `SlipdockWeb.MeetingsHook`
  answers 404 before this mounts.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.MeetingLive.Components

  alias Slipdock.Meetings
  alias SlipdockWeb.MeetingLive.Access

  on_mount {SlipdockWeb.MeetingsHook, :require_enabled}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Access.mount_board(socket, id, :read) do
      {:ok, socket} ->
        board = socket.assigns.board
        if connected?(socket), do: Meetings.subscribe_board(board.id)

        {:ok,
         socket
         |> assign(page_title: "Meetings · #{board.name}")
         |> assign(captures: Meetings.list_captures(board))}

      {:error, socket} ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_info({:captures_changed, _board_id}, socket) do
    {:noreply, assign(socket, captures: Meetings.list_captures(socket.assigns.board))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:boards}
      page_jumps={@page_jumps}
    >
      <:subnav><.meeting_nav board={@board} /></:subnav>
      <:subactions>
        <.link
          :if={@can_write}
          id="new-capture"
          navigate={~p"/boards/#{@board}/meetings/new"}
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-plus" class="size-4" />
          <span class="hidden sm:inline">Capture a meeting</span>
        </.link>
      </:subactions>

      <div id="meetings-shell" class="flex h-full flex-col">
        <.meeting_toolbar board={@board} marks={@marks} meetings={@meetings} />

        <div class="kanban-scroll min-h-0 flex-1 overflow-y-auto">
          <div class="mx-auto max-w-3xl p-4 sm:p-6">
            <div
              :if={@captures == []}
              id="meetings-empty"
              class="rounded-2xl bg-base-100 p-8 text-center shadow-sm ring-1 ring-base-content/10"
            >
              <.icon name="hero-microphone" class="size-8 text-base-content/30" />
              <h2 class="mt-3 text-lg font-semibold">No meetings captured here yet</h2>
              <p class="mx-auto mt-2 max-w-md text-sm text-base-content/60">
                Send a meeting's recording or transcript, and Slipdock reads it alongside this
                board's cards and wiki. It proposes decisions, actions and card changes, each
                tied to the words it came from, and nothing is written until somebody reviews
                and commits it.
              </p>
            </div>

            <ul
              :if={@captures != []}
              id="captures"
              class="divide-y divide-base-content/5 rounded-2xl bg-base-100 ring-1 ring-base-content/10"
            >
              <li :for={c <- @captures} id={"capture-#{c.id}"}>
                <.link
                  navigate={~p"/boards/#{@board}/meetings/#{c.id}"}
                  class="flex items-center gap-3 px-4 py-3 hover:bg-base-200"
                >
                  <span class="min-w-0 flex-1">
                    <span class="block truncate font-medium">{c.title}</span>
                    <span class="block text-xs text-base-content/60">
                      {Calendar.strftime(c.started_at || c.inserted_at, "%d %b %Y")}
                    </span>
                  </span>
                  <span class={["badge badge-sm", state_class(c.state)]}>{state_label(c.state)}</span>
                </.link>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
