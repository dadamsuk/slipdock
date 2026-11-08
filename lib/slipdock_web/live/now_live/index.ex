defmodule SlipdockWeb.NowLive.Index do
  @moduledoc """
  A board tree's **Right now** page (#2103, `Slipdock.Now`): which runners
  are doing what, which cards are in progress and where they sit, and the
  jobs waiting for a runner, read again every few seconds while it is open.

  One click from the board page: the delivery line (the rocket) links here,
  and a board with Agentic Building on and that line off has a line of its
  own saying what is happening (`SlipdockWeb.BoardLive.BoardView`). The
  Agentic Building page has it as a tile too.

  Anyone who can read the board can look; it changes nothing.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Boards, CardState, Now, Pulse}
  alias SlipdockWeb.Dates

  @every 10_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with %Boards.Board{} = board <- Boards.get_board(id),
         true <- Access.can_read?(Access.board_permission(user, board)),
         # The page names the whole tree's cards, so it needs the root too.
         true <- root_readable?(user, board) do
      {:ok,
       socket
       |> assign(board: board, page_title: "Right now · #{board.name}", page_jumps: [])
       |> load()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: "/")}
    end
  end

  defp root_readable?(_user, %Boards.Board{root_id: nil}), do: true

  defp root_readable?(user, %Boards.Board{root_id: root_id}),
    do: Access.can_read?(Access.board_permission(user, Boards.get_board(root_id)))

  defp load(socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @every)
    now = DateTime.utc_now()
    assign(socket, now: now, snap: Now.snapshot(socket.assigns.board, now: now))
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp since(nil, _now), do: nil
  defp since(%DateTime{} = at, now), do: Pulse.duration(max(DateTime.diff(now, at), 0))

  defp hold_label("waiting"), do: "Waiting on a person"
  defp hold_label("verifying"), do: "Verifying"
  defp hold_label("merging"), do: "Merging"
  defp hold_label("blocked"), do: "Blocked"
  defp hold_label("review"), do: "In review"
  defp hold_label("stuck"), do: "Stuck"

  defp hold_class("waiting"), do: "badge-warning"
  defp hold_class("blocked"), do: "badge-error"
  defp hold_class("stuck"), do: "badge-error"
  defp hold_class(_), do: "badge-info"

  attr :job, :map, required: true
  attr :now, :any, required: true

  defp job_line(assigns) do
    ~H"""
    <div class="min-w-0 space-y-0.5 text-sm">
      <div class="flex flex-wrap items-center gap-2">
        <span class="badge badge-ghost badge-sm">{@job.kind}</span>
        <.link
          :if={@job.card_id}
          navigate={~p"/boards/#{@job.board_id}/cards/#{@job.card_id}"}
          class="link min-w-0 truncate"
        >
          #{@job.card_id} {@job.card}
        </.link>
        <span class="text-xs text-base-content/60">
          job #{@job.id} · {since(@job.since, @now)}
        </span>
      </div>
      <p :if={@job.step} class="truncate text-xs text-base-content/70" title={@job.step}>
        {@job.step}
        <span :if={@job.step_at} class="text-base-content/50">· {since(@job.step_at, @now)} ago</span>
      </p>
    </div>
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

      <div id="now-shell" class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard" class="space-y-6">
          <.page_header id="now-title" title="Right now">
            <:meta>
              What the runners are doing, the cards in progress and where they are, and the jobs waiting for a runner, on this board and the boards beneath it.
              <span class="mt-1 block text-xs">
                As of <span id="now-at">{Dates.time(@now)}</span>, read again every few seconds.
              </span>
            </:meta>
          </.page_header>

          <section id="now-runners" class="space-y-2">
            <h2 class="section-title">
              Runners
              <span class="badge badge-ghost badge-sm">
                {@snap.counts.working} working · {@snap.counts.online}/{@snap.counts.runners} online
              </span>
            </h2>
            <.empty_state
              :if={@snap.runners == []}
              id="now-no-runners"
              compact
              icon="hero-cpu-chip"
              title="No runners"
            >
              No runner takes work from this board yet.
              <:action>
                <.link navigate={~p"/boards/#{@board}/automations"} class="btn btn-sm">
                  Connect one
                </.link>
              </:action>
            </.empty_state>
            <ul class="space-y-2">
              <li
                :for={r <- @snap.runners}
                id={"now-runner-#{r.id}"}
                class="space-y-1 rounded-xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/10"
              >
                <div class="flex flex-wrap items-center gap-2 text-sm">
                  <span class={[
                    "size-2 rounded-full",
                    if(r.online, do: "bg-success", else: "bg-base-content/30")
                  ]}></span>
                  <span class="font-medium">{r.name}</span>
                  <span class="text-xs text-base-content/60">
                    pool {r.pool} · {if r.online, do: "online", else: "offline"}{if r.session,
                      do: " · Claude session"}
                  </span>
                </div>
                <p :if={r.jobs == []} class="text-xs text-base-content/60">Idle</p>
                <.job_line :for={j <- r.jobs} job={j} now={@now} />
              </li>
            </ul>
          </section>

          <section id="now-cards" class="space-y-2">
            <h2 class="section-title">
              In progress <span class="badge badge-ghost badge-sm">{@snap.counts.in_progress}</span>
            </h2>
            <.empty_state
              :if={@snap.in_progress == []}
              id="now-no-cards"
              compact
              icon="hero-rectangle-stack"
              title="Nothing in progress"
            >
              No open card sits in an in-progress list on this board or beneath it.
            </.empty_state>
            <ul class="space-y-2">
              <li
                :for={c <- @snap.in_progress}
                id={"now-card-#{c.id}"}
                class="space-y-1 rounded-xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/10"
              >
                <div class="flex flex-wrap items-center gap-2 text-sm">
                  <.link navigate={~p"/boards/#{c.board_id}/cards/#{c.id}"} class="link min-w-0">
                    #{c.id} {c.title}
                  </.link>
                  <span :if={c.holds} class={["badge badge-sm", hold_class(c.holds)]}>
                    {hold_label(c.holds)}
                  </span>
                  <span :if={c.loop} class="badge badge-ghost badge-sm gap-1">
                    <.icon name="hero-cpu-chip" class="size-3" /> {CardState.loop_label(c.loop)}
                  </span>
                </div>
                <p class="text-xs text-base-content/60">
                  <span :if={c.parent}>
                    under
                    <.link
                      navigate={~p"/boards/#{c.parent.board_id}/cards/#{c.parent.id}"}
                      class="link"
                    >#{c.parent.id} {c.parent.title}</.link>
                    ·
                  </span>
                  {c.board} › {c.list}
                  <span :if={c.age}>· {Pulse.duration(c.age)} there</span>
                </p>
                <p :if={c.state} class="text-xs text-base-content/70">{c.state}</p>
              </li>
            </ul>
          </section>

          <section id="now-queued" class="space-y-2">
            <h2 class="section-title">
              Queued <span class="badge badge-ghost badge-sm">{@snap.counts.queued}</span>
            </h2>
            <.empty_state
              :if={@snap.queued == []}
              id="now-no-queued"
              compact
              icon="hero-queue-list"
              title="Nothing queued"
            >
              No job is waiting for a runner.
            </.empty_state>
            <ul class="space-y-2">
              <li
                :for={j <- @snap.queued}
                id={"now-queued-#{j.id}"}
                class="space-y-1 rounded-xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/10"
              >
                <.job_line job={j} now={@now} />
                <p class="text-xs text-base-content/60">
                  pool {j.pool}<span :if={j.held}> · Held: {j.held}</span>
                </p>
              </li>
            </ul>
          </section>
        </.page>
      </div>
    </Layouts.app>
    """
  end
end
