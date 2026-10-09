defmodule SlipdockWeb.MeetingLive.Show do
  @moduledoc """
  One capture: where it has got to, and what it holds — the transcript as
  read, line by line, and its record.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.MeetingLive.Components

  alias Slipdock.Meetings
  alias SlipdockWeb.MeetingLive.Access

  on_mount {SlipdockWeb.MeetingsHook, :require_enabled}

  @impl true
  def mount(%{"id" => id, "capture_id" => capture_id}, _session, socket) do
    with {:ok, socket} <- Access.mount_board(socket, id, :read),
         %Meetings.Capture{} = capture <- capture(capture_id, socket.assigns.board) do
      if connected?(socket), do: Meetings.subscribe(capture)

      {:ok, socket |> assign(page_title: capture.title) |> load(capture)}
    else
      {:error, socket} ->
        {:ok, socket}

      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That capture isn't on this board.")
         |> push_navigate(to: ~p"/boards/#{socket.assigns.board}/meetings")}
    end
  end

  defp capture(id, board) do
    with id when is_integer(id) <- SlipdockWeb.Params.id(id),
         %Meetings.Capture{board_id: board_id} = capture when board_id == board.id <-
           Meetings.get_capture(id) do
      capture
    else
      _ -> nil
    end
  end

  defp load(socket, capture), do: assign(socket, capture: Meetings.load(capture))

  @impl true
  def handle_info({:capture_changed, id}, socket) do
    {:noreply, load(socket, Meetings.get_capture!(id))}
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
      <:subnav><.meeting_nav board={@board} capture={@capture} /></:subnav>

      <div class="flex h-full flex-col">
        <.meeting_toolbar board={@board} marks={@marks} meetings={@meetings}>
          <span id="capture-state" class={["badge badge-sm", state_class(@capture.state)]}>
            {state_label(@capture.state)}
          </span>
        </.meeting_toolbar>

        <div class="kanban-scroll min-h-0 flex-1 overflow-y-auto">
          <div class="mx-auto max-w-3xl space-y-6 p-4 sm:p-6">
            <header>
              <h1 class="text-xl font-semibold">{@capture.title}</h1>
              <p class="mt-1 text-sm text-base-content/60">
                Sent by {(@capture.owner && (@capture.owner.name || @capture.owner.email)) ||
                  "somebody"}
                <span :if={@capture.started_at}>
                  · met {Calendar.strftime(@capture.started_at, "%d %b %Y, %H:%M")}
                </span>
                <span :if={@capture.attendees != []}>
                  · {Enum.map_join(@capture.attendees, ", ", &(&1["name"] || &1["email"]))}
                </span>
              </p>
              <p :if={@capture.state == "failed"} class="mt-2 text-sm text-error">
                {@capture.state_reason}
              </p>
            </header>

            <section
              id="capture-transcript"
              class="rounded-xl bg-base-100 ring-1 ring-base-content/10"
            >
              <h2 class="border-b border-base-content/10 px-4 py-2 text-sm font-medium">
                Transcript
              </h2>
              <p :if={@capture.utterances == []} class="px-4 py-3 text-sm text-base-content/60">
                No transcript yet.
              </p>
              <ol class="divide-y divide-base-content/5 text-sm">
                <li
                  :for={u <- @capture.utterances}
                  id={"line-#{u.line_id}"}
                  class="flex gap-3 px-4 py-2"
                >
                  <span class="w-12 shrink-0 font-mono text-2xs text-base-content/40">{clock(
                    u.start_ms
                  )}</span>
                  <span class="min-w-0">
                    <span :if={u.speaker} class="font-medium">{u.speaker}: </span>{u.text}
                  </span>
                </li>
              </ol>
            </section>

            <section id="capture-record" class="text-xs text-base-content/60">
              <h2 class="mb-1 font-medium text-base-content/70">Record</h2>
              <ol class="space-y-0.5">
                <li :for={e <- @capture.events}>
                  {Calendar.strftime(e.inserted_at, "%d %b %H:%M")} · {e.message}
                  <span :if={e.user}>— {e.user.name || e.user.email}</span>
                </li>
              </ol>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
