defmodule SlipdockWeb.BoardLive.Visualise do
  @moduledoc """
  A board's Visualise page (#1185): one scrolling page of how work moves
  through the board, how fast it is finished, how its runners are doing and
  its delivery (DORA) numbers. Reached from the board's view menu, beside
  Timeline and Prioritise, and left out of it on a simple board as they are.

  Everything is worked out when the page asks, from `Slipdock.Pulse`,
  `Slipdock.Flow`, `Slipdock.RunnerStats` and `Slipdock.Dora`; nothing is
  stored. `?days=7|30|90` (30 unless given) is the trend window, kept in the
  URL so a link reproduces the view. The Pulse tiles keep Pulse's own 7
  days, and DORA its own 30, and each says so.

  Anyone who can read the whole board can look; a board shared only as a
  saved view, or not at all, sends them home as the board page does. It
  follows the board, its runners' jobs and its deploys live, recomputing at
  most once every couple of seconds however busy the board is.
  """
  use SlipdockWeb, :live_view

  import Ecto.Query
  import SlipdockWeb.BoardLive.VisualiseComponents
  import SlipdockWeb.BoardLive.VisualiseCharts, only: [trends: 1]
  import SlipdockWeb.SlipdockComponents, only: [view_tabs: 1]

  alias Slipdock.{Access, Boards, CardState, Dora, Flow, Palette, Pulse, Repo}
  alias Slipdock.Boards.{Board, Card, CardMove, Column, Wait}

  @refresh_ms 2_000

  @doc "How long the page waits after a change before working its numbers out again."
  def refresh_ms, do: @refresh_ms

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with %Board{} = board <- Repo.get(Board, SlipdockWeb.Params.id(id) || 0),
         perm = Access.board_permission(user, board),
         true <- Access.can_read?(perm) and perm != :view do
      board = Repo.preload(board, [:saved_views])

      if connected?(socket) do
        Boards.subscribe(board.id)
        Slipdock.Runners.subscribe_board(board.id)
        Phoenix.PubSub.subscribe(Slipdock.PubSub, Slipdock.Deployments.topic(board))
      end

      {:ok,
       assign(socket,
         board: board,
         page_title: "Visualise · #{board.name}",
         marks: Slipdock.Favourites.marks(user),
         meetings: meetings_tab(user, board),
         page_jumps: [],
         refresh: nil
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: "/")}
    end
  end

  defp meetings_tab(user, board) do
    case Slipdock.Meetings.presence(user, board) do
      :none -> :none
      _ -> :tab
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(days: Flow.clamp_days(params["days"])) |> load()}
  end

  @impl true
  def handle_event("window", %{"days" => days}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/boards/#{socket.assigns.board}/visualise?days=#{Flow.clamp_days(days)}"
     )}
  end

  # Any change to the board, its runners' jobs or its deploys: once the
  # board has been quiet for a moment, work everything out again.
  @impl true
  def handle_info(:refresh, socket), do: {:noreply, socket |> assign(refresh: nil) |> load()}

  def handle_info(message, socket)
      when elem(message, 0) in [:board_changed, :jobs_changed, :deployment] do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp schedule_refresh(%{assigns: %{refresh: ref}} = socket) when is_reference(ref), do: socket

  defp schedule_refresh(socket),
    do: assign(socket, refresh: Process.send_after(self(), :refresh, @refresh_ms))

  defp load(socket) do
    %{board: board} = socket.assigns
    columns = Repo.all(from c in Column, where: c.board_id == ^board.id, order_by: :position)
    board = %{Repo.reload!(board) | saved_views: board.saved_views}

    dora =
      case Dora.for_board(board) do
        {:ok, report} -> report
        {:error, :off} -> nil
      end

    pulse = Pulse.for_board(board)
    usual = Map.new(pulse.lists, &{&1.id, &1.usual_stay})
    counts = counts(board)

    assign(socket,
      board: board,
      columns: columns,
      pulse: pulse,
      dora: dora,
      doing: Enum.find(columns, &(&1.category == "doing")),
      last_answer: last_answer(board),
      lists: lists(board, columns, pulse, counts),
      history: Flow.history(board, days: socket.assigns.days),
      mix: work_mix(board, columns, socket.assigns.days),
      runners: Slipdock.RunnerStats.for_board(board, days: socket.assigns.days),
      aging: aging(board, columns, usual),
      outside:
        for(
          c <- columns,
          is_nil(c.category),
          (n = Map.get(counts, c.id, 0)) > 0,
          do: {c.name, n}
        )
    )
  end

  # Cards in each list now: not archived, never a stand-in.
  defp counts(board) do
    Repo.all(
      from c in Card,
        where: c.board_id == ^board.id and is_nil(c.archived_at) and is_nil(c.stand_in_for_id),
        group_by: c.column_id,
        select: {c.column_id, count(c.id)}
    )
    |> Map.new()
  end

  # Pulse's lists, with how many cards each holds now, its WIP limit, and
  # for a done list how many were archived from it in 7 days.
  defp lists(board, columns, pulse, counts) do
    since = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    archived =
      Repo.all(
        from m in CardMove,
          where: m.board_id == ^board.id and m.kind == "archived" and m.inserted_at >= ^since,
          group_by: m.from_column_id,
          select: {m.from_column_id, count(m.id)}
      )
      |> Map.new()

    limits = Map.new(columns, &{&1.id, &1.wip_limit})

    Enum.map(pulse.lists, fn l ->
      Map.merge(l, %{
        count: Map.get(counts, l.id, 0),
        wip_limit: limits[l.id],
        archived_7d: Map.get(archived, l.id, 0)
      })
    end)
  end

  # Tag counts over the cards in the board's done lists: those still there,
  # and those archived from them that were completed in the window. Every
  # tag on the board has a row, most used first, unused at the bottom.
  @doc false
  def work_mix(board, columns, days) do
    done = for c <- columns, c.category == "done", do: c.id
    since = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

    cards =
      Repo.all(
        from c in Card,
          where:
            c.column_id in ^done and is_nil(c.stand_in_for_id) and
              (is_nil(c.archived_at) or c.completed_at >= ^since),
          preload: :tags
      )

    counts = cards |> Enum.flat_map(& &1.tags) |> Enum.frequencies_by(& &1.id)

    %{
      total: length(cards),
      untagged: Enum.count(cards, &(&1.tags == [])),
      tags:
        board
        |> Board.root_id()
        |> Boards.list_tags()
        |> Enum.map(&%{tag: &1, count: Map.get(counts, &1.id, 0)})
        |> Enum.sort_by(&{-&1.count, String.downcase(&1.tag.name)})
    }
  end

  # The open cards in the doing lists and the ready list, oldest in their
  # list first, with `Slipdock.CardState`'s age, usual stay and driver.
  defp aging(board, columns, usual) do
    ready = Flow.ready_list(columns)
    ids = for c <- columns, c.category == "doing" or (ready && c.id == ready.id), do: c.id
    names = Map.new(columns, &{&1.id, &1.name})

    Repo.all(
      from c in Card,
        where:
          c.column_id in ^ids and is_nil(c.archived_at) and is_nil(c.stand_in_for_id) and
            not c.completed,
        preload: [:tags, wait: ^from(w in Wait, where: is_nil(w.closed_at))]
    )
    |> CardState.put(board, columns: columns, usual: usual)
    |> Enum.map(fn card ->
      %{
        card: card,
        list: names[card.column_id],
        age: card.state.age,
        usual: card.state.usual,
        stuck: card.state.stuck,
        driver: card.state.driver
      }
    end)
    |> Enum.sort_by(&(&1.age || 0), :desc)
  end

  # How long the board's most recently answered wait took to answer.
  defp last_answer(board) do
    Repo.one(
      from w in Wait,
        join: c in Card,
        on: c.id == w.card_id,
        where: c.board_id == ^board.id and w.close_reason == "answered",
        order_by: [desc: w.closed_at, desc: w.id],
        limit: 1,
        select: {w.inserted_at, w.closed_at}
    )
    |> case do
      {opened, closed} -> DateTime.diff(closed, opened)
      nil -> nil
    end
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
        <nav class="flex min-w-0 items-center gap-1 text-sm">
          <.link
            navigate={~p"/boards/#{@board}"}
            class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
          >
            <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
            <span class="truncate font-semibold">{@board.name}</span>
          </.link>
        </nav>
      </:subnav>

      <div id="visualise-shell" class="flex h-full flex-col bg-base-200">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-2 border-b border-base-300 bg-base-100/70 px-3 py-2 text-sm">
          <.view_tabs
            board={@board}
            mode={:visualise}
            view={nil}
            marks={@marks}
            meetings={@meetings}
          />
        </div>

        <div class="kanban-scroll min-h-0 flex-1 overflow-y-auto">
          <div id="visualise" class="mx-auto max-w-[1360px] space-y-4 p-3 sm:p-6">
            <div class="flex flex-wrap items-end justify-between gap-3">
              <div class="min-w-0">
                <h1 class="text-2xl font-bold">Visualise</h1>
                <p class="truncate text-xs text-base-content/60">{@board.name}</p>
              </div>
              <.window_switch days={@days} />
            </div>

            <.pulse_section
              pulse={@pulse}
              dora={@dora}
              doing={@doing}
              last_answer={@last_answer}
            />

            <.flow_section lists={@lists} />

            <.trends history={@history} />

            <div id="visualise-pair" class="grid gap-4 lg:grid-cols-2">
              <.aging_section board={@board} aging={@aging} outside={@outside} />
              <.mix_section mix={@mix} days={@days} />
            </div>

            <.runners_section board={@board} stats={@runners} />

            <.dora_section board={@board} dora={@dora} cycle_p50={@pulse.time_to_done.p50} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
