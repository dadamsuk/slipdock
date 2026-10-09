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

        {:ok, socket |> assign(page_title: "Meetings · #{board.name}") |> load()}

      {:error, socket} ->
        {:ok, socket}
    end
  end

  defp load(socket) do
    captures = Meetings.list_captures(socket.assigns.board)
    assign(socket, captures: captures, counts: Meetings.counts(captures))
  end

  @impl true
  def handle_info({:captures_changed, _board_id}, socket), do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("discard", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %Meetings.Capture{board_id: board_id} = capture when board_id == socket.assigns.board.id <-
           Meetings.get_capture(SlipdockWeb.Params.id(id) || 0),
         {:ok, _} <- Meetings.discard(capture, socket.assigns.current_user, via: "web") do
      {:noreply, socket |> put_flash(:info, "Discarded. Nothing from it was written.") |> load()}
    else
      {:error, :conflict, message} -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, socket}
    end
  end

  # Where a capture is, in a few words: the step it is on while reading.
  defp status_words(%{state: "reading", step: step}) do
    next = Slipdock.Meetings.Pipeline.next_step(step) || "ready"
    "reading — " <> String.downcase(Slipdock.Meetings.Pipeline.step_label(next))
  end

  defp status_words(%{state: state}), do: state_label(state)

  defp source_words("agent"), do: "from an agent"
  defp source_words("connector"), do: "from a connector"
  defp source_words(_), do: "uploaded"

  defp who(nil), do: "somebody"
  defp who(user), do: user.name || user.email

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
              <li
                :for={c <- @captures}
                id={"capture-#{c.id}"}
                data-state={c.state}
                class="flex items-center gap-3 px-4 py-3"
              >
                <.link
                  navigate={~p"/boards/#{@board}/meetings/#{c.id}"}
                  class="min-w-0 flex-1 hover:underline"
                >
                  <span class="block truncate font-medium">{c.title}</span>
                  <span class="block text-xs text-base-content/60">
                    {Calendar.strftime(c.started_at || c.inserted_at, "%d %b %Y")} · {source_words(
                      c.source
                    )} by {who(c.owner)}
                    <span :if={@counts[c.id].findings > 0}>· {@counts[c.id].findings} found</span>
                    <span :if={@counts[c.id].open > 0} class="text-warning">
                      · {@counts[c.id].open} to settle
                    </span>
                  </span>
                  <span :if={c.state == "committed"} class="block text-xs text-base-content/60">
                    committed by {who(c.committed_by)}{if c.undone_at, do: ", since undone"}
                  </span>
                  <span :if={c.state == "discarded"} class="block text-xs text-base-content/60">
                    discarded by {who(c.discarded_by)}
                  </span>
                  <span :if={c.state == "failed"} class="block truncate text-xs text-error">
                    {c.state_reason}
                  </span>
                </.link>
                <span
                  id={"capture-#{c.id}-state"}
                  class={["badge badge-sm shrink-0", state_class(c.state)]}
                >
                  {status_words(c)}
                </span>
                <button
                  :if={@can_write and c.state not in ~w(committed discarded)}
                  id={"discard-#{c.id}"}
                  type="button"
                  phx-click="discard"
                  phx-value-id={c.id}
                  data-confirm="Discard this capture? Nothing from it will be written; its record is kept."
                  class="btn btn-ghost btn-xs shrink-0"
                  title="Discard"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
