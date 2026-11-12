defmodule SlipdockWeb.BoardLive.ActivityComponent do
  @moduledoc """
  The board's activity log. Nothing here changes anything; the component
  only keeps the list current, and only for a reader of the board it is
  given.

  Every entry names who did it (#1735) — a person's avatar and name, the
  agent, "Automation: <rule>", "Email" or "System" — and the entries are
  grouped by day on the reader's calendar ("Today", "Yesterday", then the
  date). The first page is 50 entries; more load as the list scrolls.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Access, Boards}
  alias Slipdock.Accounts.User
  alias SlipdockWeb.Dates

  @page 50

  # Sent by the board when something on it changed: the newest entries again,
  # down to the oldest showing.
  @impl true
  def update(%{refresh: true}, socket) do
    if socket.assigns.reader? do
      {entries, more?} =
        Boards.ActivityLog.page_activities(
          socket.assigns.board.id,
          shown(socket, socket.assigns.board)
        )

      {:ok, assign(socket, activities: entries, more?: more?)}
    else
      {:ok, socket}
    end
  end

  # The board re-renders the panel whenever it changes, too.
  def update(%{board: board, current_user: user} = assigns, socket) do
    reader? = Access.can_read?(Access.board_permission(user, board))

    {activities, more?} =
      if reader?,
        do: Boards.ActivityLog.page_activities(board.id, shown(socket, board)),
        else: {[], false}

    {:ok,
     assign(socket,
       board: board,
       reader?: reader?,
       close_path: assigns.close_path,
       activities: activities,
       more?: more?
     )}
  end

  # What to load: a page, or everything down to the oldest entry showing, so
  # a reader who has scrolled back keeps their place.
  defp shown(%{assigns: %{board: %{id: id}, activities: [_ | _] = shown}}, %{id: id}),
    do: [down_to: List.last(shown)]

  defp shown(_socket, _board), do: [limit: @page]

  @impl true
  def handle_event("load_more", _params, socket) do
    %{activities: shown, more?: more?, reader?: reader?} = socket.assigns

    if reader? and more? and shown != [] do
      {entries, more?} =
        Boards.ActivityLog.page_activities(socket.assigns.board.id,
          limit: @page,
          before: List.last(shown)
        )

      {:noreply, assign(socket, activities: shown ++ entries, more?: more?)}
    else
      {:noreply, socket}
    end
  end

  @doc """
  `entries` (newest first) in runs of one day each on the reader's calendar:
  `[{label, entries}]`, labelled "Today", "Yesterday", then the date
  (`SlipdockWeb.Dates.weekday/2`). `opts` take `:zone` and `:now`, as
  `SlipdockWeb.Dates` does; the process's zone and the clock otherwise.
  """
  def by_day(entries, opts \\ []) do
    zone = Keyword.get_lazy(opts, :zone, &Dates.zone/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    today = local_date(now, zone)

    entries
    |> Enum.chunk_by(&local_date(&1.inserted_at, zone))
    |> Enum.map(fn [first | _] = run ->
      {day_label(local_date(first.inserted_at, zone), today, zone: zone, now: now), run}
    end)
  end

  defp local_date(%NaiveDateTime{} = at, zone),
    do: at |> DateTime.from_naive!("Etc/UTC") |> local_date(zone)

  defp local_date(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _} -> DateTime.to_date(at)
    end
  end

  defp day_label(day, today, opts) do
    case Date.diff(today, day) do
      0 -> "Today"
      1 -> "Yesterday"
      _ -> Dates.weekday(day, opts)
    end
  end

  @doc """
  Who an entry names: `%{kind:, name:, user:}`. A person whose account is
  gone keeps the name they had; an entry from before actors were recorded
  is "Someone".
  """
  def actor(%{actor_kind: "person"} = a) do
    case loaded_user(a) do
      %User{} = user ->
        %{kind: "person", name: User.display_name(user), user: user}

      nil ->
        name = a.actor_name || "A deleted user"
        %{kind: "person", name: name, user: nil, deleted: true, snapshot: a.actor_name}
    end
  end

  def actor(%{actor_kind: "email"} = a) do
    user = loaded_user(a)
    by = (user && User.display_name(user)) || a.actor_name
    %{kind: "email", name: if(by, do: "Email from #{by}", else: "Email"), user: user}
  end

  def actor(%{actor_kind: "agent"} = a), do: %{kind: "agent", name: a.actor_name || "Agent"}

  def actor(%{actor_kind: "automation"} = a) do
    name = if a.actor_name, do: "Automation: #{a.actor_name}", else: "Automation"
    %{kind: "automation", name: name}
  end

  def actor(%{actor_kind: "system"}), do: %{kind: "system", name: "System"}
  def actor(_), do: %{kind: nil, name: "Someone"}

  defp loaded_user(%{user: %User{} = user}), do: user
  defp loaded_user(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-activity">
      <.activity_modal
        board={@board}
        activities={@activities}
        more?={@more?}
        close_path={@close_path}
        myself={@myself}
      />
    </div>
    """
  end

  attr :board, :any, required: true
  attr :activities, :list, required: true
  attr :more?, :boolean, required: true
  attr :close_path, :string, required: true
  attr :myself, :any, required: true

  defp activity_modal(assigns) do
    assigns = assign(assigns, :days, by_day(assigns.activities))

    ~H"""
    <.modal id="activity-modal" on_close={JS.patch(@close_path)} size="md">
      <div class="space-y-4 p-6">
        <h2 class="flex items-center gap-2 section-title">
          <.icon name="hero-bolt" class="size-5 text-warning" /> Activity
        </h2>
        <.empty_state
          :if={@activities == []}
          id="activity-empty"
          icon="hero-bolt"
          title="Nothing has happened yet"
          compact
        >
          Cards added, moved and finished on this board are logged here.
        </.empty_state>
        <div id="activity-scroll" class="max-h-[60vh] overflow-y-auto kanban-scroll pr-1">
          <div
            id="activity-days"
            class="space-y-3"
            phx-viewport-bottom={@more? && "load_more"}
            phx-target={@myself}
          >
            <section :for={{label, entries} <- @days} data-role="activity-day">
              <h3 class="sticky top-0 z-10 bg-base-100 px-2 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/50">
                {label}
              </h3>
              <ol class="space-y-1">
                <.entry :for={a <- entries} activity={a} today={label == "Today"} />
              </ol>
            </section>
          </div>
          <button
            :if={@more?}
            id="activity-more"
            type="button"
            class="btn btn-ghost btn-sm mt-2 w-full"
            phx-click="load_more"
            phx-target={@myself}
          >
            Load more
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  attr :activity, :any, required: true
  attr :today, :boolean, default: false

  # Today's entries say how long ago ("5 min ago"); an earlier day's give the
  # time on the clock, its day being the heading above.
  defp entry(assigns) do
    a = assigns.activity
    assigns = assign(assigns, actor: actor(a), icon: activity_icon(a.kind, a.message))

    ~H"""
    <li
      id={"activity-#{@activity.id}"}
      class="flex items-start gap-3 rounded-lg px-2 py-1.5 hover:bg-base-200/60"
      data-actor-kind={@actor.kind || "unknown"}
    >
      <.actor_badge actor={@actor} />
      <div class="min-w-0 flex-1">
        <p class="text-sm">
          <span
            class="font-medium"
            data-role="activity-actor"
            title={@actor[:deleted] && "This account has been deleted"}
          >
            {@actor.name}
          </span>
          {@activity.message}
        </p>
        <p class="flex items-center gap-1 text-xs text-base-content/50">
          <span data-role="activity-kind" data-icon={@icon} class="inline-flex">
            <.icon name={@icon} class="size-3.5" />
          </span>
          <.timestamp :if={@today} at={@activity.inserted_at} />
          <time
            :if={!@today}
            datetime={DateTime.to_iso8601(@activity.inserted_at)}
            title={Dates.exact(@activity.inserted_at)}
            data-role="timestamp"
          >
            {Dates.time(@activity.inserted_at)}
          </time>
        </p>
      </div>
    </li>
    """
  end

  attr :actor, :map, required: true

  # A person wears their avatar (the same one as on cards; a deleted user's
  # from the name they had); anyone else a round badge with what they are.
  defp actor_badge(%{actor: %{kind: "person"} = actor} = assigns) do
    snapshot = actor[:snapshot]
    assigns = assign(assigns, :user, actor.user || (snapshot && %User{name: snapshot}))

    ~H"""
    <.avatar user={@user} size="sm" class="mt-0.5" />
    """
  end

  defp actor_badge(assigns) do
    assigns = assign(assigns, :icon, badge_icon(assigns.actor.kind))

    ~H"""
    <span class="mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full bg-base-200 text-base-content/60">
      <.icon name={@icon} class="size-3.5" />
    </span>
    """
  end

  defp badge_icon("email"), do: "hero-envelope"
  defp badge_icon("agent"), do: "hero-cpu-chip"
  defp badge_icon("automation"), do: "hero-bolt"
  defp badge_icon("system"), do: "hero-cog-6-tooth"
  defp badge_icon(_), do: "hero-user"
end
