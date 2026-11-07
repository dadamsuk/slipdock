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

  The layout (#2013): each line reads as a short document (the title, the
  evidence as a sentence, then the details in aligned rows), and its lead
  time is drawn as a bar split into `Slipdock.LeadTime`'s phases. A bar's
  length is its lead time on a log scale from a minute to 30 days
  (`bar_width/1`), so a ten-minute fix and a three-day feature are both
  readable on one page; its segments split that length by each phase's
  share. Working phases are solid, waiting phases hatched (the palette and
  hatching are in `assets/css/views/ledger.css`, validated with the dataviz
  skill's checker, light and dark). Each segment is focusable and its
  tooltip gives the exact time, so a tap shows it on a phone. Each day's
  heading says how many shipped, the median lead time and where the day's
  time went.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Boards, LeadTime, Ledger, Palette, Profiles}
  alias Slipdock.Boards.Board
  alias SlipdockWeb.API.LedgerJSON
  alias SlipdockWeb.Dates

  # The log scale: a minute at its shortest, 30 days at its longest.
  @scale_min 60
  @scale_max 30 * 86_400
  # The scale's marks, drawn on every track so the bars line up.
  @ticks [{"1 h", 3600}, {"1 day", 86_400}, {"1 week", 7 * 86_400}]

  @waiting ~w(backlog waiting_for_runner waiting_on_person verification_wait)a

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with %Board{} = board <- Boards.get_board(id),
         true <- Access.can_read?(Access.board_permission(user, board)) do
      {:ok,
       assign(socket,
         board: board,
         tiers: if(board.profiles, do: Profiles.board_tiers(board), else: %{}),
         page_title: "Ledger · #{board.name}",
         page_jumps: []
       )}
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

  @doc false
  def duration(s) when s < 60, do: "#{s}s"
  def duration(s) when s < 3600, do: "#{div(s, 60)}m"
  def duration(s) when s < 86_400, do: "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"
  def duration(s), do: "#{div(s, 86_400)}d #{rem(div(s, 3600), 24)}h"

  @doc false
  # A phase's name as people read it.
  def phase_name(:waiting_for_runner), do: "Waiting for a runner"
  def phase_name(:waiting_on_person), do: "Waiting on a person"
  def phase_name(:verification_wait), do: "Waiting for verification"
  def phase_name(:ci), do: "CI"
  def phase_name(phase), do: phase |> to_string() |> String.capitalize()

  @doc false
  def waiting?(phase), do: Enum.member?(@waiting, phase)

  @doc false
  # How long a bar is, as a % of its track: its lead time on the log scale,
  # never under 4% so a minute still shows.
  def bar_width(seconds) when is_integer(seconds) and seconds > 0 do
    s = seconds |> max(@scale_min) |> min(@scale_max)
    span = :math.log10(@scale_max) - :math.log10(@scale_min)
    share = (:math.log10(s) - :math.log10(@scale_min)) / span
    Float.round(max(share * 100, 4.0), 1)
  end

  def bar_width(_), do: 0.0

  defp tick_at(seconds), do: bar_width(seconds)

  @doc false
  # The phases with time on them, in the order a card goes through them,
  # each with its seconds and its share of the whole (a % to one place),
  # and which way its tooltip opens: leftwards past the bar's middle.
  def segments(phases) when is_map(phases) do
    total = max(phases |> Map.values() |> Enum.sum(), 1)

    LeadTime.phases()
    |> Enum.map(&{&1, Map.get(phases, &1, 0)})
    |> Enum.filter(fn {_phase, seconds} -> seconds > 0 end)
    |> Enum.map_reduce(0, fn {phase, seconds}, before ->
      mid = (before + seconds / 2) / total

      {%{
         phase: phase,
         seconds: seconds,
         share: Float.round(seconds * 100 / total, 1),
         align: if(mid > 0.5, do: "end", else: "start")
       }, before + seconds}
    end)
    |> elem(0)
  end

  @doc false
  # A day's heading (#2013): how many shipped, the median lead time of the
  # lines that have one, and the day's phases added up.
  def day_summary(items) do
    leads = for %{lead_time: %{seconds: s}} <- items, is_integer(s) and s > 0, do: s

    %{
      count: length(items),
      median: median(leads),
      phases:
        Enum.reduce(items, %{}, fn item, acc ->
          Map.merge(acc, item.lead_time.phases, fn _k, a, b -> a + b end)
        end)
    }
  end

  @doc false
  def median([]), do: nil

  def median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: div(Enum.at(sorted, mid - 1) + Enum.at(sorted, mid), 2)
  end

  # A docs card the server took without a verify job (#1953) says so.
  defp acceptor_text(nil, profile) when is_binary(profile), do: "Not verified (#{profile})"
  defp acceptor_text(nil, _), do: "Not verified"
  defp acceptor_text(%{name: name}, _), do: "Accepted by #{name}"

  # The repository's address for a commit, from the pull request's.
  defp commit_url(pr, sha) when is_binary(pr) and is_binary(sha) do
    case Regex.run(~r{^(https://[^/]+/[^/]+/[^/]+)/pull/\d+}, pr) do
      [_, repo] -> "#{repo}/commit/#{sha}"
      _ -> nil
    end
  end

  defp commit_url(_pr, _sha), do: nil

  defp pr_text(pr) do
    case Regex.run(~r{/pull/(\d+)}, pr) do
      [_, n] -> "Pull request ##{n}"
      _ -> "Pull request"
    end
  end

  defp short(nil), do: nil
  defp short(sha), do: String.slice(sha, 0, 7)

  defp tier_text("none"), do: "merges on acceptance"
  defp tier_text("ledger"), do: "merges, read here"
  defp tier_text("before_merge"), do: "a person merges"
  defp tier_text(_), do: nil

  attr :segments, :list, required: true
  attr :width, :float, required: true, doc: "the bar's length, % of its track"
  attr :id, :string, required: true
  attr :label, :string, required: true

  # A bar of phases on a track: each segment a focusable span whose tooltip
  # gives the exact time, so a tap shows it too.
  defp phase_bar(assigns) do
    ~H"""
    <div id={@id} class="ledger-track" role="group" aria-label={@label} data-role="phase-bar">
      <span
        :for={{_label, at} <- ticks()}
        class="ledger-tick"
        style={"left: #{tick_at(at)}%"}
        aria-hidden="true"
      ></span>
      <div class="ledger-bar" style={"width: #{@width}%"}>
        <span
          :for={seg <- @segments}
          tabindex="0"
          role="img"
          class={["ledger-seg", "ledger-phase-#{seg.phase}"]}
          style={"flex-grow: #{seg.seconds}"}
          data-tip={"#{phase_name(seg.phase)} · #{duration(seg.seconds)} · #{seg.share}%"}
          data-phase={seg.phase}
          data-align={seg.align}
          data-share={seg.share}
          aria-label={"#{phase_name(seg.phase)}: #{duration(seg.seconds)}, #{seg.share}%"}
        ></span>
      </div>
    </div>
    """
  end

  defp ticks, do: @ticks

  attr :item, :map, required: true
  attr :board, :map, required: true
  attr :zone, :string, required: true
  attr :tiers, :map, required: true

  defp ledger_line(assigns) do
    assigns =
      assign(assigns,
        segments: segments(assigns.item.lead_time.phases),
        tier: assigns.item.card.profile && assigns.tiers[assigns.item.card.profile]
      )

    ~H"""
    <li id={"ledger-#{@item.card.id}"} class="ledger-line">
      <div class="flex items-start gap-3">
        <div class="min-w-0 flex-1">
          <h3 class="text-base font-semibold leading-snug" data-role="title">{@item.card.title}</h3>
          <p class="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/60">
            <span class="tabular-nums">#{@item.card.id}</span>
            <span aria-hidden="true">·</span>
            <time datetime={DateTime.to_iso8601(@item.at)}>{time_text(@item.at, @zone)}</time>
            <span :for={e <- @item.events} class="ledger-event" data-role="event" data-event={e}>
              {e}
            </span>
          </p>
        </div>
        <a
          href={LedgerJSON.card_url(@item.card)}
          id={"ledger-look-#{@item.card.id}"}
          class="btn btn-ghost btn-sm shrink-0"
          title="Open the card with its chat"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4" />
          <span class="hidden sm:inline">Look closer</span>
          <span class="sr-only sm:hidden">Look closer</span>
        </a>
      </div>

      <p :if={@item.evidence} class="mt-2 text-sm leading-relaxed" data-role="evidence">
        {@item.evidence}
      </p>
      <p :if={!@item.evidence} class="mt-2 text-sm text-base-content/50" data-role="no-evidence">
        No evidence given.
      </p>

      <div :if={@segments != []} class="mt-3 flex items-center gap-3" data-role="lead-time">
        <.phase_bar
          id={"ledger-bar-#{@item.card.id}"}
          segments={@segments}
          width={bar_width(@item.lead_time.seconds)}
          label={"Lead time #{duration(@item.lead_time.seconds)}, by phase"}
        />
        <span class="w-16 shrink-0 text-right text-sm font-medium tabular-nums" data-role="total">
          {duration(@item.lead_time.seconds)}
        </span>
      </div>
      <p :if={@segments == []} class="mt-3 text-xs text-base-content/50" data-role="no-timings">
        No timings recorded.
      </p>

      <dl class="ledger-details">
        <dt>Verified</dt>
        <dd>
          <span data-role="acceptor">{acceptor_text(@item.accepted_by, @item[:not_verified])}</span>
          <span
            :if={@item.audit}
            class={[
              "ml-1 inline-flex items-center gap-1",
              if(@item.audit.verdict == "agrees", do: "text-success", else: "text-error")
            ]}
            data-role="audit"
          >
            <.icon
              name={
                if @item.audit.verdict == "agrees", do: "hero-check-circle", else: "hero-x-circle"
              }
              class="size-4"
            /> audit {@item.audit.verdict}
          </span>
          <span :if={@item.waiting_for} class="ml-1 text-warning" data-role="waiting-for">
            · waiting for {@item.waiting_for}
          </span>
        </dd>

        <%= if @item.card.profile do %>
          <dt>Profile</dt>
          <dd>
            <SlipdockWeb.SlipdockComponents.profile_chip profile={@item.card.profile} />
            <span :if={tier_text(@tier)} class="ml-1 text-base-content/60" data-role="tier">
              {tier_text(@tier)}
            </span>
          </dd>
        <% end %>

        <%= if @item.pr || @item.merge_sha || @item.deploys != [] do %>
          <dt>Shipped</dt>
          <dd class="flex flex-wrap gap-x-3 gap-y-1">
            <a
              :if={@item.pr}
              href={@item.pr}
              class="link"
              data-role="pr"
              target="_blank"
              rel="noopener"
            >
              {pr_text(@item.pr)}
            </a>
            <span :if={@item.merge_sha} data-role="merge">
              merged <.sha_link sha={@item.merge_sha} url={commit_url(@item.pr, @item.merge_sha)} />
            </span>
            <span :for={d <- @item.deploys} data-role="deploy">
              deployed to {d.environment} (<.sha_link sha={d.sha} url={commit_url(@item.pr, d.sha)} />)
            </span>
          </dd>
        <% end %>

        <%= if cost = Slipdock.Runners.JobCost.text(@item.lead_time[:cost]) do %>
          <dt>Cost</dt>
          <dd data-role="cost">spent {cost}</dd>
        <% end %>

        <%= if @item.subcards do %>
          <dt>Subcards</dt>
          <dd data-role="subcards">
            {@item.subcards.done}/{@item.subcards.total} subcards · {@item.subcards.on_ledger} here
          </dd>
        <% end %>

        <%= if @item.should_broken != [] do %>
          <dt>Rules</dt>
          <dd class="text-base-content/70" data-role="should">
            <.icon name="hero-information-circle" class="size-4 text-warning" />
            should rules missed: {Enum.map_join(@item.should_broken, ", ", & &1.id)}
          </dd>
        <% end %>
      </dl>
    </li>
    """
  end

  attr :sha, :string, default: nil
  attr :url, :string, default: nil

  defp sha_link(%{url: nil} = assigns) do
    ~H"""
    <code class="text-xs">{short(@sha)}</code>
    """
  end

  defp sha_link(assigns),
    do: ~H"""
    <a href={@url} class="link font-mono text-xs" target="_blank" rel="noopener">{short(@sha)}</a>
    """

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
        <.page width="standard" class="ledger space-y-8">
          <.page_header id="ledger-title" title="Ledger">
            <:meta>
              What shipped on this board and the boards beneath it since {when_text(
                @ledger.since,
                @zone
              )}: who accepted it, its evidence, the should rules it missed and where its time went.
            </:meta>
          </.page_header>

          <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <.form
              for={@since_form}
              id="ledger-since"
              phx-change="since"
              phx-submit="since"
              class="w-full sm:w-56"
            >
              <.input
                field={@since_form[:since]}
                type="text"
                label="Since"
                placeholder="7:00 yesterday"
                phx-debounce="400"
                class="input field w-full"
              />
            </.form>
            <.legend :if={@ledger.days != []} />
          </div>

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
            class="ledger-day"
            aria-labelledby={"ledger-day-#{Date.to_iso8601(day.date)}-title"}
          >
            <.day_heading day={day} />
            <ul class="ledger-lines">
              <.ledger_line
                :for={item <- day.items}
                item={item}
                board={@board}
                zone={@zone}
                tiers={@tiers}
              />
            </ul>
          </section>
        </.page>
      </div>
    </Layouts.app>
    """
  end

  attr :day, :map, required: true

  defp day_heading(assigns) do
    assigns = assign(assigns, summary: day_summary(assigns.day.items))

    ~H"""
    <header class="ledger-day-head">
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2
          id={"ledger-day-#{Date.to_iso8601(@day.date)}-title"}
          class="text-lg font-semibold tracking-tight"
        >
          {day_text(@day.date)}
        </h2>
        <p class="text-sm text-base-content/70 tabular-nums" data-role="day-summary">
          <span data-role="day-count">{@summary.count} shipped</span>
          <span :if={@summary.median}>
            · median lead time <span data-role="day-median">{duration(@summary.median)}</span>
          </span>
        </p>
      </div>
      <div :if={map_size(@summary.phases) > 0} class="mt-2">
        <span class="sr-only">Where the day's time went</span>
        <.phase_bar
          id={"ledger-day-bar-#{Date.to_iso8601(@day.date)}"}
          segments={segments(@summary.phases)}
          width={100.0}
          label={"Where #{day_text(@day.date)}'s time went, by phase"}
        />
      </div>
    </header>
    """
  end

  # What the colours and the hatching mean, and the bars' scale.
  defp legend(assigns) do
    assigns = assign(assigns, phases: LeadTime.phases())

    ~H"""
    <details id="ledger-legend" class="ledger-legend group" open>
      <summary class="cursor-pointer text-xs font-medium text-base-content/70">
        Key: where the time went
      </summary>
      <ul class="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-3">
        <li :for={phase <- @phases} class="flex items-center gap-1.5" data-phase={phase}>
          <span class={["ledger-swatch", "ledger-phase-#{phase}"]} aria-hidden="true"></span>
          {phase_name(phase)}
          <span :if={waiting?(phase)} class="sr-only">(waiting)</span>
        </li>
      </ul>
      <p class="mt-2 text-xs text-base-content/60">
        Hatched is waiting, solid is work. A card's bar is its lead time on a log scale, so minutes
        and days both read; the marks are 1 hour, 1 day and 1 week.
      </p>
    </details>
    """
  end
end
