defmodule SlipdockWeb.MeetingLive.Index do
  @moduledoc """
  A board's Meetings tab: the captures made on it (see `Slipdock.Meetings`).

  Not there at all while meeting mode is off — `SlipdockWeb.MeetingsHook`
  answers 404 before this mounts.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents, only: [view_tabs: 1]

  alias Slipdock.{Access, Boards, Meetings, Palette}

  on_mount {SlipdockWeb.MeetingsHook, :require_enabled}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    board = Boards.get_board!(id)
    user = socket.assigns.current_user
    perm = Access.board_permission(user, board)

    if Access.can_read?(perm) do
      {:ok,
       assign(socket,
         board: board,
         can_write: Access.can_write?(perm),
         meetings: Meetings.presence(user, board),
         marks: Slipdock.Favourites.marks(user),
         page_title: "Meetings · #{board.name}",
         page_jumps: []
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have access to that board.")
       |> push_navigate(to: ~p"/")}
    end
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
      <:subnav>
        <nav class="flex min-w-0 items-center gap-1 text-sm">
          <.link
            navigate={~p"/boards/#{@board}"}
            class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
          >
            <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
            <span class="truncate font-semibold">{@board.name}</span>
          </.link>
          <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
          <span class="rounded-lg px-2 py-1 font-semibold">Meetings</span>
        </nav>
      </:subnav>

      <div id="meetings-shell" class="flex h-full flex-col">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-2 border-b border-base-300 bg-base-100/70 px-3 py-2 text-sm">
          <.view_tabs board={@board} mode={:meetings} view={nil} marks={@marks} meetings={@meetings} />
        </div>

        <div class="kanban-scroll min-h-0 flex-1 overflow-y-auto">
          <div class="mx-auto max-w-3xl p-6">
            <div
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
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
