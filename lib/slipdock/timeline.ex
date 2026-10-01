defmodule Slipdock.Timeline do
  @moduledoc """
  The timeline (Gantt) view: a window of days anchored on a date, header
  rows for the chosen zoom unit and the coarser unit above it, and one bar per
  scheduled card placed by its start and due dates. Grouping, filtering and
  sorting come from `Slipdock.Table.rows/3`, so the timeline shares them with
  the table and swimlane views.

  A card is scheduled when it has a start date, a due date or both: with one
  date it occupies that single day. A card without dates of its own takes the
  dates rolled up from its subcards (see `Slipdock.Rollup`); such bars are
  marked derived and can't be dragged. Cards with neither are listed
  separately.

  With a `depth` above one, each bar carries the bars of the card's subcards
  (`children`, nested to that depth, `level` counting from 0), so a roadmap
  can be opened into the delivery plan beneath it. When a card's subcards
  aren't shown beneath its bar (cut off by the depth, or not in the window),
  `more` counts them and `sub_board_id` is the board they live on.

  Everything here is pure; persistence lives in `Slipdock.Boards`.
  """

  alias Slipdock.Boards.Card
  alias Slipdock.Dates
  alias Slipdock.Outline
  alias Slipdock.Rollup
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Table

  # Per zoom unit: how many units come before the anchor, how many the window
  # holds in total, and how wide one day is drawn (px).
  @windows %{
    "day" => {7, 35, 44},
    "week" => {3, 16, 14},
    "month" => {2, 9, 5},
    "quarter" => {2, 8, 2},
    "year" => {1, 4, 1}
  }

  # The header row drawn above the units row.
  @super_unit %{"day" => "month", "week" => "month", "month" => "year", "quarter" => "year"}

  @type bar :: %{
          card: Card.t(),
          from: non_neg_integer,
          to: pos_integer,
          kind: :span | :due | :start,
          clipped_start: boolean,
          clipped_end: boolean,
          derived_start: boolean,
          derived_end: boolean,
          level: non_neg_integer,
          children: [bar],
          more: non_neg_integer,
          sub_board_id: integer | nil
        }

  @doc "The zoom units a timeline offers, as `{key, label}`."
  def units, do: Enum.map(Config.units(), fn {k, l} -> {k, l} end)

  @doc """
  Builds the timeline for `board`. Returns a map with:

    * `:groups` – from the `rows` axis, each with `:bars` (see `t:bar/0`)
    * `:unscheduled` – filtered cards that have no dates
    * `:earlier` / `:later` – scheduled cards entirely outside the window
    * `:window` – `from`, `to` (exclusive), `days`, `px` per day, `today`
      (index or nil), `weekends` (indexes, day unit only), `header` and
      `units` (cells as `%{label, from, span, tone}`)
    * `:milestones` – the tree's milestones inside the window, each with
      its day index (`idx`)
    * `:links` – dependencies between bars in the window, as
      `%{from: blocker_id, to: blocked_id, violated: bool}`; violated when
      the blocked card starts before its blocker is done
    * `:title`, `:prev`, `:next` – for the toolbar's navigation
    * `:shown` / `:hidden` – filter counts, `:grouped`, `:unit`
  """
  def build(board, %Config{} = config, today \\ Date.utc_today()) do
    unit = if Map.has_key?(@windows, config.unit), do: config.unit, else: "week"
    {before, total, px} = Map.fetch!(@windows, unit)
    anchor = Config.anchor(config, today)
    # Day zoom shows whole weeks so weekends line up; the anchor's week is the second one.
    from = anchor |> window_start(unit) |> shift(unit, -before)
    to = shift(from, unit, total)
    days = Date.diff(to, from)

    rows = Table.rows(board, config, today)
    rollup = Map.get(board, :rollup)
    depth = Outline.depth(config)

    {groups, outside} =
      Enum.map_reduce(rows.groups, %{}, fn group, outside ->
        {bars, outside} =
          Enum.reduce(group.cards, {[], outside}, fn card, {bars, outside} ->
            case place(card, from, days) do
              {:bar, bar} -> {[nest(bar, rollup, depth, from, days) | bars], outside}
              {:outside, side} -> {bars, Map.put(outside, card.id, side)}
              :unscheduled -> {bars, outside}
            end
          end)

        {group
         |> Map.delete(:cards)
         |> Map.merge(%{bars: Enum.reverse(bars), count: length(bars)}), outside}
      end)

    groups = if config.empty == "hide", do: Enum.reject(groups, &(&1.bars == [])), else: groups

    unscheduled =
      rows.groups
      |> Enum.flat_map(& &1.cards)
      # A card and a placed wiki page can share a number: the two id spaces
      # are separate, so what makes a row unique is the pair.
      |> Enum.uniq_by(&{&1.__struct__, &1.id})
      |> Enum.filter(&is_nil(starts_on(&1)))

    today_idx = Date.diff(today, from)

    milestones =
      for m <- Map.get(board, :milestones) || [],
          idx = Date.diff(m.date, from),
          idx >= 0 and idx < days,
          do: %{
            id: m.id,
            name: m.name,
            date: m.date,
            color: m.color,
            card_id: m.card_id,
            idx: idx
          }

    visible = groups |> Enum.flat_map(&flatten_bars(&1.bars)) |> Map.new(&{&1.card.id, &1.card})

    links =
      for {_, card} <- visible,
          is_list(card.blocked_by),
          blocker <- card.blocked_by,
          Map.has_key?(visible, blocker.id),
          is_nil(blocker.archived_at),
          uniq: true do
        %{
          from: blocker.id,
          to: card.id,
          violated: not blocker.completed and blocker in Card.violated_blockers(card)
        }
      end

    %{
      groups: groups,
      milestones: milestones,
      links: links,
      grouped: rows.grouped,
      unscheduled: unscheduled,
      earlier: Enum.count(outside, fn {_, side} -> side == :earlier end),
      later: Enum.count(outside, fn {_, side} -> side == :later end),
      window: %{
        from: from,
        to: to,
        days: days,
        px: px,
        today: if(today_idx in 0..(days - 1)//1, do: today_idx),
        weekends: if(unit == "day", do: weekends(from, days), else: []),
        header: if(super = @super_unit[unit], do: cells(from, to, super, today), else: []),
        units: cells(from, to, unit, today)
      },
      title: title(from, Date.add(to, -1), unit),
      prev: from |> shift(unit, before - total) |> Date.to_iso8601(),
      next: from |> shift(unit, before + total) |> Date.to_iso8601(),
      unit: unit,
      shown: rows.shown,
      hidden: rows.hidden,
      levels: if(rollup, do: Rollup.levels(rollup, board.id), else: 1)
    }
  end

  defp flatten_bars(bars), do: Enum.flat_map(bars, &[&1 | flatten_bars(&1.children)])

  # Hangs the scheduled subcards of a bar's card beneath it, to `depth`
  # levels, and notes when the card has subcards that don't appear there.
  defp nest(bar, nil, _depth, _from, _days), do: bar

  defp nest(bar, rollup, depth, from, days) do
    children =
      if depth == :all or bar.level + 1 < depth do
        rollup
        |> Rollup.children(bar.card)
        |> Enum.flat_map(fn kid ->
          case place(kid, from, days) do
            {:bar, b} -> [nest(%{b | level: bar.level + 1}, rollup, depth, from, days)]
            _ -> []
          end
        end)
      else
        []
      end

    stats = Rollup.stats(rollup, bar.card)

    %{
      bar
      | children: children,
        more: if(children == [] and stats, do: stats.children, else: 0),
        sub_board_id: Map.get(rollup.sub_board, bar.card.id)
    }
  end

  @doc """
  The attribute changes that move a bar by `delta` days: `"both"` shifts the
  whole card, `"start"` and `"end"` move one edge (never past the other). A
  card with a single date grows the other one from it when an edge is pulled.

  A card scheduled at a coarser precision (a month, a quarter) moves by whole
  buckets: the drag is rounded to the nearest number of buckets, and a drag
  shorter than half a bucket does nothing.
  """
  def shift_attrs(%Card{} = card, edge, delta) when is_integer(delta) do
    starts = card.start_date
    due = card.due_date

    {unit, n} =
      if Card.fuzzy?(card),
        do: {card.date_precision, round(delta / Dates.approx_days(card.date_precision))},
        else: {"day", delta}

    add = &Dates.shift(&1, unit, n)

    case edge do
      _ when n == 0 ->
        %{}

      "both" ->
        %{}
        |> put_date("start_date", starts && add.(starts))
        |> put_date("due_date", due && add.(due))

      "start" ->
        new_start = add.(starts || due)
        new_start = if due && Date.compare(new_start, due) == :gt, do: due, else: new_start
        %{"start_date" => new_start}

      # A due-only card is a one-day pill: pulling its right edge out keeps
      # that day as the start, so the card grows into a span rather than moving.
      "end" when is_nil(starts) and n > 0 ->
        %{"start_date" => due, "due_date" => add.(due)}

      "end" when is_nil(starts) ->
        %{}

      "end" ->
        new_due = add.(due || starts)
        new_due = if Date.compare(new_due, starts) == :lt, do: starts, else: new_due
        %{"due_date" => new_due}
    end
  end

  defp put_date(attrs, _key, nil), do: attrs
  defp put_date(attrs, key, date), do: Map.put(attrs, key, date)

  ## Placement ---------------------------------------------------------------

  defp place(card, from, days) do
    case {starts_on(card), ends_on(card)} do
      {nil, _} ->
        :unscheduled

      {starts, ends} ->
        s = Date.diff(starts, from)
        e = Date.diff(ends, from) + 1
        {kind, derived_start, derived_end} = kind(card)

        cond do
          e <= 0 ->
            {:outside, :earlier}

          s >= days ->
            {:outside, :later}

          true ->
            {:bar,
             %{
               card: card,
               from: max(s, 0),
               to: min(e, days),
               kind: kind,
               clipped_start: s < 0,
               clipped_end: e > days,
               derived_start: derived_start,
               derived_end: derived_end,
               level: 0,
               children: [],
               more: 0,
               sub_board_id: nil
             }}
        end
    end
  end

  # Effective dates: the card's own, else those rolled up from its subcards.
  defp starts_on(card), do: Card.effective_start(card) || Card.effective_due(card)
  defp ends_on(card), do: Card.effective_due(card) || Card.effective_start(card)

  # The bar's shape and which of its edges come from subcards rather than the card.
  defp kind(card) do
    start = Card.effective_start(card)
    due = Card.effective_due(card)
    ds = Card.start_derived?(card)
    de = Card.due_derived?(card)

    case {start, due} do
      # A range rolled up from a single day beneath is a due date, not a span.
      {%Date{}, %Date{}} when start == due and (ds or de) -> {:due, true, true}
      {%Date{}, %Date{}} -> {:span, ds, de}
      {nil, %Date{}} -> {:due, de, de}
      _ -> {:start, ds, ds}
    end
  end

  defp weekends(from, days) do
    for i <- 0..(days - 1)//1, Date.day_of_week(Date.add(from, i)) >= 6, do: i
  end

  ## Header cells --------------------------------------------------------------

  # One cell per `unit` bucket intersecting [from, to), clipped to the window.
  defp cells(from, to, unit, today) do
    Stream.unfold(from, fn cur ->
      if Date.compare(cur, to) == :lt do
        start = unit_start(cur, unit)
        finish = start |> shift(unit, 1) |> min_date(to)

        tone =
          cond do
            Date.compare(today, start) != :lt and
                Date.compare(today, shift(start, unit, 1)) == :lt ->
              :current

            Date.compare(finish, today) != :gt ->
              :past

            true ->
              nil
          end

        {%{
           label: label(start, unit, today),
           from: Date.diff(cur, from),
           span: Date.diff(finish, cur),
           tone: tone
         }, finish}
      end
    end)
    |> Enum.to_list()
  end

  defp min_date(a, b), do: if(Date.compare(a, b) == :gt, do: b, else: a)

  defp label(d, "day", _today), do: Calendar.strftime(d, "%a %-d")
  defp label(d, "week", _today), do: Calendar.strftime(d, "%-d %b")

  defp label(d, "month", today),
    do: Calendar.strftime(d, if(d.year == today.year, do: "%b", else: "%b %Y"))

  defp label(d, "quarter", _today), do: "Q#{div(d.month - 1, 3) + 1} #{d.year}"
  defp label(d, "year", _today), do: Integer.to_string(d.year)

  defp title(from, last, unit) when unit in ~w(day week) do
    if from.year == last.year and from.month == last.month,
      do: Calendar.strftime(from, "%B %Y"),
      else: "#{Calendar.strftime(from, "%b %Y")} – #{Calendar.strftime(last, "%b %Y")}"
  end

  defp title(from, last, _unit) do
    if from.year == last.year,
      do: Integer.to_string(from.year),
      else: "#{from.year} – #{last.year}"
  end

  ## Date arithmetic -------------------------------------------------------------

  defp window_start(d, "day"), do: Date.beginning_of_week(d)
  defp window_start(d, unit), do: unit_start(d, unit)

  @doc "The first day of the `unit` bucket containing `date`."
  def unit_start(%Date{} = d, "day"), do: d
  def unit_start(%Date{} = d, "week"), do: Date.beginning_of_week(d)
  def unit_start(%Date{} = d, "month"), do: Date.beginning_of_month(d)
  def unit_start(%Date{} = d, "quarter"), do: Date.new!(d.year, div(d.month - 1, 3) * 3 + 1, 1)
  def unit_start(%Date{} = d, "year"), do: Date.new!(d.year, 1, 1)

  @doc "`date` moved by `n` units (negative to go back)."
  def shift(%Date{} = d, "day", n), do: Date.shift(d, day: n)
  def shift(%Date{} = d, "week", n), do: Date.shift(d, week: n)
  def shift(%Date{} = d, "month", n), do: Date.shift(d, month: n)
  def shift(%Date{} = d, "quarter", n), do: Date.shift(d, month: 3 * n)
  def shift(%Date{} = d, "year", n), do: Date.shift(d, year: n)
end
