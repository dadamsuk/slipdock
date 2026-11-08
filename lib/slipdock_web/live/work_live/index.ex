defmodule SlipdockWeb.WorkLive.Index do
  @moduledoc """
  My work: every card assigned to the signed-in user, across all boards and
  levels, grouped by when it is due, each with the path of cards above it.

  It opens with "Waiting on you" (#1118): everything that needs this person,
  oldest first (`Slipdock.Work.waiting_on_me/2`), with a wait's answers
  right there. The header's count is the length of that section.

  What the person took off it is never silent (#2069): a line counts the
  items dismissed and the boards muted, the × on a row dismisses it (held
  on its cause), and the dismissed items and muted boards open below with
  Undo and Unmute.

  Open cards with no due date aren't listed (#2099): the page is for what is
  coming due. The header says how many there are, so none is hidden
  silently, and a completed one still shows under Show completed. The AI
  chat's source keeps every section, as do the API, CLI and MCP.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents
  alias Slipdock.{Access, Actor, Boards, Pulse, Work}
  alias SlipdockWeb.BoardNotices

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> BoardNotices.subscribe()
     |> assign(
       page_title: "My work",
       show_done: false,
       show_hidden: false,
       # `?board=` (#2095): kept to one board's tree, from its header.
       board: nil,
       ai?: Slipdock.AI.configured?(socket.assigns.current_user)
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    board = readable_board(socket.assigns.current_user, params["board"])

    if board == socket.assigns.board,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(board: board) |> load()}
  end

  # A board the reader can't see, or no board, keeps nothing out.
  defp readable_board(_user, id) when id in [nil, ""], do: nil

  defp readable_board(user, id) do
    with {n, ""} <- Integer.parse(id),
         %Slipdock.Boards.Board{} = board <- Slipdock.Repo.get(Slipdock.Boards.Board, n),
         true <- Access.can_read?(Access.board_permission(user, board)) do
      board
    else
      _ -> nil
    end
  end

  defp load(socket) do
    user = socket.assigns.current_user
    opts = if b = socket.assigns.board, do: [board_id: b.id], else: []
    cards = Work.assigned(user, nil, opts)
    open = Enum.reject(cards, &(&1.section == :done))
    sections = Work.group(cards, socket.assigns.show_done)

    %{items: waiting} = found = Work.waiting(user, opts)

    assign(socket,
      waiting: waiting,
      dismissed: found.dismissed,
      muted_count: found.muted,
      muted_boards: Work.muted_boards(user),
      # The header's number is this section's length, never a second count;
      # kept to a board, the header still counts everything.
      waiting_count: if(opts == [], do: length(waiting), else: Work.waiting_count(user)),
      now: DateTime.utc_now(),
      # The chat reads every section; the page leaves out :none (#2099).
      sections: sections,
      listed: Enum.reject(sections, &(&1.key == :none)),
      undated_count: Enum.count(open, &(&1.section == :none)),
      open_count: length(open),
      done_count: length(cards) - length(open)
    )
  end

  @impl true
  def handle_info({:boards_changed}, socket) do
    Boards.drain_boards_changed()
    socket = BoardNotices.resubscribe(socket)
    {:noreply, load(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_done", _, socket) do
    {:noreply, socket |> assign(show_done: not socket.assigns.show_done) |> load()}
  end

  def handle_event("toggle_complete", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    card = Boards.get_card!(id)

    if Access.can_write?(Access.card_permission(user, card)) do
      Boards.toggle_completed(card)
      {:noreply, load(socket)}
    else
      {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  # Off my own list (#2069): held on the item's cause, so a new one shows.
  def handle_event("dismiss_waiting", %{"card" => id}, socket) do
    case Work.dismiss(socket.assigns.current_user, Boards.get_card!(id)) do
      {:ok, item} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, "Dismissed “#{item.card.title}”. A new reason brings it back.")}

      {:error, :not_waiting} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("undismiss_waiting", %{"card" => id}, socket) do
    Work.undismiss(socket.assigns.current_user, Boards.get_card!(id))
    {:noreply, load(socket)}
  end

  def handle_event("unmute_waiting", %{"board" => id}, socket) do
    user = socket.assigns.current_user

    socket.assigns.muted_boards
    |> Enum.filter(&(to_string(&1.id) == id))
    |> Enum.each(&Work.unmute(user, &1))

    {:noreply, load(socket)}
  end

  def handle_event("toggle_hidden", _, socket),
    do: {:noreply, assign(socket, show_hidden: not socket.assigns.show_hidden)}

  # A wait answered from here: by choice button or in words.
  def handle_event("answer_wait", %{"card" => id} = params, socket) do
    user = socket.assigns.current_user
    card = Boards.get_card!(id)

    attrs = %{
      "choice" => params["choice"],
      "answer" => get_in(params, ["wait", "answer"]) || params["answer"]
    }

    with true <- Access.can_write?(Access.card_permission(user, card)),
         {:ok, _} <- Boards.answer_wait(card, Actor.web(user), attrs) do
      # `load/1` counts the header's number again, from the same section.
      {:noreply, load(socket)}
    else
      false -> {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "That answer couldn't be saved.")}
    end
  end

  # "3 waiting · 2 dismissed · 1 board muted" (#2069).
  defp hidden_line(waiting, dismissed, boards) do
    n = length(boards)

    [
      "#{length(waiting)} waiting",
      dismissed != [] && "#{length(dismissed)} dismissed",
      n > 0 && "#{n} #{if n == 1, do: "board", else: "boards"} muted"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp undated_line(1), do: "1 has no due date and isn't listed."
  defp undated_line(n), do: "#{n} have no due date and aren't listed."

  defp since(item, now), do: Pulse.duration(max(DateTime.diff(now, item.since), 0))

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
      nav_active={:work}
    >
      <:actions>
        <button
          :if={@ai?}
          type="button"
          class="btn btn-ghost btn-sm btn-square"
          title="Chat about your work with AI"
          aria-label="Chat about your work with AI"
          phx-click="toggle"
          phx-target="#page-ai"
        >
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" />
        </button>
      </:actions>
      <.live_component
        :if={@ai?}
        module={SlipdockWeb.AIChatComponent}
        id="page-ai"
        layout="drawer"
        title="Chat about my work"
        source={%{kind: :work, sections: @sections, user: @current_user}}
        current_user={@current_user}
        can_write={true}
      />
      <div class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard">
          <.page_header title="My work">
            <:meta>
              {@open_count} open {if @open_count == 1, do: "card", else: "cards"} assigned to you, across every board and level.
              <span :if={@undated_count > 0} id="work-undated">
                {undated_line(@undated_count)}
              </span>
            </:meta>
            <:actions>
              <label class="flex cursor-pointer items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  class="toggle"
                  checked={@show_done}
                  phx-click="toggle_done"
                /> Show completed
                <span :if={@done_count > 0} class="badge badge-ghost badge-sm font-mono">
                  {@done_count}
                </span>
              </label>
            </:actions>
          </.page_header>

          <.callout :if={@board} id="work-board-filter" kind={:info} class="mb-4 text-sm">
            Kept to {@board.name} and the boards under it.
            <.link id="work-board-filter-clear" patch={~p"/work"} class="link ml-1">
              Show everything
            </.link>
          </.callout>

          <section
            :if={@waiting != [] or @dismissed != [] or @muted_boards != []}
            id="work-waiting"
            class="mb-8"
          >
            <h2 class="mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-warning">
              Waiting on you
              <span class="badge badge-ghost badge-sm font-mono">{length(@waiting)}</span>
            </h2>
            <%!-- The hiding is never silent (#2069). --%>
            <p
              :if={@dismissed != [] or @muted_boards != []}
              id="work-waiting-hidden"
              class="mb-2 flex flex-wrap items-center gap-x-1 text-xs text-base-content/60"
            >
              {hidden_line(@waiting, @dismissed, @muted_boards)}
              <button
                type="button"
                id="work-waiting-hidden-toggle"
                class="link link-hover ml-1"
                phx-click="toggle_hidden"
              >
                {if @show_hidden, do: "Hide", else: "Show"}
              </button>
            </p>
            <div :if={@show_hidden} id="work-waiting-hidden-list" class="mb-3 space-y-2 text-sm">
              <ul
                :if={@dismissed != []}
                id="work-dismissed"
                class="divide-y divide-base-300/60 overflow-hidden rounded-2xl bg-base-200/40 ring-1 ring-base-content/10"
              >
                <li
                  :for={item <- @dismissed}
                  id={"dismissed-card-#{item.card.id}"}
                  class="flex items-center gap-3 px-4 py-2"
                >
                  <div class="min-w-0 flex-1">
                    <.link
                      navigate={~p"/boards/#{item.card.board_id}/cards/#{item.card.id}"}
                      class="block truncate hover:underline"
                    >
                      {item.card.title}
                    </.link>
                    <p class="truncate text-xs text-base-content/50">
                      Dismissed · {item.text} · {Enum.join(item.path, " › ")}
                    </p>
                  </div>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="undismiss_waiting"
                    phx-value-card={item.card.id}
                  >
                    Undo
                  </button>
                </li>
              </ul>
              <ul
                :if={@muted_boards != []}
                id="work-muted"
                class="divide-y divide-base-300/60 overflow-hidden rounded-2xl bg-base-200/40 ring-1 ring-base-content/10"
              >
                <li
                  :for={board <- @muted_boards}
                  id={"muted-board-#{board.id}"}
                  class="flex items-center gap-3 px-4 py-2"
                >
                  <.icon name="hero-bell-slash" class="size-4 shrink-0 text-base-content/50" />
                  <.link
                    navigate={~p"/boards/#{board.id}"}
                    class="min-w-0 flex-1 truncate hover:underline"
                  >
                    {board.name}
                  </.link>
                  <span class="text-xs text-base-content/50">muted, its tree with it</span>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="unmute_waiting"
                    phx-value-board={board.id}
                  >
                    Unmute
                  </button>
                </li>
              </ul>
            </div>
            <ul
              :if={@waiting != []}
              class="divide-y divide-base-300/60 overflow-hidden rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10"
            >
              <li
                :for={item <- @waiting}
                id={"waiting-card-#{item.card.id}"}
                class="px-4 py-2.5 hover:bg-base-200/40"
              >
                <div class="flex items-center gap-3">
                  <.icon name="hero-hand-raised" class="size-5 shrink-0 text-warning" />
                  <div class="min-w-0 flex-1">
                    <.link
                      navigate={~p"/boards/#{item.card.board_id}/cards/#{item.card.id}"}
                      class="block truncate font-medium hover:underline"
                    >
                      {item.card.title}
                    </.link>
                    <p
                      class="truncate text-xs text-base-content/50"
                      title={Enum.join(item.path, " › ")}
                    >
                      {Enum.join(item.path, " › ")} · {item.card.column.name}
                    </p>
                  </div>
                  <span class="shrink-0 font-mono text-xs text-base-content/60">
                    {since(item, @now)}
                  </span>
                  <button
                    type="button"
                    id={"dismiss-waiting-#{item.card.id}"}
                    class="btn btn-ghost btn-xs btn-square shrink-0"
                    phx-click="dismiss_waiting"
                    phx-value-card={item.card.id}
                    title="Dismiss: off my list until the reason changes"
                    aria-label={"Dismiss #{item.card.title} from Waiting on you"}
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
                <p class="mt-1 pl-8 text-sm text-base-content/80">{item.text}</p>
                <div :if={item.wait} class="mt-2 flex flex-wrap items-center gap-2 pl-8">
                  <button
                    :for={{choice, n} <- Enum.with_index(item.wait.choices, 1)}
                    type="button"
                    class="btn btn-xs"
                    phx-click="answer_wait"
                    phx-value-card={item.card.id}
                    phx-value-choice={n}
                  >
                    {choice}
                  </button>
                  <form
                    id={"waiting-answer-#{item.card.id}"}
                    phx-submit="answer_wait"
                    class="flex min-w-0 flex-1 items-center gap-2"
                  >
                    <input type="hidden" name="card" value={item.card.id} />
                    <input
                      type="text"
                      name="wait[answer]"
                      placeholder="Answer…"
                      class="input field min-w-0 flex-1"
                      maxlength="4000"
                      required
                    />
                    <button type="submit" class="btn btn-primary btn-xs">Answer</button>
                  </form>
                </div>
              </li>
            </ul>
          </section>

          <%!-- Only undated cards assigned: say so, never "nothing" (#2099). --%>
          <.empty_state
            :if={@listed == []}
            id="work-empty"
            icon="hero-check-badge"
            title={
              if @undated_count > 0, do: "Nothing with a due date", else: "Nothing assigned to you"
            }
          >
            {if @undated_count > 0,
              do:
                "Every open card assigned to you has no due date, so none is listed. Give one a due date and it shows up here.",
              else: "Cards you are assigned to, on any board, show up here."}
          </.empty_state>

          <section :for={section <- @listed} id={"work-#{section.key}"} class="mb-8">
            <h2 class={[
              "mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide",
              section.tone || "text-base-content/60"
            ]}>
              {section.label}
              <span class="badge badge-ghost badge-sm font-mono">{length(section.items)}</span>
            </h2>
            <ul class="divide-y divide-base-300/60 overflow-hidden rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10">
              <li
                :for={%{card: card, path: path} <- section.items}
                id={"work-card-#{card.id}"}
                class={[
                  "flex items-center gap-3 px-4 py-2.5 hover:bg-base-200/40",
                  card.completed && "opacity-60"
                ]}
              >
                <button
                  type="button"
                  class={[
                    "shrink-0 rounded-full transition",
                    if(card.completed,
                      do: "text-success",
                      else: "text-base-content/25 hover:text-success"
                    )
                  ]}
                  phx-click="toggle_complete"
                  phx-value-id={card.id}
                  title={if card.completed, do: "Mark incomplete", else: "Mark complete"}
                >
                  <.icon
                    name={if card.completed, do: "hero-check-circle-solid", else: "hero-check-circle"}
                    class="size-5"
                  />
                </button>
                <span
                  :if={card.color}
                  class={["size-2 shrink-0 rounded-full", Slipdock.Palette.dot(card.color)]}
                ></span>
                <div class="min-w-0 flex-1">
                  <.link
                    navigate={~p"/boards/#{card.board_id}/cards/#{card.id}"}
                    class={[
                      "block truncate font-medium hover:underline",
                      card.completed && "text-base-content/50"
                    ]}
                  >
                    {card.title}
                  </.link>
                  <p class="truncate text-xs text-base-content/50" title={Enum.join(path, " › ")}>
                    {Enum.join(path, " › ")} · {card.column.name}
                  </p>
                </div>
                <span :if={card.tags != []} class="hidden items-center gap-1 sm:flex">
                  <.tag_chip :for={tag <- card.tags} tag={tag} size="xs" />
                </span>
                <.flag_icon :for={flag <- card.flags} flag={flag} class="size-3.5" />
                <.subcards_badge card={card} />
                <.priority_badge priority={card.priority} />
                <.schedule_badges card={card} />
              </li>
            </ul>
          </section>
        </.page>
      </div>
    </Layouts.app>
    """
  end
end
