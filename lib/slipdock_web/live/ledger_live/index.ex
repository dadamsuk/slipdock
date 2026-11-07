defmodule SlipdockWeb.LedgerLive.Index do
  @moduledoc """
  A board tree's Ledger page (#1948, see `Slipdock.Ledger`): what shipped on
  the board and the boards beneath it since a time, a line per card with its
  evidence, grouped by day, for a person to skim instead of approving each
  card.

  It lists what `GET /api/boards/:board/ledger` lists. `?since=` (days, a
  date or an ISO time) is kept in the URL; without it the window starts at
  07:00 yesterday in the board's timezone. Each line's **Look closer** opens
  the card's panel at its chat. Anyone who can read the board can look; the
  page writes nothing.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Boards, Ledger, Palette}
  alias Slipdock.Boards.Board
  alias SlipdockWeb.API.LedgerJSON
  alias SlipdockWeb.Dates

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with %Board{} = board <- Boards.get_board(id),
         true <- Access.can_read?(Access.board_permission(user, board)) do
      {:ok, assign(socket, board: board, page_title: "Ledger · #{board.name}", page_jumps: [])}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    since = String.trim(params["since"] || "")
    board = socket.assigns.board

    {ledger, error} =
      case Ledger.since(board, since: since) do
        {:ok, ledger} -> {ledger, nil}
        {:error, message} -> {elem(Ledger.since(board), 1), message}
      end

    {:noreply,
     assign(socket,
       ledger: ledger,
       since: since,
       since_error: error,
       since_form: to_form(%{"since" => since}, as: :ledger),
       zone: ledger.timezone
     )}
  end

  @impl true
  def handle_event("since", %{"ledger" => %{"since" => since}}, socket) do
    query = if String.trim(since) == "", do: "", else: "?" <> URI.encode_query(since: since)
    {:noreply, push_patch(socket, to: "/boards/#{socket.assigns.board.id}/ledger" <> query)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Times are the board's, as its days are (`Ledger` groups by them).
  defp when_text(at, zone), do: Dates.datetime(at, zone: zone)
  defp time_text(at, zone), do: Dates.time(at, zone: zone)
  defp day_text(date), do: Dates.weekday(date)

  # Where the time went: the three biggest phases, with how long each took.
  defp phases_text(%{phases: phases}) when map_size(phases) == 0, do: nil

  defp phases_text(%{phases: phases}) do
    phases
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(3)
    |> Enum.map_join(" · ", fn {phase, s} -> "#{phase_name(phase)} #{duration(s)}" end)
  end

  defp phase_name(phase), do: phase |> to_string() |> String.replace("_", " ")

  @doc false
  def duration(s) when s < 60, do: "#{s}s"
  def duration(s) when s < 3600, do: "#{div(s, 60)}m"
  def duration(s) when s < 86_400, do: "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"
  def duration(s), do: "#{div(s, 86_400)}d #{rem(div(s, 3600), 24)}h"

  defp event_class("deployed"), do: "badge-success"
  defp event_class("merged"), do: "badge-info"
  defp event_class("accepted"), do: "badge-primary"
  defp event_class(_), do: "badge-ghost"

  defp acceptor_text(nil), do: "not verified"
  defp acceptor_text(%{kind: "person", name: name}), do: "accepted by #{name}"
  defp acceptor_text(%{kind: _, name: name}), do: "accepted by #{name}"

  attr :item, :map, required: true
  attr :board, :map, required: true
  attr :zone, :string, required: true

  defp ledger_line(assigns) do
    ~H"""
    <li
      id={"ledger-#{@item.card.id}"}
      class="space-y-1 rounded-xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/10"
    >
      <div class="flex flex-wrap items-center gap-2 text-sm">
        <span class="text-base-content/50">#{@item.card.id}</span>
        <span class="font-medium" data-role="title">{@item.card.title}</span>
        <span
          :for={e <- @item.events}
          class={["badge badge-sm", event_class(e)]}
          data-role="event"
        >
          {e}
        </span>
        <span :if={@item.subcards} class="badge badge-sm badge-outline" data-role="subcards">
          {@item.subcards.done}/{@item.subcards.total} subcards · {@item.subcards.on_ledger} here
        </span>
        <span class="ml-auto text-xs text-base-content/60">{time_text(@item.at, @zone)}</span>
        <a
          href={LedgerJSON.card_url(@item.card)}
          id={"ledger-look-#{@item.card.id}"}
          class="btn btn-ghost btn-xs"
          title="Open the card with its chat"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4" /> Look closer
        </a>
      </div>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
        <span data-role="acceptor">{acceptor_text(@item.accepted_by)}</span>
        <span
          :if={@item.audit}
          class={if @item.audit.verdict == "agrees", do: "text-success", else: "text-error"}
          data-role="audit"
        >
          audit {@item.audit.verdict}
        </span>
        <a :if={@item.pr} href={@item.pr} class="link" data-role="pr" target="_blank" rel="noopener">
          pull request
        </a>
        <span :for={d <- @item.deploys} data-role="deploy">
          deployed to {d.environment} ({String.slice(d.sha || "", 0, 7)})
        </span>
        <span :if={phases_text(@item.lead_time)} data-role="lead-time">
          {duration(@item.lead_time.seconds)}: {phases_text(@item.lead_time)}
        </span>
      </div>
      <p :if={@item.evidence} class="text-sm" data-role="evidence">{@item.evidence}</p>
      <p :if={@item.should_broken != []} class="text-xs text-warning" data-role="should">
        should rules missed: {Enum.map_join(@item.should_broken, ", ", & &1.id)}
      </p>
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

      <div id="ledger-shell" class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard" class="space-y-6">
          <.page_header id="ledger-title" title="Ledger">
            <:meta>
              What shipped on this board and the boards beneath it since {when_text(
                @ledger.since,
                @zone
              )}: who accepted it, its evidence, the should rules it missed and where its time went.
            </:meta>
          </.page_header>

          <.form
            for={@since_form}
            id="ledger-since"
            phx-change="since"
            phx-submit="since"
            class="grid grid-cols-2 gap-2 sm:grid-cols-4"
          >
            <.input
              field={@since_form[:since]}
              type="text"
              label="Since"
              placeholder="7:00 yesterday"
              phx-debounce="400"
            />
          </.form>

          <.callout :if={@since_error} id="ledger-since-error" kind={:error}>
            {@since_error}
          </.callout>

          <.empty_state
            :if={@ledger.days == []}
            id="ledger-empty"
            icon="hero-document-check"
            title="Nothing shipped"
          >
            Cards appear here when they are completed, accepted, merged or deployed.
          </.empty_state>

          <section
            :for={day <- @ledger.days}
            id={"ledger-day-#{Date.to_iso8601(day.date)}"}
            class="space-y-2"
          >
            <h2 class="section-title">
              {day_text(day.date)} <span class="badge badge-ghost badge-sm">{length(day.items)}</span>
            </h2>
            <ul class="space-y-2">
              <.ledger_line :for={item <- day.items} item={item} board={@board} zone={@zone} />
            </ul>
          </section>
        </.page>
      </div>
    </Layouts.app>
    """
  end
end
