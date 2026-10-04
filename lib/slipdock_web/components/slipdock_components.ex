defmodule SlipdockWeb.SlipdockComponents do
  @moduledoc "Presentational components for boards, columns and cards."
  use Phoenix.Component
  use Gettext, backend: SlipdockWeb.Gettext
  use Phoenix.VerifiedRoutes, endpoint: SlipdockWeb.Endpoint, router: SlipdockWeb.Router

  import SlipdockWeb.CoreComponents, only: [icon: 1, quick_chips: 1]
  alias Slipdock.Palette
  alias Slipdock.TimeTracking
  alias Slipdock.Swimlanes.Config
  alias Phoenix.LiveView.JS

  ## Priority --------------------------------------------------------------

  @priorities %{
    "none" => {"None", nil, nil},
    "low" => {"Low", "hero-arrow-down", "text-sky-600 dark:text-sky-300"},
    "medium" => {"Medium", "hero-minus", "text-amber-600 dark:text-amber-300"},
    "high" => {"High", "hero-chevron-up", "text-orange-600 dark:text-orange-300"},
    "critical" => {"Critical", "hero-chevron-double-up", "text-rose-600 dark:text-rose-300"}
  }

  def priority_options, do: Enum.map(~w(none low medium high critical), &{priority_label(&1), &1})
  def priority_label(p), do: @priorities |> Map.fetch!(p) |> elem(0)

  attr :priority, :string, required: true
  attr :with_label, :boolean, default: false

  def priority_badge(%{priority: "none"} = assigns) do
    ~H"""
    <span :if={@with_label} class="text-xs opacity-50">No priority</span>
    """
  end

  def priority_badge(assigns) do
    {label, icon, color} = Map.fetch!(@priorities, assigns.priority)
    assigns = assign(assigns, label: label, icon_name: icon, color: color)

    ~H"""
    <span
      class={["chip chip-tint", !@with_label && "chip-icon", @color]}
      title={"Priority: #{@label}"}
    >
      <.icon name={@icon_name} class="size-3.5" />
      <span :if={@with_label}>{@label}</span>
    </span>
    """
  end

  ## Flags ------------------------------------------------------------------

  @flags [
    {"flagged", "Flagged", "hero-flag-solid", "text-rose-600 dark:text-rose-300",
     "bg-rose-100 text-rose-700 ring-rose-200 dark:bg-rose-400/20 dark:text-rose-200 dark:ring-rose-400/30"},
    {"blocked", "Blocked", "hero-no-symbol", "text-red-600 dark:text-red-300",
     "bg-red-100 text-red-700 ring-red-200 dark:bg-red-400/20 dark:text-red-200 dark:ring-red-400/30"},
    {"review", "Needs review", "hero-eye", "text-violet-600 dark:text-violet-300",
     "bg-violet-100 text-violet-700 ring-violet-200 dark:bg-violet-400/20 dark:text-violet-200 dark:ring-violet-400/30"},
    {"waiting", "Waiting", "hero-clock", "text-amber-600 dark:text-amber-300",
     "bg-amber-100 text-amber-700 ring-amber-200 dark:bg-amber-400/20 dark:text-amber-200 dark:ring-amber-400/30"},
    {"starred", "Starred", "hero-star-solid", "text-yellow-600 dark:text-yellow-300",
     "bg-yellow-100 text-yellow-700 ring-yellow-200 dark:bg-yellow-400/20 dark:text-yellow-200 dark:ring-yellow-400/30"}
  ]

  def flags, do: @flags
  def flag_label(flag), do: @flags |> List.keyfind!(flag, 0) |> elem(1)

  attr :flag, :string, required: true
  attr :class, :string, default: "size-4"

  def flag_icon(assigns) do
    {_, label, icon, color, _} = List.keyfind!(@flags, assigns.flag, 0)
    assigns = assign(assigns, label: label, icon_name: icon, color: color)

    ~H"""
    <span class={["chip chip-icon chip-tint", @color]} title={@label}>
      <.icon name={@icon_name} class={@class} />
    </span>
    """
  end

  attr :flag, :string, required: true
  attr :active, :boolean, default: false
  attr :rest, :global

  def flag_toggle(assigns) do
    {_, label, icon, color, active_cls} = List.keyfind!(@flags, assigns.flag, 0)
    assigns = assign(assigns, label: label, icon_name: icon, color: color, active_cls: active_cls)

    ~H"""
    <button
      type="button"
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ring-1 transition",
        if(@active,
          do: @active_cls,
          else: "ring-base-content/10 text-base-content/60 hover:bg-base-200 hover:text-base-content"
        )
      ]}
      aria-pressed={to_string(@active)}
      {@rest}
    >
      <.icon name={@icon_name} class={["size-3.5", @active && @color]} />
      {@label}
    </button>
    """
  end

  ## Tags -------------------------------------------------------------------

  attr :tag, :map, required: true
  attr :size, :string, default: "sm"
  attr :rest, :global

  def tag_chip(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 rounded-md font-medium leading-none",
        @size == "xs" && "px-1.5 py-0.5 text-2xs",
        @size == "sm" && "px-2 py-1 text-xs",
        Palette.chip(@tag.color)
      ]}
      {@rest}
    >
      {@tag.name}
    </span>
    """
  end

  attr :tag, :map, required: true
  attr :active, :boolean, default: false
  attr :rest, :global

  @doc """
  A tag as a toggle, styled like `flag_toggle/1`: a muted outlined pill with
  the tag's colour as a dot, filling with the tag's colour when active.
  """
  def tag_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ring-1 transition",
        if(@active,
          do: [Palette.chip(@tag.color), "ring-transparent"],
          else: "ring-base-content/10 text-base-content/60 hover:bg-base-200 hover:text-base-content"
        )
      ]}
      aria-pressed={to_string(@active)}
      title={if @active, do: "Remove tag", else: "Add tag"}
      {@rest}
    >
      <.icon :if={@active} name="hero-check" class="size-3.5" />
      <span :if={!@active} class={["size-2 rounded-full", Palette.dot(@tag.color)]}></span>
      {@tag.name}
    </button>
    """
  end

  attr :color, :string, required: true
  attr :selected, :boolean, default: false
  attr :rest, :global

  def color_swatch(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "size-6 rounded-full ring-offset-2 ring-offset-base-100 transition hover:scale-110",
        Palette.dot(@color),
        @selected && "ring-2 ring-base-content"
      ]}
      title={Palette.label(@color)}
      aria-pressed={to_string(@selected)}
      {@rest}
    ></button>
    """
  end

  ## Assignees --------------------------------------------------------------

  attr :user, :map, required: true
  attr :size, :string, default: "sm"
  attr :with_name, :boolean, default: false

  @doc "An initials avatar for the card's assignee."
  def assignee_chip(assigns) do
    user = assigns.user

    assigns =
      assign(assigns,
        initials: Slipdock.Accounts.User.initials(user),
        name: Slipdock.Accounts.User.display_name(user)
      )

    ~H"""
    <span class="inline-flex items-center gap-1" title={"Assigned to #{@name}"}>
      <span class={[
        "inline-flex shrink-0 items-center justify-center rounded-full bg-secondary/20 font-semibold uppercase text-secondary-content dark:text-secondary",
        @size == "xs" && "size-4 text-[9px]",
        @size == "sm" && "size-6 text-2xs"
      ]}>
        {@initials}
      </span>
      <span :if={@with_name} class="truncate text-sm">{@name}</span>
    </span>
    """
  end

  def loaded_assignee(%{assignee: %Slipdock.Accounts.User{} = user}), do: user
  def loaded_assignee(_), do: nil

  attr :users, :list, required: true
  attr :size, :string, default: "sm"
  attr :with_name, :boolean, default: false
  attr :max, :integer, default: 3

  @doc """
  Everybody a card is assigned to, as overlapping initials avatars, the lead
  first; past `max` the rest are counted rather than drawn. One person is
  drawn exactly as `assignee_chip/1` draws them.
  """
  def assignee_chips(%{users: [user]} = assigns) do
    assigns = assign(assigns, :user, user)

    ~H"""
    <.assignee_chip user={@user} size={@size} with_name={@with_name} />
    """
  end

  def assignee_chips(assigns) do
    names = Enum.map_join(assigns.users, ", ", &Slipdock.Accounts.User.display_name/1)

    assigns =
      assign(assigns,
        names: names,
        shown: Enum.take(assigns.users, assigns.max),
        more: max(length(assigns.users) - assigns.max, 0)
      )

    ~H"""
    <span :if={@users != []} class="inline-flex items-center gap-1" title={"Assigned to #{@names}"}>
      <span class="inline-flex -space-x-1">
        <span
          :for={user <- @shown}
          class={[
            "inline-flex shrink-0 items-center justify-center rounded-full bg-secondary/20 font-semibold uppercase text-secondary-content ring-1 ring-base-100 dark:text-secondary",
            @size == "xs" && "size-4 text-[9px]",
            @size == "sm" && "size-6 text-2xs"
          ]}
        >
          {Slipdock.Accounts.User.initials(user)}
        </span>
        <span
          :if={@more > 0}
          class={[
            "inline-flex shrink-0 items-center justify-center rounded-full bg-base-300 font-semibold text-base-content/70 ring-1 ring-base-100",
            @size == "xs" && "size-4 text-[9px]",
            @size == "sm" && "size-6 text-2xs"
          ]}
        >
          +{@more}
        </span>
      </span>
      <span :if={@with_name} class="truncate text-sm">{@names}</span>
    </span>
    """
  end

  ## Due dates --------------------------------------------------------------

  attr :date, :any, required: true
  attr :completed, :boolean, default: false
  attr :derived, :boolean, default: false, doc: "the date comes from the card's subcards"

  def due_badge(%{date: nil} = assigns), do: ~H""

  def due_badge(assigns) do
    assigns = assign(assigns, :state, due_state(assigns.date, assigns.completed))

    ~H"""
    <span
      class={[
        "chip",
        @state == :done && "bg-success/15 text-success",
        @state == :overdue && "bg-error/15 text-error",
        @state == :soon && "bg-amber-500/15 text-amber-700 dark:text-amber-300",
        @state == :later && "chip-line text-base-content/70",
        @derived && "bg-transparent ring-1 ring-inset ring-current/40 ring-dashed"
      ]}
      title={
        "Due #{Calendar.strftime(@date, "%A, %B %-d %Y")}" <>
          if(@derived, do: " (rolled up from subcards)", else: "")
      }
    >
      <.icon
        name={
          cond do
            @state == :done -> "hero-check-circle"
            @derived -> "hero-arrow-up-on-square-stack"
            true -> "hero-clock"
          end
        }
        class="size-3"
      />
      {format_due(@date)}
    </span>
    """
  end

  attr :card, :map, required: true

  @doc """
  The card's schedule at a glance: its due date, or the one rolled up from
  its subcards when it has none, plus a warning when the subcards run past
  the card's own due date.
  """
  def schedule_badges(assigns) do
    card = assigns.card

    assigns =
      assign(assigns,
        due: Slipdock.Boards.Card.effective_due(card),
        derived: Slipdock.Boards.Card.due_derived?(card),
        card: card
      )

    ~H"""
    <.due_badge date={@due} completed={@card.completed} derived={@derived} />
    <.slip_chips card={@card} />
    """
  end

  @doc """
  The sentences used wherever a date overrun is shown. One phrasing, in one
  place, because this is said on the card face, in the outline, in the card
  modal and in the CLI, and four copies of a sentence drift.

  Each names the date it is measured from, because "overdue" and "slipped"
  do not: a card can be past its own due date while every subcard is still
  ahead of schedule, and those are different facts about different dates.
  """
  def past_date_label(:start, days), do: "#{days} #{plural_days(days)} past start date"
  def past_date_label(:due, days), do: "#{days} #{plural_days(days)} past due date"

  defp plural_days(1), do: "day"
  defp plural_days(_), do: "days"

  @doc "The same, said in full: what runs past what, and until when."
  def past_date_detail(:start, days, on) when not is_nil(on),
    do: "Subcards begin #{fmt_long(on)} — #{past_date_label(:start, days)}"

  def past_date_detail(:due, days, on) when not is_nil(on),
    do: "Subcards run until #{fmt_long(on)} — #{past_date_label(:due, days)}"

  def past_date_detail(which, days, _on), do: past_date_label(which, days)

  defp fmt_long(%Date{} = d), do: Calendar.strftime(d, "%-d %b %Y")
  defp fmt_long(other), do: to_string(other)

  attr :card, :map, required: true
  attr :class, :string, default: "chip bg-amber-500/15 text-amber-700 dark:text-amber-300"

  @doc """
  A chip per overrun: one if the subcards start late, one if they finish late,
  both when both. Each is labelled with the date it is measured from rather
  than left as a bare `+31d`, which says nothing about what it is 31 days past.
  """
  def slip_chips(assigns) do
    card = assigns.card
    rollup = card.rollup

    assigns =
      assign(assigns,
        start_slip: Slipdock.Boards.Card.start_slip(card),
        due_slip: Slipdock.Boards.Card.due_slip(card),
        derived_start: rollup && rollup.derived_start,
        derived_due: rollup && rollup.derived_due
      )

    ~H"""
    <span
      :if={@start_slip > 0 and not @card.completed}
      class={@class}
      title={past_date_detail(:start, @start_slip, @derived_start)}
    >
      <.icon name="hero-arrow-trending-up" class="size-3" /> start +{@start_slip}d
    </span>
    <span
      :if={@due_slip > 0 and not @card.completed}
      class={@class}
      title={past_date_detail(:due, @due_slip, @derived_due)}
    >
      <.icon name="hero-arrow-trending-up" class="size-3" /> due +{@due_slip}d
    </span>
    """
  end

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

  def stated_label(key), do: @stated |> Map.fetch!(key) |> elem(0)

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

  def due_state(nil, _), do: nil
  def due_state(_, true), do: :done

  def due_state(date, false) do
    today = Date.utc_today()

    cond do
      Date.compare(date, today) == :lt -> :overdue
      Date.diff(date, today) <= 2 -> :soon
      true -> :later
    end
  end

  def format_due(date) do
    today = Date.utc_today()

    case Date.diff(date, today) do
      0 -> "Today"
      1 -> "Tomorrow"
      -1 -> "Yesterday"
      # "overdue" does not say which date, and a card has two. Everywhere else
      # now says "past due date"; this is the compact form of the same thing.
      n when n < 0 and n > -7 -> "#{-n}d past due"
      n when n > 0 and n < 7 -> Calendar.strftime(date, "%a")
      _ -> Calendar.strftime(date, "%b %-d")
    end
  end

  defp loaded_attachments(%{attachments: list}) when is_list(list), do: list
  defp loaded_attachments(_), do: []

  def relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      # Ahead of us: a token's expiry, say. Without this branch a negative
      # difference falls through to "just now", which reads as the opposite
      # of what it means.
      seconds <= -7 * 86_400 -> Calendar.strftime(dt, "%b %-d")
      seconds <= -86_400 -> "in #{div(-seconds, 86_400)}d"
      seconds <= -3600 -> "in #{div(-seconds, 3600)}h"
      seconds < 0 -> "in #{max(div(-seconds, 60), 1)}m"
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds < 7 * 86_400 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %-d")
    end
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
        depth: depth
      )

    ~H"""
    <span
      :if={@progress}
      class={[
        "chip",
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
          if(@depth > 1, do: " (#{@depth} levels)", else: "")
      }
    >
      <.icon name="hero-squares-2x2" class="size-3" /> {elem(@progress, 0)}/{elem(@progress, 1)}
    </span>
    """
  end

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
        <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Time</span>
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
          <span class="text-2xs text-base-content/60">Spent</span>
          <input
            type="text"
            inputmode="decimal"
            name="card[time_spent]"
            id={"card-time-spent-#{@form_key}"}
            value={TimeTracking.in_unit(@card.time_spent, @unit)}
            placeholder="0"
            phx-debounce="blur"
            disabled={!@can_write}
            class="input input-sm w-full"
          />
        </label>
        <label class="block space-y-1">
          <span class="text-2xs text-base-content/60">Estimate</span>
          <input
            type="text"
            inputmode="decimal"
            name="card[time_estimate]"
            id={"card-time-estimate-#{@form_key}"}
            value={TimeTracking.in_unit(@card.time_estimate, @unit)}
            placeholder="—"
            phx-debounce="blur"
            disabled={!@can_write}
            class="input input-sm w-full"
          />
        </label>
        <label class="block space-y-1">
          <span class="text-2xs text-base-content/60">Unit</span>
          <select
            name="card[time_unit]"
            id="card-time-unit"
            class="select select-sm"
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
          class="input input-sm min-w-0 flex-1"
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

  ## Card -------------------------------------------------------------------

  attr :card, :map, required: true

  @doc "When the card starts: its own start date, or the one rolled up from its subcards."
  def start_badge(assigns) do
    card = assigns.card

    assigns =
      assign(assigns,
        date: Slipdock.Boards.Card.effective_start(card),
        derived: Slipdock.Boards.Card.start_derived?(card)
      )

    ~H"""
    <span
      :if={@date}
      class={[
        "chip chip-line text-base-content/70",
        @derived && "ring-1 ring-inset ring-dashed ring-current/40"
      ]}
      title={
        "Starts #{Calendar.strftime(@date, "%A, %B %-d %Y")}" <>
          if(@derived, do: " (rolled up from subcards)", else: "")
      }
    >
      <.icon name="hero-play" class="size-3" /> {format_day(@date)}
    </span>
    """
  end

  def format_day(date) do
    case Date.diff(date, Date.utc_today()) do
      0 -> "Today"
      1 -> "Tomorrow"
      -1 -> "Yesterday"
      _ -> Calendar.strftime(date, "%b %-d")
    end
  end

  @doc "The facets to show as a MapSet; `nil` means every facet."
  def show_set(nil), do: MapSet.new(Config.facet_keys())
  def show_set(%MapSet{} = set), do: set
  def show_set(list) when is_list(list), do: MapSet.new(list)

  attr :card, :map, required: true
  attr :id, :string, default: nil, doc: "DOM id; defaults to card-<id>"
  attr :compact, :boolean, default: false, doc: "single-line variant for dense grids"

  attr :show, :any,
    default: nil,
    doc: "the facets to render (a list or MapSet of keys from Config.facets/1); nil shows all"

  attr :cover, :any,
    default: :auto,
    doc: "the palette colour of the cover strip; :auto uses the card's own colour"

  attr :focus, :atom,
    default: nil,
    doc: """
    where the keyboard is: `:cursor` when it points at this card (the "c"
    shortcut), `:held` when the card is being carried (the "J" shortcut)
    """

  slot :actions,
    doc: """
    controls rendered at the end of the card's title row — the board view's
    "move to another list" menu. Anything in here needs a `phx-click` of its
    own, or the click finds the card's and opens it instead.
    """

  def card(assigns) do
    card = assigns.card
    page? = page?(card)
    show = show_set(assigns.show)
    on = &MapSet.member?(show, &1)
    done = Enum.count(card.checklist_items, & &1.done)
    total = length(card.checklist_items)
    cover = if assigns.cover == :auto, do: card.color, else: assigns.cover

    facets = %{
      cover: on.("cover") and not is_nil(cover),
      stated: on.("status") and not is_nil(Slipdock.Boards.Card.stated_health(card)),
      status: on.("status"),
      tags: on.("tags") and card.tags != [],
      flags: on.("flags") and card.flags != [],
      priority: on.("priority") and card.priority != "none",
      assignee: on.("assignee") and Slipdock.Boards.Card.assignees(card) != [],
      start_date: on.("start_date") and not is_nil(Slipdock.Boards.Card.effective_start(card)),
      due_date: on.("due_date") and not is_nil(Slipdock.Boards.Card.effective_due(card)),
      percent: on.("percent_complete") and not is_nil(card.percent_complete),
      time: on.("time") and TimeTracking.tracked?(card),
      dependencies: on.("dependencies") and (card.blocks != [] or card.blocked_by != []),
      subcards: on.("subcards") and not is_nil(card.sub_board),
      checklist: on.("checklist") and total > 0,
      description: on.("description") and (card.description || "") != "",
      comments: on.("comments") and card.comments != [],
      attachments: on.("attachments") and loaded_attachments(card) != []
    }

    meta? = facets |> Map.drop([:cover, :status, :tags]) |> Map.values() |> Enum.any?()

    assigns =
      assign(assigns,
        done: done,
        total: total,
        f: facets,
        meta?: meta?,
        cover_color: cover,
        page?: page?,
        # A wiki page is `page-7` where a card is `12`, so the drag-and-drop
        # and the click handlers can tell the two apart.
        item_id: item_id(card),
        dom_id: assigns.id || if(page?, do: "page-#{card.id}", else: "card-#{card.id}"),
        page_path: page? && "/boards/#{card.board_id}/wiki/#{card.slug}"
      )

    ~H"""
    <div
      id={@dom_id}
      data-id={@item_id}
      class={[
        "kanban-card group relative cursor-grab rounded-xl bg-base-100 shadow-sm ring-1 ring-base-content/5",
        "outline-none transition hover:shadow-md hover:ring-primary/40 active:cursor-grabbing",
        "focus-visible:ring-2 focus-visible:ring-primary/50",
        @page? && "kanban-page",
        @card.completed && "opacity-60",
        @focus == :cursor && "z-10 ring-2 ring-secondary",
        @focus == :held && "z-10 scale-[1.02] shadow-lg ring-2 ring-primary"
      ]}
      data-focus={@focus}
      tabindex="0"
      role="button"
      phx-click={open_item(@page?, @card.id)}
      phx-keydown={open_item(@page?, @card.id)}
      phx-key="Enter"
    >
      <div
        :if={@f.cover && !@compact}
        class={["h-1.5 rounded-t-xl bg-gradient-to-r", Palette.gradient(@cover_color)]}
      >
      </div>
      <div :if={@compact} class="flex items-center gap-2 px-2.5 py-1.5">
        <span :if={@f.cover} class={["size-2 shrink-0 rounded-full", Palette.dot(@cover_color)]}></span>
        <.doc_link :if={@page?} path={@page_path} class="size-3.5" />
        <button
          :if={@f.status and not @page?}
          type="button"
          class={[
            "shrink-0 rounded-full transition",
            if(@card.completed, do: "text-success", else: "text-base-content/25 hover:text-success")
          ]}
          phx-click={JS.push("toggle_complete", value: %{id: @card.id})}
          title={if @card.completed, do: "Mark incomplete", else: "Mark complete"}
        >
          <.icon
            name={if @card.completed, do: "hero-check-circle-solid", else: "hero-check-circle"}
            class="size-3.5"
          />
        </button>
        <p
          class={[
            "min-w-20 flex-1 truncate text-2xs font-medium leading-snug",
            @card.completed && "text-base-content/50"
          ]}
          title={@card.title}
        >
          {@card.title}
        </p>
        <span
          :if={@f.tags}
          class="flex shrink-0 items-center gap-0.5"
          title={Enum.map_join(@card.tags, ", ", & &1.name)}
        >
          <span :for={tag <- @card.tags} class={["size-2 rounded-full", Palette.dot(tag.color)]}></span>
        </span>
        <.flag_icon :for={flag <- @card.flags} :if={@f.flags} flag={flag} class="size-3" />
        <.dependency_badge :if={@f.dependencies} card={@card} class="size-3" />
        <.subcards_badge :if={@f.subcards} card={@card} />
        <.stated_pill
          :if={@f.stated}
          health={Slipdock.Boards.Card.stated_health(@card)}
          with_label={false}
        />
        <.assignee_chips :if={@f.assignee} users={Slipdock.Boards.Card.assignees(@card)} size="xs" />
        <.priority_badge :if={@f.priority} priority={@card.priority} />
        <.start_badge :if={@f.start_date} card={@card} />
        <.schedule_badges :if={@f.due_date} card={@card} />
        <.percent_badge :if={@f.percent} percent={@card.percent_complete} />
        <.time_badge :if={@f.time} card={@card} />
        <span :if={@actions != []} class="-mr-1 shrink-0">{render_slot(@actions)}</span>
      </div>
      <div :if={!@compact} class="space-y-2 p-3">
        <div :if={@f.tags} class="flex flex-wrap gap-1">
          <.tag_chip :for={tag <- @card.tags} tag={tag} size="xs" />
        </div>

        <div class="flex items-start gap-2">
          <.doc_link :if={@page?} path={@page_path} class="mt-0.5 size-4" />
          <button
            :if={@f.status and not @page?}
            type="button"
            class={[
              "mt-0.5 shrink-0 rounded-full transition",
              if(@card.completed,
                do: "text-success",
                else:
                  "text-base-content/25 opacity-0 hover:text-success group-hover:opacity-100 no-hover:opacity-100"
              )
            ]}
            phx-click={JS.push("toggle_complete", value: %{id: @card.id})}
            title={if @card.completed, do: "Mark incomplete", else: "Mark complete"}
          >
            <.icon
              name={if @card.completed, do: "hero-check-circle-solid", else: "hero-check-circle"}
              class="size-4"
            />
          </button>
          <p class={[
            "min-w-0 flex-1 text-xs font-medium leading-snug",
            @card.completed && "text-base-content/70"
          ]}>
            {@card.title}
          </p>
          <span :if={@actions != []} class="-mr-1 -mt-0.5 shrink-0">{render_slot(@actions)}</span>
        </div>

        <div :if={@meta?} class="flex flex-wrap items-center gap-1 text-base-content/60">
          <.flag_icon :for={flag <- @card.flags} :if={@f.flags} flag={flag} class="size-3.5" />
          <.dependency_badge :if={@f.dependencies} card={@card} />
          <.subcards_badge :if={@f.subcards} card={@card} />
          <.stated_pill
            :if={@f.stated}
            health={Slipdock.Boards.Card.stated_health(@card)}
            with_label={false}
          />
          <.assignee_chips :if={@f.assignee} users={Slipdock.Boards.Card.assignees(@card)} size="xs" />
          <.priority_badge :if={@f.priority} priority={@card.priority} />
          <.start_badge :if={@f.start_date} card={@card} />
          <.schedule_badges :if={@f.due_date} card={@card} />
          <.percent_badge :if={@f.percent} percent={@card.percent_complete} />
          <.time_badge :if={@f.time} card={@card} />
          <span
            :if={@f.checklist}
            class={[
              "chip",
              if(@done == @total,
                do: "bg-success/15 text-success",
                else: "chip-line text-base-content/70"
              )
            ]}
            title="Checklist"
          >
            <.icon name="hero-clipboard-document-check" class="size-3" /> {@done}/{@total}
          </span>
          <span
            :if={@f.description}
            class="chip chip-icon chip-line text-base-content/70"
            title="Has description"
          >
            <.icon name="hero-bars-3-bottom-left" class="size-3.5" />
          </span>
          <span :if={@f.comments} class="chip chip-line text-base-content/70" title="Comments">
            <.icon name="hero-chat-bubble-left" class="size-3.5" /> {length(@card.comments)}
          </span>
          <span
            :if={@f.attachments}
            class="chip chip-line text-base-content/70"
            title="Attachments"
          >
            <.icon name="hero-paper-clip" class="size-3.5" /> {length(loaded_attachments(@card))}
          </span>
        </div>
      </div>
    </div>
    """
  end

  ## Placed wiki pages --------------------------------------------------------

  @doc """
  Whether a thing drawn on a board is a wiki page rather than a card.

  A placed page carries the card's facets under the card's names (see
  `Slipdock.Wiki.Page`), so everything that *reads* one treats them alike. This
  is for the handful of places that must not: the link that opens the
  document, and the `page-7` id the drag-and-drop needs.
  """
  def page?(%Slipdock.Wiki.Page{}), do: true
  def page?(_), do: false

  @doc """
  The id a card or a placed wiki page answers to on the board: `page-7` for a
  page, a bare number for a card.

  Two id spaces share one list, so everything that puts an item's id into the
  DOM or onto the wire uses this — the drag-and-drop reads it back with
  `Slipdock.Boards.item_ref/1`, and a card and a page that happen to share a
  number never collide.
  """
  def item_id(item), do: if(page?(item), do: "page-#{item.id}", else: to_string(item.id))

  @doc """
  The document icon on a placed page's tile: one click opens the page.

  It is a link rather than a button, and it sits *outside* the tile's own
  click target, so opening the document and opening the panel never race each
  other for the same click. That is the whole bargain of a page on the board:
  the icon is the document, the rest of it is a card.
  """
  attr :path, :string, required: true
  attr :class, :string, default: "size-4"

  def doc_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class="shrink-0 text-primary/70 transition hover:text-primary"
      title="Open the document"
      aria-label="Open the document"
    >
      <.icon name="hero-document-text" class={@class} />
    </.link>
    """
  end

  @doc """
  The icon for a kind of thing in a list (see `Slipdock.Kinds`): a card, a
  document — a card whose whole content is the file clipped to it — or a wiki
  page placed in the list.
  """
  def kind_icon("document"), do: "hero-paper-clip"
  def kind_icon("page"), do: "hero-document-text"
  def kind_icon(_card), do: "hero-rectangle-stack"

  @doc """
  The click that opens an item: a card opens the card, a placed wiki page opens
  its panel, which the view turns into a query parameter so it works over every
  mode without a route each.

  Every view that draws cards and placed pages together needs this — a page
  pushed at `open_card` is a card that "no longer exists".
  """
  def open_item(item), do: open_item(page?(item), item.id)

  defp open_item(true, id), do: JS.push("open_page", value: %{id: id})
  defp open_item(false, id), do: JS.push("open_card", value: %{id: id})

  @doc """
  A label with one letter underlined: the key that jumps to it.

  The card dialog's sections are reached by key — `SlipdockWeb.Shortcuts` writes
  them down and the `CardKeys` hook acts on them — and the underline is how a
  heading says which key is its own. The letter is the first match in the
  label, case-insensitively; a key the label does not contain is rendered
  plainly rather than guessed at.
  """
  attr :key, :string, required: true
  attr :label, :string, required: true

  def keyed_label(assigns) do
    {before, letter, rest} = split_on_key(assigns.label, assigns.key)
    assigns = assign(assigns, before: before, letter: letter, rest: rest)

    ~H"""
    <span phx-no-format>{@before}<u :if={@letter != ""} class="underline decoration-1 underline-offset-2">{@letter}</u>{@rest}</span>
    """
  end

  defp split_on_key(label, key) do
    case :binary.match(String.downcase(label), String.downcase(key)) do
      {at, len} ->
        {binary_part(label, 0, at), binary_part(label, at, len),
         binary_part(label, at + len, byte_size(label) - at - len)}

      :nomatch ->
        {label, "", ""}
    end
  end

  ## Modal ------------------------------------------------------------------

  attr :id, :string, required: true
  attr :on_close, JS, required: true
  attr :size, :string, default: "md"

  attr :keys, :boolean,
    default: false,
    doc: "give the dialog the keyboard: arrows, hjkl, PageUp/Down, Home/End and the section keys"

  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="kanban-modal fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-base-content/40 p-0 backdrop-blur-sm sm:p-8"
      phx-window-keydown={@on_close}
      phx-key="Escape"
      phx-click-away={@on_close}
      phx-hook={@keys && "CardKeys"}
      data-card-keys={@keys && ""}
    >
      <div
        class={[
          "kanban-modal-in relative my-0 min-h-dvh w-full rounded-none bg-base-100 pb-[env(safe-area-inset-bottom)] shadow-2xl ring-1 ring-base-content/10 sm:my-4 sm:min-h-0 sm:rounded-2xl sm:pb-0",
          @size == "sm" && "max-w-md",
          @size == "md" && "max-w-xl",
          @size == "lg" && "max-w-4xl"
        ]}
        phx-click-away={@on_close}
      >
        <button
          type="button"
          class="btn btn-ghost btn-sm btn-circle absolute right-3 top-3 z-10"
          phx-click={@on_close}
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  ## Favourites -----------------------------------------------------------------

  attr :kind, :string,
    required: true,
    doc: ~s(what is being favourited: "board", "column", "card" or "view")

  attr :id, :any, required: true, doc: "the thing's id"
  attr :name, :string, required: true, doc: "its name, for the label a screen reader reads"

  attr :marks, :any,
    required: true,
    doc: "the reader's favourites, from `Slipdock.Favourites.marks/1`"

  attr :class, :any, default: nil
  attr :size, :string, default: "size-4"

  @doc """
  The heart that puts something on `/favourites`, and takes it off again.

  A heart rather than a star because a card already *has* a star — the
  "Starred" flag, which is the board's and everyone's. This one is yours:
  nobody else's list changes when you press it, so it needs only the right
  to read the thing, not to change it.
  """
  def favourite_toggle(assigns) do
    {:ok, kind} = Slipdock.Favourites.kind(assigns.kind)
    marks = assigns.marks || MapSet.new()
    assigns = assign(assigns, on: Slipdock.Favourites.favourite?(marks, kind, assigns.id))

    ~H"""
    <button
      type="button"
      class={["shrink-0 transition", @class]}
      phx-click="toggle_favourite"
      phx-value-kind={@kind}
      phx-value-id={@id}
      aria-pressed={to_string(@on)}
      aria-label={"#{if @on, do: "Remove from", else: "Add to"} favourites: #{@name}"}
      title={
        if @on,
          do: "Remove from favourites",
          else: "Favourite: keep this two taps away, under Favourites"
      }
    >
      <.icon
        name={if @on, do: "hero-heart-solid", else: "hero-heart"}
        class={[
          @size,
          if(@on, do: "text-rose-500", else: "text-base-content/30 hover:text-rose-500")
        ]}
      />
    </button>
    """
  end

  ## Quick add -----------------------------------------------------------------

  @quick_add_help "Type a title and press Enter. Mix in commands: due: tomorrow · start: next mon · #high · #blocked · #todo (a list) · #tag · @name"

  attr :id, :string, required: true, doc: "the form id; the server clears the input by it"
  attr :placeholder, :string, default: "Add a card…"

  attr :params, :map,
    default: %{},
    doc: "hidden fields sent along (group, column_id, parent_card)"

  attr :preview, :any, default: nil, doc: "a Slipdock.QuickAdd result to show as chips"
  attr :class, :any, default: nil
  attr :style, :string, default: nil

  @doc """
  A one-line add-a-card row: type, press Enter, type the next. Commands in
  the text (see `Slipdock.QuickAdd`) are previewed as chips while typing.
  """
  def quick_add_row(assigns) do
    assigns = assign(assigns, help: @quick_add_help)

    ~H"""
    <form
      id={@id}
      phx-submit="quick_add_card"
      phx-change="quick_add_change"
      class={["quick-add flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1", @class]}
      style={@style}
    >
      <input type="hidden" name="form" value={@id} />
      <input :for={{k, v} <- @params} type="hidden" name={k} value={v} />
      <.icon name="hero-plus" class="size-4 shrink-0 text-base-content/40" />
      <input
        type="text"
        name="title"
        id={"#{@id}-title"}
        phx-hook="QuickAdd"
        phx-debounce="150"
        placeholder={@placeholder}
        title={@help}
        class="input input-sm input-ghost min-w-56 max-w-xl flex-1 px-1"
        autocomplete="off"
      />
      <.quick_chips :if={@preview} chips={@preview.chips} unknown={@preview.unknown} />
    </form>
    """
  end

  ## The board chrome shared with the wiki ------------------------------------
  @view_tabs [
    {:board, "", "Board", "hero-view-columns", "Board view", "b"},
    {:outline, "/outline", "Outline", "hero-queue-list",
     "Outline view: cards and their subcards as a tree", "o"},
    {:swimlanes, "/swimlanes", "Swimlanes", "hero-squares-2x2", "Swimlane view", "s"},
    {:table, "/table", "Table", "hero-table-cells", "Table view", "t"},
    {:timeline, "/timeline", "Timeline", "hero-chart-bar", "Timeline view", "i"},
    {:calendar, "/calendar", "Calendar", "hero-calendar-days", "Calendar view", "c"},
    {:narrative, "/narrative", "Narrative", "hero-book-open",
     "Narrative view: what happened to these cards over a date range", "n"},
    {:prioritise, "/prioritise", "Prioritise", "hero-scale",
     "Prioritise view: vote, score and rank the cards", "p"}
  ]

  @doc false
  # The attribute, reachable from the helpers defined above it.
  def view_tabs_list, do: @view_tabs

  attr :board, :any, required: true
  attr :mode, :atom, required: true
  attr :config, :any, default: nil, doc: "the card view's configuration, when there is one"
  attr :view, :any, default: nil, doc: "the saved view currently loaded, if any"
  attr :marks, :any, default: nil, doc: "the reader's favourites (`Slipdock.Favourites.marks/1`)"

  # The view switcher that leads every board toolbar: the current view, with
  # the others in a menu, followed by the reader's own favourite saved views.
  def view_tabs(assigns) do
    # A simple board leaves its project-tooling views out of the menu.
    hidden = Slipdock.Boards.Board.hidden_views(assigns.board)
    tabs = Enum.reject(@view_tabs, fn {mode, _, _, _, _, _} -> mode in hidden end)

    # The wiki is not one of the card views, so it is not in the list; it
    # still has to name itself when it is what you are looking at.
    {_, _, label, icon, _, _} =
      case assigns.mode do
        :wiki -> {:wiki, "/wiki", "Wiki", "hero-book-open", "Wiki", nil}
        mode -> Enum.find(tabs, hd(tabs), fn {m, _, _, _, _, _} -> m == mode end)
      end

    marks = assigns.marks || MapSet.new()

    favourites =
      Enum.filter(assigns.board.saved_views, &Slipdock.Favourites.favourite?(marks, :view, &1.id))

    assigns = assign(assigns, tabs: tabs, label: label, icon: icon, favourites: favourites)

    ~H"""
    <div id="view-menu" class="dropdown shrink-0" phx-hook="DropdownAlign">
      <div
        tabindex="0"
        role="button"
        class="btn btn-sm gap-1.5 bg-base-100 font-medium shadow-sm ring-1 ring-base-content/10"
        title="Switch view"
        aria-label={"View: #{@label}"}
      >
        <.icon name={@icon} class="size-4" />
        <span>{@label}</span>
        <.icon name="hero-chevron-down" class="size-3 text-base-content/50" />
      </div>
      <ul
        tabindex="0"
        class="menu dropdown-content z-40 mt-1 w-64 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
        role="group"
        aria-label="View mode"
      >
        <li :for={{mode, suffix, label, icon, title, key} <- @tabs}>
          <.link
            patch={"/boards/#{@board.id}#{suffix}"}
            class={["flex items-center gap-2", @mode == mode && "menu-active"]}
            title={title}
            aria-current={@mode == mode && "page"}
          >
            <.icon name={icon} class="size-4 shrink-0" />
            <span class="flex-1">{label}</span>
            <kbd class="rounded border border-base-content/15 px-1 font-mono text-2xs text-base-content/50">
              {key}
            </kbd>
            <.icon :if={@mode == mode} name="hero-check" class="size-3.5" />
          </.link>
        </li>
        <%!-- The wiki is not a view of the cards, so it sits below the line:
              same board, different kind of thing. --%>
        <li class="mt-1 border-t border-base-content/10 pt-1">
          <.link
            navigate={~p"/boards/#{@board.id}/wiki"}
            class={["flex items-center gap-2", @mode == :wiki && "menu-active"]}
            title="Wiki: the board's documents"
            aria-current={@mode == :wiki && "page"}
          >
            <.icon name="hero-book-open" class="size-4 shrink-0" />
            <span class="flex-1">Wiki</span>
            <.icon :if={@mode == :wiki} name="hero-check" class="size-3.5" />
          </.link>
        </li>
        <%!-- The honest way to write a live query into a document: point at
              the view you already made and let the app write the syntax. --%>
        <li :if={@config}>
          <.link
            navigate={
              ~p"/boards/#{@board.id}/wiki/new?#{[block: Slipdock.Wiki.Query.to_block(@config, @board, saved_view: @view && @view.name)]}"
            }
            class="flex items-center gap-2"
            title="Start a page with this view in it, as a live query"
          >
            <.icon name="hero-document-plus" class="size-4 shrink-0" />
            <span class="flex-1">Write this into a doc</span>
          </.link>
        </li>
        <li :if={@favourites != []} class="menu-title mt-1 border-t border-base-content/10 pt-2">
          Favourite views
        </li>
        <%!-- `SlipdockWeb.SwimlaneComponents` imports this module, so reaching
              back for `view_path/2` is a remote call rather than an import:
              importing it makes the two deadlock at compile time. --%>
        <li :for={v <- @favourites}>
          <.link
            patch={SlipdockWeb.SwimlaneComponents.view_path(@board, v)}
            class={["flex items-center gap-2", @view && @view.id == v.id && "menu-active"]}
            title={"Open the “#{v.name}” view"}
            aria-current={@view && @view.id == v.id && "page"}
          >
            <.icon name="hero-heart-solid" class="size-4 shrink-0 text-rose-500" />
            <span class="min-w-0 flex-1 truncate">{v.name}</span>
            <.icon :if={@view && @view.id == v.id} name="hero-check" class="size-3.5" />
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :filters, :map, required: true
  attr :filtering, :boolean, required: true
  attr :label, :string, default: "Hide completed cards"

  attr :kinds, :boolean,
    default: true,
    doc: "Offer the Kind section. False where everything in view is the one kind."

  @doc """
  The filter dropdown the card views carry, and the wiki carries too: a wiki
  page answers every one of these, because it holds the card's facets under
  the card's names (see `Slipdock.Filters`).
  """
  def filter_menu(assigns) do
    ~H"""
    <div class="dropdown">
      <div
        tabindex="0"
        role="button"
        class={["btn btn-ghost btn-sm gap-1", @filtering && "text-primary"]}
        title="Filter"
      >
        <.icon name="hero-funnel" class="size-4" />
        <span class="hidden md:inline">Filter</span>
        <span :if={@filtering} class="badge badge-primary badge-xs">
          {Slipdock.Filters.count(@filters)}
        </span>
      </div>
      <div
        tabindex="0"
        class="dropdown-content z-30 mt-2 w-72 space-y-4 rounded-2xl bg-base-100 p-4 shadow-xl ring-1 ring-base-content/10"
      >
        <%!-- The three things a list can hold: a card, a document (a card whose
              whole content is the file on it) and a wiki page placed in the
              list. See `Slipdock.Kinds`. --%>
        <div :if={@kinds}>
          <p class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Kind
          </p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={{kind, label} <- Slipdock.Kinds.all()}
              type="button"
              class={[
                "btn btn-xs",
                if(kind in @filters.kinds, do: "btn-primary", else: "btn-ghost")
              ]}
              phx-click="filter_kind"
              phx-value-kind={kind}
              title={"Show #{String.downcase(label)}"}
            >
              <.icon name={kind_icon(kind)} class="size-3.5" /> {label}
            </button>
          </div>
        </div>
        <div :if={@board.tags != []}>
          <p class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Tags
          </p>
          <div class="flex flex-wrap gap-1.5">
            <button
              :for={tag <- @board.tags}
              type="button"
              class={[
                "rounded-md ring-2 ring-offset-1 ring-offset-base-100 transition",
                if(tag.id in @filters.tags,
                  do: "ring-primary",
                  else: "ring-transparent opacity-80 hover:opacity-100"
                )
              ]}
              phx-click="filter_tag"
              phx-value-id={tag.id}
            >
              <.tag_chip tag={tag} />
            </button>
          </div>
        </div>
        <div>
          <p class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Priority
          </p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={p <- ~w(low medium high critical)}
              type="button"
              class={["btn btn-xs", if(@filters.priority == p, do: "btn-primary", else: "btn-ghost")]}
              phx-click="filter_priority"
              phx-value-priority={p}
            >
              <.priority_badge priority={p} /> {priority_label(p)}
            </button>
          </div>
        </div>
        <div>
          <p class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Flags
          </p>
          <div class="flex flex-wrap gap-1">
            <.flag_toggle
              :for={{flag, _, _, _, _} <- flags()}
              flag={flag}
              active={@filters.flag == flag}
              phx-click="filter_flag"
              phx-value-flag={flag}
            />
          </div>
        </div>
        <div>
          <p class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Due
          </p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={
                {value, label} <- [
                  {"overdue", "Overdue"},
                  {"week", "Next 7 days"},
                  {"none", "No date"}
                ]
              }
              type="button"
              class={["btn btn-xs", if(@filters.due == value, do: "btn-primary", else: "btn-ghost")]}
              phx-click="filter_due"
              phx-value-due={value}
            >
              {label}
            </button>
          </div>
        </div>
        <label class="flex cursor-pointer items-center gap-2 text-sm">
          <input
            type="checkbox"
            class="toggle toggle-sm"
            checked={@filters.hide_completed}
            phx-click="toggle_hide_completed"
          /> {@label}
        </label>
        <button
          :if={@filtering}
          type="button"
          class="btn btn-ghost btn-xs w-full"
          phx-click="clear_filters"
        >
          Clear all filters
        </button>
      </div>
    </div>
    """
  end
end
