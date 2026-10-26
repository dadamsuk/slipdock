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
  attr :class, :string, default: "size-6"
  attr :rest, :global

  def color_swatch(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        @class,
        "rounded-full ring-offset-2 ring-offset-base-100 transition hover:scale-110",
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

  @doc """
  The edges of a card's front in their own colours (#1209): a strip on each
  side that has one, clipped to the card's rounded corners and drawn over
  it, so the card keeps its size whichever edges are coloured.
  """
  def card_borders(assigns) do
    ~H"""
    <div
      class="pointer-events-none absolute inset-0 z-[1] overflow-hidden rounded-xl"
      data-role="card-borders"
      aria-hidden="true"
    >
      <span
        :if={@card.border_top}
        data-edge="top"
        class={["absolute inset-x-0 top-0 h-1", Palette.dot(@card.border_top)]}
      ></span>
      <span
        :if={@card.border_right}
        data-edge="right"
        class={["absolute inset-y-0 right-0 w-1", Palette.dot(@card.border_right)]}
      ></span>
      <span
        :if={@card.border_bottom}
        data-edge="bottom"
        class={["absolute inset-x-0 bottom-0 h-1", Palette.dot(@card.border_bottom)]}
      ></span>
      <span
        :if={@card.border_left}
        data-edge="left"
        class={["absolute inset-y-0 left-0 w-1", Palette.dot(@card.border_left)]}
      ></span>
    </div>
    """
  end

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

  attr :dismiss, :boolean,
    default: false,
    doc: "on a stand-in, offer to dismiss it (the reader can change the board)"

  attr :selected, :boolean,
    default: nil,
    doc: """
    in the board's select mode, whether this card is picked out (`true`) or
    not (`false`); nil outside select mode
    """

  attr :zone, :string, default: "Etc/UTC", doc: "the reader's timezone, for a snoozed card's day"

  attr :handoff_note, :string,
    default: "hide",
    doc: """
    whether an open card's front shows its handoff note (#1171): "hide" (the
    ↩ mark alone), "short" (two lines) or "full"; comfortable cards only
    """

  attr :handoff_label, :string,
    default: "Left off",
    doc: "what the board calls a handoff (#1212, `Board.handoff_label/1`)"

  attr :marks, :any,
    default: nil,
    doc: """
    the reader's favourites (`Slipdock.Favourites.marks/1`); a card in them
    shows a heart on its front
    """

  slot :actions,
    doc: """
    controls rendered at the end of the card's title row — the board view's
    "move to another list" menu. Anything in here needs a `phx-click` of its
    own, or the click finds the card's and opens it instead.
    """

  def card(%{card: %{stand_in_for_id: id}} = assigns) when not is_nil(id),
    do: stand_in_card(assigns)

  def card(assigns) do
    card = assigns.card
    page? = page?(card)
    show = show_set(assigns.show)
    on = &MapSet.member?(show, &1)
    done = Enum.count(card.checklist_items, & &1.done)
    total = length(card.checklist_items)
    cover = if assigns.cover == :auto, do: card.color, else: assigns.cover
    image = if on.("images"), do: Slipdock.Boards.Attachment.front_image(loaded_attachments(card))
    handoff = Slipdock.Boards.Card.open_handoff(card)
    wait = Slipdock.Boards.Card.open_wait(card)
    recurrence = Slipdock.Boards.Card.recurrence(card)
    snoozed = Slipdock.Boards.Card.snoozed?(card)
    state = Map.get(card, :state)

    facets = %{
      cover: on.("cover") and not is_nil(cover),
      # Its own colour on each edge (#1209), shown with the cover colour.
      borders: on.("cover") and Enum.any?(Slipdock.Boards.Card.borders(), &Map.get(card, &1)),
      image: not is_nil(image),
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
      attachments: on.("attachments") and loaded_attachments(card) != [],
      # Where it was left (W-1804): always shown while the card is open, since
      # it is what the next person needs before anything else on it.
      handoff: not is_nil(handoff),
      # Waiting on a person (#1114): always shown, with what it needs.
      wait: not is_nil(wait),
      # A recurring card (W-1802): always marked, like the handoff.
      recurrence: not is_nil(recurrence),
      # Snoozed (W-1803): only seen where snoozed cards are shown, and then
      # always marked, with the day it wakes.
      snoozed: snoozed,
      # What is happening to it and who drives it (#1117): always shown when
      # there is something to say. How long it has sat in its list is a
      # facet like the rest, so a board can leave it off.
      state_line: match?(%Slipdock.CardState{line: line} when is_binary(line), state),
      driver: match?(%Slipdock.CardState{driver: d} when is_binary(d), state),
      age: on.("age") and match?(%Slipdock.CardState{age: age} when is_integer(age), state)
    }

    meta? =
      facets
      |> Map.drop([:cover, :borders, :image, :status, :tags])
      |> Map.values()
      |> Enum.any?()

    assigns =
      assign(assigns,
        done: done,
        total: total,
        f: facets,
        meta?: meta?,
        cover_color: cover,
        image: image,
        page?: page?,
        favourite?: favourite_mark?(assigns.marks, card),
        handoff: handoff,
        wait: wait,
        recurrence: recurrence,
        snoozed: snoozed,
        state: state,
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
        (@card.completed or @snoozed) && "opacity-60",
        @focus == :cursor && "z-10 ring-2 ring-secondary",
        @focus == :held && "z-10 scale-[1.02] shadow-lg ring-2 ring-primary",
        @selected && "z-10 bg-primary/5 ring-2 ring-primary"
      ]}
      data-focus={@focus}
      data-selected={@selected}
      tabindex="0"
      role="button"
      aria-pressed={if is_boolean(@selected), do: to_string(@selected)}
      phx-click={open_item(@page?, @card.id)}
      phx-keydown={open_item(@page?, @card.id)}
      phx-key="Enter"
    >
      <span
        :if={@selected}
        class="absolute -top-1.5 -right-1.5 z-10 flex size-5 items-center justify-center rounded-full bg-primary text-primary-content shadow"
        aria-hidden="true"
      >
        <.icon name="hero-check" class="size-3.5" />
      </span>
      <.card_borders :if={@f.borders} card={@card} />
      <div
        :if={@f.cover && !@compact}
        class={["h-1.5 rounded-t-xl bg-gradient-to-r", Palette.gradient(@cover_color)]}
      >
      </div>
      <img
        :if={@f.image && !@compact}
        src={Slipdock.Boards.attachment_url(@image)}
        alt={@image.filename}
        loading="lazy"
        draggable="false"
        data-role="card-image"
        class={[
          "max-h-40 w-full bg-base-200 object-cover",
          !@f.cover && "rounded-t-xl"
        ]}
      />
      <div :if={@compact} class="flex items-center gap-2 px-2.5 py-1.5">
        <span :if={@f.cover} class={["size-2 shrink-0 rounded-full", Palette.dot(@cover_color)]}></span>
        <img
          :if={@f.image}
          src={Slipdock.Boards.attachment_url(@image)}
          alt={@image.filename}
          loading="lazy"
          draggable="false"
          data-role="card-image"
          class="size-5 shrink-0 rounded object-cover"
        />
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
        <.favourite_mark :if={@favourite?} class="size-3" />
        <span
          :if={@f.tags}
          class="flex shrink-0 items-center gap-0.5"
          title={Enum.map_join(@card.tags, ", ", & &1.name)}
        >
          <span :for={tag <- @card.tags} class={["size-2 rounded-full", Palette.dot(tag.color)]}></span>
        </span>
        <.flag_icon :for={flag <- @card.flags} :if={@f.flags} flag={flag} class="size-3" />
        <.dependency_badge :if={@f.dependencies} card={@card} class="size-3" />
        <.subcards_badge :if={@f.subcards} card={@card} open={not @page?} />
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
        <.handoff_mark :if={@f.handoff} handoff={@handoff} label={@handoff_label} class="size-3" />
        <.wait_mark :if={@f.wait} wait={@wait} class="size-3" compact />
        <.recurrence_mark :if={@f.recurrence} recurrence={@recurrence} class="size-3" />
        <.snooze_mark :if={@f.snoozed} card={@card} zone={@zone} />
        <.driver_mark :if={@f.driver} state={@state} class="size-3" />
        <.state_line :if={@f.state_line} state={@state} compact />
        <.age_chip :if={@f.age} state={@state} compact />
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
          <.favourite_mark :if={@favourite?} class="mt-0.5 size-3.5" />
          <span :if={@actions != []} class="-mr-1 -mt-0.5 shrink-0">{render_slot(@actions)}</span>
        </div>

        <div :if={@meta?} class="flex flex-wrap items-center gap-1 text-base-content/60">
          <.flag_icon :for={flag <- @card.flags} :if={@f.flags} flag={flag} class="size-3.5" />
          <.dependency_badge :if={@f.dependencies} card={@card} />
          <.subcards_badge :if={@f.subcards} card={@card} open={not @page?} />
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
          <.handoff_mark :if={@f.handoff} handoff={@handoff} label={@handoff_label} />
          <.wait_mark :if={@f.wait} wait={@wait} />
          <.recurrence_mark :if={@f.recurrence} recurrence={@recurrence} />
          <.snooze_mark :if={@f.snoozed} card={@card} zone={@zone} />
          <.driver_mark :if={@f.driver} state={@state} />
          <.age_chip :if={@f.age} state={@state} />
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
        <.handoff_note
          :if={@f.handoff and @handoff_note in ~w(short full)}
          handoff={@handoff}
          label={@handoff_label}
          mode={@handoff_note}
        />
        <.state_line :if={@f.state_line} state={@state} />
      </div>
    </div>
    """
  end

  attr :handoff, :any, required: true
  attr :label, :string, required: true
  attr :mode, :string, required: true

  # The handoff itself on the card's front (#1171), when the Display menu asks
  # for it: the next step then the note, cut to two lines or in full.
  defp handoff_note(assigns) do
    assigns =
      assign(assigns,
        text: Enum.join([assigns.handoff.next_step | List.wrap(assigns.handoff.body)], "\n")
      )

    ~H"""
    <div
      class="rounded-lg bg-info/10 px-2 py-1.5 text-2xs leading-snug text-base-content/80"
      data-role="handoff-note"
      data-mode={@mode}
      title={if @mode == "short", do: @text}
    >
      <%!-- Unformatted: a line break here would show in the pre-line text. --%>
      <p phx-no-format class={["whitespace-pre-line break-words", @mode == "short" && "line-clamp-2"]}><span class="font-semibold text-info">{@label}:</span> {@text}</p>
    </div>
    """
  end

  attr :state, :any, required: true
  attr :compact, :boolean, default: false

  # What is happening to the card (#1117): the same words `card_line` and
  # the API give as `state`, coloured by what it is (#1132) so a running or
  # failed card stands out from the board around it.
  defp state_line(assigns) do
    {text, dot} = state_colours(assigns.state.kind)
    assigns = assign(assigns, text: text, dot: dot)

    ~H"""
    <p
      class={[
        "flex min-w-0 items-center gap-1 font-medium",
        @text,
        if(@compact, do: "max-w-40 shrink text-2xs", else: "text-2xs leading-snug")
      ]}
      data-role="state-line"
      data-kind={@state.kind}
      title={@state.line}
    >
      <span
        class={["size-1.5 shrink-0 rounded-full", @dot, @state.kind == "running" && "animate-pulse"]}
        aria-hidden="true"
      ></span>
      <span class="truncate">{@state.line}</span>
    </p>
    """
  end

  # The line's text and dot colours for each kind of state.
  defp state_colours("running"), do: {"text-success", "bg-success"}
  defp state_colours("claimed"), do: {"text-info", "bg-info"}
  defp state_colours("queued"), do: {"text-sky-700 dark:text-sky-300", "bg-sky-500"}

  defp state_colours(kind) when kind in ~w(waiting held),
    do: {"text-amber-700 dark:text-amber-300", "bg-amber-500"}

  defp state_colours(kind) when kind in ~w(failed timeout), do: {"text-error", "bg-error"}
  defp state_colours(_kind), do: {"text-base-content/70", "bg-base-content/40"}

  attr :state, :any, required: true
  attr :class, :string, default: "size-3.5"

  # Who is driving the card, on a tree where agents work (#1117).
  defp driver_mark(assigns) do
    ~H"""
    <span
      class={[
        "chip chip-icon chip-line",
        if(@state.driver == "agent", do: "text-secondary", else: "text-base-content/60")
      ]}
      data-role="driver-mark"
      data-driver={@state.driver}
      title={
        if @state.driver == "agent", do: "An agent is driving this", else: "A person is driving this"
      }
    >
      <.icon
        name={if @state.driver == "agent", do: "hero-cpu-chip", else: "hero-user"}
        class={@class}
      />
    </span>
    """
  end

  attr :state, :any, required: true
  attr :compact, :boolean, default: false

  # How long the card has been in its list, amber past the list's usual stay.
  defp age_chip(assigns) do
    assigns = assign(assigns, :text, Slipdock.CardState.age_text(assigns.state))

    ~H"""
    <span
      class={[
        "chip shrink-0",
        if(@state.stuck,
          do: "bg-amber-500/15 text-amber-700 dark:text-amber-300",
          else: "chip-line text-base-content/60"
        )
      ]}
      data-role="age-chip"
      data-stuck={to_string(@state.stuck)}
      title={age_title(@state)}
    >
      {if @compact, do: Slipdock.Pulse.duration(@state.age), else: @text}
    </span>
    """
  end

  defp age_title(%{known: false} = state),
    do:
      "In this list for at most #{Slipdock.Pulse.duration(state.age)} (its move here wasn't recorded)"

  defp age_title(%{usual: nil} = state),
    do: "In this list for #{Slipdock.Pulse.duration(state.age)}"

  defp age_title(state),
    do:
      "In this list for #{Slipdock.CardState.age_text(state)}; usually " <>
        Slipdock.Pulse.duration(state.usual)

  attr :handoff, :any, required: true
  attr :label, :string, required: true
  attr :class, :string, default: "size-3.5"

  # A card someone stopped short on: the next step is the tooltip.
  defp handoff_mark(assigns) do
    ~H"""
    <span
      class="chip chip-icon chip-line text-info"
      data-role="handoff-mark"
      title={@label <> " — next: " <> @handoff.next_step}
    >
      <.icon name="hero-arrow-uturn-left" class={@class} />
    </span>
    """
  end

  attr :wait, :any, required: true
  attr :class, :string, default: "size-3.5"
  attr :compact, :boolean, default: false

  # A card waiting on a person (#1114): what it needs, and from whom.
  defp wait_mark(assigns) do
    ~H"""
    <span
      class="chip chip-line max-w-full gap-1 text-warning"
      data-role="wait-mark"
      title={"Waiting on " <> Slipdock.Boards.Wait.on_name(@wait) <> ": " <> @wait.needs}
    >
      <.icon name="hero-hand-raised" class={@class} />
      <span :if={!@compact} class="truncate">{@wait.needs}</span>
    </span>
    """
  end

  attr :card, :any, required: true
  attr :zone, :string, default: "Etc/UTC"

  @doc "💤 and the day a snoozed card wakes (W-1803), the note as its tooltip."
  def snooze_mark(assigns) do
    ~H"""
    <span
      class="chip chip-line shrink-0 text-base-content/70"
      data-role="snooze-mark"
      title={snooze_title(@card, @zone)}
    >
      <span aria-hidden="true" class="leading-none">💤</span>
      {@card.snoozed_until |> Slipdock.Timezones.to_local(@zone) |> Calendar.strftime("%-d %b")}
      <span class="sr-only">Snoozed</span>
    </span>
    """
  end

  defp snooze_title(card, zone) do
    local = Slipdock.Timezones.to_local(card.snoozed_until, zone)
    until = "Snoozed until " <> Calendar.strftime(local, "%a %-d %b %Y %H:%M")
    if card.snooze_note, do: until <> " — " <> card.snooze_note, else: until
  end

  attr :recurrence, :any, required: true
  attr :class, :string, default: "size-3.5"

  defp recurrence_mark(assigns) do
    ~H"""
    <span
      class="chip chip-icon chip-line text-accent"
      data-role="recurrence-mark"
      title={recurrence_title(@recurrence)}
    >
      <span aria-hidden="true" class="leading-none">↻</span>
      <span class="sr-only">Repeats</span>
    </span>
    """
  end

  defp recurrence_title(series) do
    state =
      cond do
        series.ended_at -> " — ended"
        series.paused -> " — paused"
        series.next_on -> " — next due #{Calendar.strftime(series.next_on, "%a %-d %b")}"
        true -> ""
      end

    "Repeats: " <> Slipdock.Recurrence.Series.summary(series) <> state
  end

  # A card or a placed page the reader has favourited. Only a mark, not the
  # toggle: a click on the front of the card opens it.
  defp favourite_mark?(nil, _card), do: false

  defp favourite_mark?(marks, card),
    do: Slipdock.Favourites.favourite?(marks, if(page?(card), do: :page, else: :card), card.id)

  attr :class, :string, default: "size-3.5"

  defp favourite_mark(assigns) do
    ~H"""
    <span class="shrink-0 text-rose-500" data-role="favourite-mark" title="In your favourites">
      <.icon name="hero-heart-solid" class={@class} />
      <span class="sr-only">Favourite</span>
    </span>
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

  # A stand-in: what sprint planning leaves where a card it took used to be.
  # Nothing on it is its own — the title, the sprint and the status are the
  # real card's, read as the board loads — and opening it opens that card.
  defp stand_in_card(assigns) do
    target = loaded(assigns.card.stand_in_for)
    {label, class, icon} = stand_in_status(target)

    assigns =
      assign(assigns,
        title: (target && target.title) || assigns.card.title,
        where: stand_in_where(target),
        label: label,
        status_class: class,
        status_icon: icon
      )

    ~H"""
    <div
      id={@id || "card-#{@card.id}"}
      data-id={@card.id}
      data-stand-in={@card.stand_in_for_id}
      class={[
        "kanban-card kanban-stand-in group relative cursor-grab rounded-xl border border-dashed",
        "border-base-content/20 bg-base-100/60 outline-none transition",
        "hover:border-primary/40 hover:bg-base-100 active:cursor-grabbing",
        "focus-visible:ring-2 focus-visible:ring-primary/50",
        @focus == :cursor && "z-10 ring-2 ring-secondary",
        @focus == :held && "z-10 scale-[1.02] shadow-lg ring-2 ring-primary"
      ]}
      data-focus={@focus}
      tabindex="0"
      role="button"
      title={"Stand-in: this card moved to #{@where || "another board"}. Open it there."}
      phx-click={JS.push("open_card", value: %{id: @card.id})}
      phx-keydown={JS.push("open_card", value: %{id: @card.id})}
      phx-key="Enter"
    >
      <div class={["flex items-center gap-2 px-2.5", if(@compact, do: "py-1.5", else: "pt-2")]}>
        <.icon name="hero-arrow-uturn-right" class="size-3.5 shrink-0 text-base-content/40" />
        <p
          class={[
            "min-w-0 flex-1 truncate font-medium leading-snug text-base-content/70",
            if(@compact, do: "text-2xs", else: "text-xs")
          ]}
          title={@title}
        >
          {@title}
        </p>
        <span
          :if={@compact}
          class={["chip shrink-0 text-2xs", @status_class]}
          title={stand_in_summary(@where, @label)}
        >
          <.icon name={@status_icon} class="size-3" />
        </span>
        <span :if={@actions != []} class="-mr-1 shrink-0">{render_slot(@actions)}</span>
        <button
          :if={@dismiss}
          type="button"
          class="-mr-1 shrink-0 rounded p-0.5 text-base-content/30 opacity-0 transition hover:text-base-content group-hover:opacity-100 focus-visible:opacity-100"
          phx-click={JS.push("dismiss_stand_in", value: %{id: @card.id})}
          title="Dismiss this stand-in"
          aria-label={"Dismiss the stand-in for #{@title}"}
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
      <div :if={!@compact} class="flex flex-wrap items-center gap-1 px-2.5 pt-1 pb-2 text-2xs">
        <span :if={@where} class="chip chip-line max-w-40 truncate text-base-content/60">
          <.icon name="hero-arrow-right" class="size-3" /> {@where}
        </span>
        <span class={["chip", @status_class]}>
          <.icon name={@status_icon} class="size-3" /> {@label}
        </span>
      </div>
    </div>
    """
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded(value), do: value

  # Where the real card is now: the sprint holding it, or the board when it
  # has gone somewhere that is not a sprint's.
  defp stand_in_where(nil), do: nil

  defp stand_in_where(%{board: board}) do
    case loaded(board) do
      nil -> nil
      %{parent_card: parent} = board -> (loaded(parent) && parent.title) || board.name
    end
  end

  defp stand_in_summary(nil, label), do: label
  defp stand_in_summary(where, label), do: "#{where} · #{label}"

  # The real card's status, from its list's category rather than its list's
  # name: the two boards' lists need not match, but every board knows what
  # to-do, doing and done mean.
  @stand_in_statuses %{
    deleted: {"Deleted", "chip-line text-base-content/50", "hero-trash"},
    archived: {"Archived", "chip-line text-base-content/50", "hero-archive-box"},
    done: {"Done", "bg-success/15 text-success", "hero-check-circle"},
    doing: {"In progress", "bg-sky-500/15 text-sky-700 dark:text-sky-300", "hero-play-circle"},
    dropped: {"Dropped", "chip-line text-base-content/50", "hero-x-circle"},
    todo: {"To do", "chip-line text-base-content/70", "hero-stop-circle"}
  }

  @doc "The status a stand-in shows for the card it stands for, as `{label, class, icon}`."
  def stand_in_status(target), do: Map.fetch!(@stand_in_statuses, stand_in_state(target))

  @doc "The same, as a word: deleted, archived, done, doing, dropped or todo."
  def stand_in_state(nil), do: :deleted
  def stand_in_state(%{archived_at: at}) when not is_nil(at), do: :archived

  def stand_in_state(target) do
    case loaded(Map.get(target, :column)) do
      %{category: "done"} -> :done
      %{category: "doing"} -> :doing
      %{category: "dropped"} -> :dropped
      _ -> if target.completed, do: :done, else: :todo
    end
  end

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

  attr :size, :string,
    default: "md",
    doc:
      ~s("sm", "md", "lg", "xl", "page": 80% of the screen, for a long form like board settings, or "wide": 90%, for a card opened full screen)

  attr :keys, :boolean,
    default: false,
    doc: "give the dialog the keyboard: arrows, hjkl, PageUp/Down, Home/End and the section keys"

  slot :actions,
    doc: "buttons that sit in the top corner beside the close button, on the same row"

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
          @size == "lg" && "max-w-4xl",
          @size == "xl" && "max-w-6xl",
          @size == "page" && "sm:max-w-[80%]",
          @size == "wide" && "sm:max-w-[90%]"
        ]}
        phx-click-away={@on_close}
      >
        <div class="modal-actions absolute right-3 top-3 z-10 flex items-center gap-2">
          {render_slot(@actions)}
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-circle"
            phx-click={@on_close}
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  ## Favourites -----------------------------------------------------------------

  attr :kind, :string,
    required: true,
    doc: ~s(what is being favourited: "board", "column", "card", "view" or "page")

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

  @quick_add_help "Type a title and press Enter. Mix in commands: due: tomorrow · start: next mon · #high · #blocked · #todo (a list) · #tag · @name · ; a comment"

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
     "Prioritise view: vote, score and rank the cards", "p"},
    {:visualise, "/visualise", "Visualise", "hero-presentation-chart-line",
     "Visualise: flow, velocity, runners and delivery on one page", "g"}
  ]

  # The views that are pages of their own rather than modes of the board
  # page, so they are navigated to, not patched.
  @page_views [:visualise]

  @doc false
  # The attribute, reachable from the helpers defined above it.
  def view_tabs_list, do: @view_tabs

  attr :board, :any, required: true
  attr :mode, :atom, required: true
  attr :view, :any, default: nil, doc: "the saved view currently loaded, if any"
  attr :marks, :any, default: nil, doc: "the reader's favourites (`Slipdock.Favourites.marks/1`)"

  attr :meetings, :atom,
    default: :none,
    doc:
      "`:tab` puts Meetings beside the wiki (see `Slipdock.Meetings.presence/2`); on a meeting page, `:hidden` when the reader hid it"

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
        :wiki ->
          {:wiki, "/wiki", "Wiki", "hero-book-open", "Wiki", nil}

        :meetings ->
          # A conversation's page with meeting mode off (#1077), or not on
          # for the reader (#1206), is no Meetings tab.
          if assigns.meetings != :none,
            do: {:meetings, "/meetings", "Meetings", "hero-microphone", "Meetings", nil},
            else:
              {:meetings, "/meetings", "Conversation", "hero-chat-bubble-left-right",
               "Conversation", nil}

        mode ->
          Enum.find(tabs, hd(tabs), fn {m, _, _, _, _, _} -> m == mode end)
      end

    marks = assigns.marks || MapSet.new()

    favourites =
      Enum.filter(assigns.board.saved_views, &Slipdock.Favourites.favourite?(marks, :view, &1.id))

    assigns =
      assign(assigns,
        tabs: tabs,
        label: label,
        icon: icon,
        favourites: favourites,
        page_views: @page_views
      )

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
            patch={mode not in @page_views && "/boards/#{@board.id}#{suffix}"}
            navigate={mode in @page_views && "/boards/#{@board.id}#{suffix}"}
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
        <%!-- Meeting capture, the other thing a board keeps beside its cards,
              while meeting mode shows here (see `Slipdock.Meetings`). --%>
        <li :if={@meetings == :tab or (@mode == :meetings and @meetings != :none)}>
          <.link
            id="view-menu-meetings"
            navigate={~p"/boards/#{@board.id}/meetings"}
            class={["flex items-center gap-2", @mode == :meetings && "menu-active"]}
            title="Meetings: captures of what was decided and agreed"
            aria-current={@mode == :meetings && "page"}
          >
            <.icon name="hero-microphone" class="size-4 shrink-0" />
            <span class="flex-1">Meetings</span>
            <.icon :if={@mode == :meetings} name="hero-check" class="size-3.5" />
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

  attr :states, :boolean,
    default: false,
    doc: """
    Offer the filters that read a card's state (#1117): Stuck, and Agent /
    Human on a tree with a runner rule. Cards only; a page has no state.
    """

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
        <div :if={@states}>
          <p class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Time in list
          </p>
          <button
            type="button"
            class={["btn btn-xs", if(@filters.stuck, do: "btn-primary", else: "btn-ghost")]}
            phx-click="filter_stuck"
            title="Cards in their list longer than it usually takes"
          >
            <.icon name="hero-clock" class="size-3.5" /> Stuck
          </button>
        </div>
        <div :if={@states and @board.runner_tree}>
          <p class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Driver
          </p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={{value, label} <- Slipdock.Swimlanes.Config.drivers()}
              type="button"
              class={[
                "btn btn-xs",
                if((@filters.driver || "all") == value, do: "btn-primary", else: "btn-ghost")
              ]}
              phx-click="filter_driver"
              phx-value-driver={value}
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

  ## Support access --------------------------------------------------------

  attr :id, :string, required: true
  attr :boards, :list, required: true

  @doc """
  The boards a support session opens, as links: the way in to what the
  session grants, which no board list shows (see `Slipdock.Access.supported_boards/1`).
  """
  def support_board_links(assigns) do
    ~H"""
    <p :if={@boards == []} id={@id} class="text-xs text-base-content/60">
      They have no boards of their own.
    </p>
    <ul :if={@boards != []} id={@id} class="flex flex-wrap gap-1.5">
      <li :for={board <- @boards}>
        <.link
          navigate={~p"/boards/#{board}"}
          id={"#{@id}-#{board.id}"}
          class="flex items-center gap-1.5 rounded-lg bg-base-100 px-2 py-1 text-xs font-medium ring-1 ring-base-content/10 hover:ring-primary/40"
        >
          <span class={["size-2 shrink-0 rounded-full", Palette.dot(board.color)]}></span>
          {board.name}
          <span :if={board.code} class="font-mono text-2xs text-base-content/50">{board.code}</span>
        </.link>
      </li>
    </ul>
    """
  end

  @doc "How long a support session has left, as \"3h 52m\"."
  def support_time_left(%DateTime{} = expires_at, now \\ DateTime.utc_now()) do
    minutes = max(DateTime.diff(expires_at, now, :minute), 0)

    case {div(minutes, 60), rem(minutes, 60)} do
      {0, m} -> "#{m}m"
      {h, 0} -> "#{h}h"
      {h, m} -> "#{h}h #{m}m"
    end
  end
end
