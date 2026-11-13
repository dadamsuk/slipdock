defmodule SlipdockWeb.SlipdockComponents.Progress do
  @moduledoc "How far along a card is: its health pills, dependencies, subcards, profile, percent complete and time tracking."
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Slipdock.TimeTracking

  import SlipdockWeb.CoreComponents, only: [icon: 1]

  @healths %{
    done: {"Done", "bg-success/15 text-success", "hero-check-circle"},
    blocked: {"Blocked", "bg-error/15 text-error", "hero-no-symbol"},
    late:
      {"At risk", "bg-amber-500/15 text-amber-700 dark:text-amber-300",
       "hero-exclamation-triangle"},
    ok: {"On track", "chip-line text-base-content/70", "hero-check"},
    dropped: {"Dropped", "chip-line text-base-content/50", "hero-x-circle"}
  }

  # Stated health (what the owner reports), keyed as stored.
  @stated %{
    "on_track" => {"On track", "bg-success/15 text-success", "hero-hand-thumb-up"},
    "at_risk" =>
      {"At risk", "bg-amber-500/15 text-amber-700 dark:text-amber-300", "hero-hand-raised"},
    "off_track" => {"Off track", "bg-error/15 text-error", "hero-hand-thumb-down"}
  }

  attr :health, :string, required: true, doc: "on_track, at_risk or off_track"
  attr :with_label, :boolean, default: true
  attr :title, :string, default: nil

  @doc "A pill for a card's stated (reported) health."
  def stated_pill(%{health: nil} = assigns), do: ~H""

  def stated_pill(assigns) do
    {label, cls, icon} = Map.fetch!(@stated, assigns.health)
    assigns = assign(assigns, label: label, cls: cls, icon_name: icon)

    ~H"""
    <span class={["chip", @cls]} title={@title || "Reported #{String.downcase(@label)}"}>
      <.icon name={@icon_name} class="size-3" />
      <span :if={@with_label}>{@label}</span>
    </span>
    """
  end

  def health_label(health), do: @healths |> Map.fetch!(health) |> elem(0)

  attr :health, :atom, required: true, doc: ":done, :blocked, :late or :ok"
  attr :with_label, :boolean, default: true

  @doc "A pill for a card's rolled-up health."
  def health_pill(%{health: nil} = assigns), do: ~H""

  def health_pill(assigns) do
    {label, cls, icon} = Map.fetch!(@healths, assigns.health)
    assigns = assign(assigns, label: label, cls: cls, icon_name: icon)

    ~H"""
    <span
      class={["chip", @cls]}
      title={@label}
    >
      <.icon name={@icon_name} class="size-3" />
      <span :if={@with_label}>{@label}</span>
    </span>
    """
  end

  ## Dependencies ------------------------------------------------------------

  attr :card, :map, required: true
  attr :class, :string, default: "size-3.5"

  @doc "Shows 'blocked by N' when open blockers remain, and how many cards this one blocks."
  def dependency_badge(assigns) do
    blockers = Slipdock.Boards.Card.open_blockers(assigns.card)
    blocks = if is_list(assigns.card.blocks), do: length(assigns.card.blocks), else: 0
    assigns = assign(assigns, blockers: blockers, blocks: blocks)

    ~H"""
    <span
      :if={@blockers != []}
      class="chip bg-error/15 text-error"
      title={"Blocked by: " <> Enum.map_join(@blockers, ", ", & &1.title)}
    >
      <.icon name="hero-lock-closed" class="size-3" /> {length(@blockers)}
    </span>
    <span
      :if={@blocks > 0}
      class="chip chip-line text-base-content/70"
      title={"Blocks " <> Enum.map_join(@card.blocks, ", ", & &1.title)}
    >
      <.icon name="hero-arrow-right-circle" class={@class} /> {@blocks}
    </span>
    """
  end

  attr :card, :map, required: true

  attr :open, :boolean,
    default: false,
    doc: "a button that opens the sub-board, for a tile whose own click opens the card"

  @doc """
  Progress of a card's subcards, when it has a sub-board: every leaf beneath
  the card when a rollup is loaded, else the direct subcards. Tinted by the
  rolled-up health.
  """
  def subcards_badge(assigns) do
    card = assigns.card
    depth = (card.rollup && card.rollup.depth) || 1

    assigns =
      assign(assigns,
        progress: Slipdock.Boards.Card.progress(card),
        health: Slipdock.Boards.Card.health(card),
        depth: depth,
        open:
          assigns.open && match?(%Slipdock.Boards.Board{}, Map.get(card, :sub_board)) &&
            card.sub_board.id
      )

    ~H"""
    <.dynamic_tag
      :if={@progress}
      tag_name={if @open, do: "button", else: "span"}
      phx-click={@open && JS.navigate("/boards/#{@open}")}
      class={[
        "chip",
        @open && "cursor-pointer transition hover:ring-1 hover:ring-current",
        cond do
          elem(@progress, 0) == elem(@progress, 1) and elem(@progress, 1) > 0 ->
            "bg-success/15 text-success"

          @health == :blocked ->
            "bg-error/15 text-error"

          @health == :late ->
            "bg-amber-500/15 text-amber-700 dark:text-amber-300"

          true ->
            "bg-primary/10 text-primary"
        end
      ]}
      title={
        "#{elem(@progress, 0)} of #{elem(@progress, 1)} subcards done" <>
          if(@depth > 1, do: " (#{@depth} levels)", else: "") <>
          if(@open, do: " — click to open them as a board", else: "")
      }
    >
      <.icon name="hero-squares-2x2" class="size-3" /> {elem(@progress, 0)}/{elem(@progress, 1)}
    </.dynamic_tag>
    """
  end

  attr :profile, :string, required: true
  attr :source, :string, default: nil

  @doc """
  A card's profile (#1951): what kind of change it is, as one word. An
  inferred one is lighter and dashed (#2018), so it reads as a guess beside
  one a person or agent chose; its title says which.
  """
  def profile_chip(assigns) do
    ~H"""
    <span
      class={[
        "chip chip-line",
        if(@source == "inferred",
          do: "border-dashed text-base-content/45",
          else: "text-base-content/70"
        )
      ]}
      data-role="profile"
      data-source={@source}
      title={profile_title(@profile, @source)}
    >
      {@profile}
    </span>
    """
  end

  defp profile_title(profile, "inferred"), do: "Profile: #{profile}, inferred"

  defp profile_title(profile, source) when source in ~w(person agent rule),
    do: "Profile: #{profile}, set by #{source}"

  defp profile_title(profile, _source), do: "Profile: #{profile}"

  attr :percent, :integer, required: true

  @doc "A card's stated % complete, as a chip with a small bar."
  def percent_badge(assigns) do
    ~H"""
    <span
      class={[
        "chip",
        if(@percent == 100, do: "bg-success/15 text-success", else: "chip-line text-base-content/70")
      ]}
      title={"#{@percent}% complete"}
    >
      <span class="h-1 w-6 overflow-hidden rounded-full bg-base-content/15">
        <span class="block h-full rounded-full bg-current" style={"width: #{@percent}%"}></span>
      </span>
      {@percent}%
    </span>
    """
  end

  attr :card, :map, required: true

  @doc """
  Time spent against the estimate, as a chip: `1.5h/4h` with a small bar
  coloured by how close it is, or just the time spent without an estimate.
  A running timer shows as a pulsing clock.
  """
  def time_badge(assigns) do
    card = assigns.card
    unit = Map.get(card, :time_unit) || TimeTracking.default_unit()
    percent = TimeTracking.percent(card)

    assigns =
      assign(assigns,
        spent: TimeTracking.format(TimeTracking.spent(card), unit),
        estimate: TimeTracking.format(Map.get(card, :time_estimate), unit),
        percent: percent,
        status: TimeTracking.status(percent),
        running: TimeTracking.running?(card)
      )

    ~H"""
    <span
      class={[
        "chip",
        case @status do
          :over -> "bg-error/15 text-error"
          :near -> "bg-warning/15 text-warning"
          _ -> "chip-line text-base-content/70"
        end
      ]}
      title={
        "#{@spent} spent" <>
          if(@estimate, do: " of #{@estimate} estimated (#{@percent}%)", else: "") <>
          if(@running, do: " — timer running", else: "")
      }
    >
      <.icon
        name="hero-clock"
        class={["size-3", @running && "animate-pulse text-primary"]}
      />
      <span :if={@estimate} class="h-1 w-6 overflow-hidden rounded-full bg-base-content/15">
        <span
          class={["block h-full rounded-full", time_fill(@status)]}
          style={"width: #{min(@percent, 100)}%"}
        ></span>
      </span>
      {@spent}{if @estimate, do: "/#{@estimate}"}
    </span>
    """
  end

  attr :percent, :integer, required: true
  attr :class, :any, default: nil

  @doc """
  A bar of time spent against the estimate. Past 100% the bar fills and a
  tick marks where the estimate fell, so the overrun reads as a length.
  """
  def time_bar(assigns) do
    assigns = assign(assigns, status: TimeTracking.status(assigns.percent))

    ~H"""
    <div
      class={["relative h-2 overflow-hidden rounded-full bg-base-content/10", @class]}
      role="progressbar"
      aria-valuenow={@percent}
      aria-valuemin="0"
      aria-valuemax="100"
      data-status={@status}
    >
      <div
        class={["h-full rounded-full transition-all", time_fill(@status)]}
        style={"width: #{min(@percent, 100)}%"}
      >
      </div>
      <div
        :if={@percent > 100}
        class="absolute inset-y-0 w-0.5 bg-base-100"
        style={"left: #{Float.round(10_000 / @percent, 1)}%"}
        title="Estimate"
      >
      </div>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :can_write, :boolean, required: true
  attr :form_key, :integer, default: 0
  attr :target, :any, default: nil, doc: "the LiveComponent the events go to"

  @doc """
  The card panel's time tracking: the unit, time spent and the estimate (each
  typed in the unit, or with a suffix like `90m`), the bar between them, a
  timer to start and stop, and a box to log a stretch of time by hand.
  """
  def time_section(assigns) do
    card = assigns.card
    unit = card.time_unit || TimeTracking.default_unit()
    percent = TimeTracking.percent(card)

    assigns =
      assign(assigns,
        unit: unit,
        percent: percent,
        spent: TimeTracking.spent(card),
        status: TimeTracking.status(percent),
        running: TimeTracking.running?(card)
      )

    ~H"""
    <section class="space-y-2" id="card-time">
      <div class="flex items-center justify-between">
        <span class="section-label">Time</span>
        <button
          :if={@can_write}
          type="button"
          id="card-timer-toggle"
          phx-click="card_timer"
          phx-target={@target}
          phx-value-action={if @running, do: "stop", else: "start"}
          class={[
            "btn btn-xs gap-1",
            if(@running, do: "btn-primary", else: "btn-ghost")
          ]}
        >
          <.icon
            name={if @running, do: "hero-stop-solid", else: "hero-play-solid"}
            class="size-3"
          />
          <span :if={!@running}>Start timer</span>
          <span
            :if={@running}
            id={"card-timer-elapsed-#{DateTime.to_unix(@card.timer_started_at)}"}
            phx-hook="Elapsed"
            phx-update="ignore"
            data-since={DateTime.to_iso8601(@card.timer_started_at)}
            class="font-mono tabular-nums"
          >
            Stop
          </span>
        </button>
      </div>
      <.form
        for={%{}}
        as={:card}
        id="card-time-form"
        phx-change="card_change"
        phx-target={@target}
        class="grid grid-cols-[1fr_1fr_auto] items-end gap-2"
      >
        <label class="block space-y-1">
          <span class="field-label">Spent</span>
          <input
            type="text"
            inputmode="decimal"
            name="card[time_spent]"
            id={"card-time-spent-#{@form_key}"}
            value={TimeTracking.in_unit(@card.time_spent, @unit)}
            placeholder="0"
            phx-debounce="blur"
            disabled={!@can_write}
            class="input field w-full"
          />
        </label>
        <label class="block space-y-1">
          <span class="field-label">Estimate</span>
          <input
            type="text"
            inputmode="decimal"
            name="card[time_estimate]"
            id={"card-time-estimate-#{@form_key}"}
            value={TimeTracking.in_unit(@card.time_estimate, @unit)}
            placeholder="—"
            phx-debounce="blur"
            disabled={!@can_write}
            class="input field w-full"
          />
        </label>
        <label class="block space-y-1">
          <span class="field-label">Unit</span>
          <select
            name="card[time_unit]"
            id="card-time-unit"
            class="select field"
            disabled={!@can_write}
          >
            <option
              :for={{key, label} <- TimeTracking.units()}
              value={key}
              selected={key == @unit}
            >
              {label}
            </option>
          </select>
        </label>
      </.form>
      <div :if={@percent} class="space-y-1" id="card-time-progress">
        <.time_bar percent={@percent} />
        <p class={[
          "flex justify-between text-2xs",
          case @status do
            :over -> "text-error"
            :near -> "text-warning"
            _ -> "text-base-content/60"
          end
        ]}>
          <span>
            {TimeTracking.format(@spent, @unit)} of {TimeTracking.format(@card.time_estimate, @unit)}
          </span>
          <span>
            {@percent}%{if @status == :over,
              do: " — #{TimeTracking.format(@spent - @card.time_estimate, @unit)} over"}
          </span>
        </p>
      </div>
      <form
        :if={@can_write}
        id={"card-log-time-#{@form_key}"}
        phx-submit="log_time"
        phx-target={@target}
        class="flex gap-2"
      >
        <input
          type="text"
          name="amount"
          placeholder={"Log time — e.g. 30m, 1.5#{TimeTracking.suffix(@unit)}"}
          class="input field min-w-0 flex-1"
          autocomplete="off"
        />
        <button type="submit" class="btn btn-sm btn-ghost">Log</button>
      </form>
    </section>
    """
  end

  defp time_fill(:over), do: "bg-error"
  defp time_fill(:near), do: "bg-warning"
  defp time_fill(_), do: "bg-success"
end
