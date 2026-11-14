defmodule SlipdockWeb.SlipdockComponents.Schedule do
  @moduledoc "Dates as a card shows them: the due and start badges, the range of the two, the overrun chips and their sentences, and a moment as a `<time>`."
  use Phoenix.Component

  alias SlipdockWeb.Dates

  import SlipdockWeb.CoreComponents, only: [icon: 1]

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
        "Due #{Dates.full(@date)}" <>
          if(@derived, do: " (rolled up from subcards)", else: "")
      }
    >
      <.icon
        name={
          cond do
            @state == :done -> "hero-check-circle"
            @derived -> "hero-arrow-up-on-square-stack"
            true -> due_icon()
          end
        }
        class="size-3"
      />
      {format_due(@date)}
    </span>
    """
  end

  attr :card, :map, required: true

  attr :due, :boolean,
    default: true,
    doc: "false when the due date is already drawn, in a `date_range_badge/1`"

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
        show_due: assigns.due,
        card: card
      )

    ~H"""
    <.due_badge :if={@show_due} date={@due} completed={@card.completed} derived={@derived} />
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

  defp fmt_long(%Date{} = d), do: Dates.long(d)
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
      data-role="start-slip"
      title={"#{start_words(@card)}. " <> past_date_detail(:start, @start_slip, @derived_start)}
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
      n when n > 0 and n < 7 -> Dates.day_name(date)
      _ -> Dates.short(date)
    end
  end

  @doc "How long ago (or ahead) a moment is: `SlipdockWeb.Dates.relative/2`. In markup prefer `timestamp/1`, which adds the exact time."
  def relative_time(value), do: Dates.relative(value)

  attr :at, :any, required: true, doc: "a DateTime, NaiveDateTime or Date; nil renders nothing"
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :zone, :string, default: nil, doc: "the viewer's timezone; the process's when nil"
  attr :format, :atom, default: :relative, values: [:relative, :short, :long, :datetime, :time]

  @doc """
  A moment as people read it, in a `<time>` with the machine value in
  `datetime` and the exact time in `title` (#1719): "5 min ago" that says
  "4 Nov 2026, 11:43 UTC" on hover. `format` picks another
  `SlipdockWeb.Dates` style for the text.

  A relative moment (not a bare date) carries `data-relative` (`past` or
  `future`, against the server's clock) and `data-zone`, the timezone it was
  written in, so `assets/js/relative_time.js` keeps its words up to date in
  the browser without a re-render (#2025).
  """
  def timestamp(assigns) do
    zone = assigns.zone || Dates.zone()
    opts = [zone: zone]
    at = assigns.at

    assigns =
      assign(assigns,
        text: at && apply(Dates, assigns.format, [at, opts]),
        title: at && Dates.exact(at, opts),
        iso: at && iso8601(at),
        relative: relative_mark(at, assigns.format),
        tick_zone: zone
      )

    ~H"""
    <time
      :if={@at}
      id={@id}
      class={@class}
      datetime={@iso}
      title={@title}
      data-role="timestamp"
      data-relative={@relative}
      data-zone={@relative && @tick_zone}
    >{@text}</time>
    """
  end

  # Which side of the server's clock a ticking moment is on; nil for one that
  # doesn't tick (another format, or a bare date, which has no time to count).
  defp relative_mark(%Date{}, _format), do: nil
  defp relative_mark(nil, _format), do: nil

  defp relative_mark(at, :relative) do
    at = if is_struct(at, NaiveDateTime), do: DateTime.from_naive!(at, "Etc/UTC"), else: at
    if DateTime.compare(at, DateTime.utc_now()) == :gt, do: "future", else: "past"
  end

  defp relative_mark(_at, _format), do: nil

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at) <> "Z"
  defp iso8601(%Date{} = d), do: Date.to_iso8601(d)

  attr :card, :map, required: true

  @doc """
  A card's start and due dates as one range, "31 Oct → 5 Nov" (#1708), for
  a card front that shows both. Tinted as `due_badge/1` tints the due date:
  overdue and due soon need attention, anything later is plain. Draws
  nothing unless both dates are set.
  """
  def date_range_badge(assigns) do
    card = assigns.card
    start = Slipdock.Boards.Card.effective_start(card)
    due = Slipdock.Boards.Card.effective_due(card)

    assigns =
      assign(assigns,
        start: start,
        due: due,
        state: due && due_state(due, card.completed),
        derived:
          Slipdock.Boards.Card.start_derived?(card) or Slipdock.Boards.Card.due_derived?(card)
      )

    ~H"""
    <span
      :if={@start && @due}
      data-role="date-range"
      data-state={@state}
      class={[
        "chip",
        @state == :done && "bg-success/15 text-success",
        @state == :overdue && "bg-error/15 text-error",
        @state == :soon && "bg-amber-500/15 text-amber-700 dark:text-amber-300",
        @state == :later && "chip-line text-base-content/70"
      ]}
      title={
        "Starts #{Dates.full(@start)}, due " <>
          Dates.full(@due) <>
          if(@derived, do: " (rolled up from subcards)", else: "")
      }
    >
      <.icon name="hero-calendar-date-range" class="size-3" />
      {format_range(@start, @due)}
    </span>
    """
  end

  @doc """
  A start-to-due range, as in \"31 Oct → 5 Nov\", with the year on a date
  outside this one: `SlipdockWeb.Dates.range/3`, so "this year" is the
  viewer's (the `:zone` option, else the process's), not UTC's (#2879).
  """
  def format_range(start, due, opts \\ []), do: Dates.range(start, due, opts)

  # The date icons, one pair everywhere a start or a due date is drawn: the
  # card face, the filter menu and the card back (#1709). An arrow into a
  # circle for "begins", a calendar for "due". The clock is the Waiting
  # flag's, and the play triangle read as media controls.
  @start_icon "hero-arrow-right-circle"
  @due_icon "hero-calendar"

  @doc "The icon drawn beside a start date."
  def start_icon, do: @start_icon
  @doc "The icon drawn beside a due date."
  def due_icon, do: @due_icon

  @doc """
  When a card starts, said in words and counted from `today` (#1709):
  "Starts in 11 days", "Starts tomorrow", "Starts today", "Started
  yesterday", "Started 3 days ago". When its subcards begin after the
  card's own start date it says how late instead: "Started 11 days late",
  or "Starts 11 days late" while they are still to begin. A completed card
  is never late. `nil` when the card has no start date at all.
  """
  def start_words(card, today \\ Date.utc_today()) do
    slip = Slipdock.Boards.Card.start_slip(card)

    case Slipdock.Boards.Card.effective_start(card) do
      nil ->
        nil

      %Date{} = start ->
        if slip > 0 and not Map.get(card, :completed, false),
          do: late_words(slip, card.rollup.derived_start || start, today),
          else: start_in_words(Date.diff(start, today))
    end
  end

  defp late_words(slip, begins, today) do
    verb = if Date.compare(begins, today) == :gt, do: "Starts", else: "Started"
    "#{verb} #{slip} #{plural_days(slip)} late"
  end

  defp start_in_words(0), do: "Starts today"
  defp start_in_words(1), do: "Starts tomorrow"
  defp start_in_words(-1), do: "Started yesterday"
  defp start_in_words(n) when n > 1, do: "Starts in #{n} days"
  defp start_in_words(n), do: "Started #{-n} days ago"

  attr :card, :map, required: true

  @doc """
  When the card starts: its own start date, or the one rolled up from its
  subcards. The tooltip says it in words first ("Starts in 11 days",
  "Started 11 days late"), then the full date.
  """
  def start_badge(assigns) do
    card = assigns.card

    assigns =
      assign(assigns,
        date: Slipdock.Boards.Card.effective_start(card),
        derived: Slipdock.Boards.Card.start_derived?(card),
        words: start_words(card),
        icon_name: @start_icon
      )

    ~H"""
    <span
      :if={@date}
      data-role="start"
      class={[
        "chip chip-line text-base-content/70",
        @derived && "ring-1 ring-inset ring-dashed ring-current/40"
      ]}
      title={
        "#{@words}: #{Dates.full(@date)}" <>
          if(@derived, do: " (rolled up from subcards)", else: "")
      }
    >
      <.icon name={@icon_name} class="size-3" /> {format_day(@date)}
    </span>
    """
  end

  def format_day(date) do
    case Date.diff(date, Date.utc_today()) do
      0 -> "Today"
      1 -> "Tomorrow"
      -1 -> "Yesterday"
      _ -> Dates.short(date)
    end
  end
end
