defmodule SlipdockWeb.BoardLive.ActivityComponent do
  @moduledoc """
  The board's activity log. Nothing here changes anything; the component
  only keeps the list current, and only for a reader of the board it is
  given.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Access, Boards}

  # Sent by the board when something on it changed.
  @impl true
  def update(%{refresh: true}, socket),
    do: {:ok, assign(socket, activities: Boards.list_activities(socket.assigns.board.id))}

  def update(%{board: board, current_user: user} = assigns, socket) do
    activities =
      if Access.can_read?(Access.board_permission(user, board)),
        do: Boards.list_activities(board.id),
        else: []

    {:ok,
     assign(socket,
       board: board,
       close_path: assigns.close_path,
       activities: activities
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-activity">
      <.activity_modal board={@board} activities={@activities} close_path={@close_path} />
    </div>
    """
  end

  attr :board, :any, required: true
  attr :activities, :list, required: true
  attr :close_path, :string, required: true

  defp activity_modal(assigns) do
    ~H"""
    <.modal id="activity-modal" on_close={JS.patch(@close_path)} size="md">
      <div class="space-y-4 p-6">
        <h2 class="flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-bolt" class="size-5 text-warning" /> Activity
        </h2>
        <p :if={@activities == []} class="text-sm text-base-content/60">Nothing has happened yet.</p>
        <ol class="max-h-[60vh] space-y-1 overflow-y-auto kanban-scroll pr-1">
          <li
            :for={a <- @activities}
            id={"activity-#{a.id}"}
            class="flex items-start gap-3 rounded-lg px-2 py-1.5 hover:bg-base-200/60"
          >
            <span class="mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full bg-base-200 text-base-content/60">
              <.icon name={activity_icon(a.kind)} class="size-3.5" />
            </span>
            <div class="min-w-0 flex-1">
              <p class="text-sm">{a.message}</p>
              <p class="text-xs text-base-content/50">{relative_time(a.inserted_at)}</p>
            </div>
          </li>
        </ol>
      </div>
    </.modal>
    """
  end
end
