defmodule Slipdock.Calendar do
  @moduledoc """
  The calendar view: a month (or a single week) of days, each holding the
  cards that fall on it. A card sits on its due date, or on its start date
  when it has no due date; with `place: "start"` in the config it is the
  other way round. Cards with neither date are listed separately.
  Filtering and sorting come from `Slipdock.Swimlanes`.

  Everything here is pure; persistence lives in `Slipdock.Boards`.
  """

  alias Slipdock.Boards.Card
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config

  @units [{"month", "Month"}, {"week", "Week"}]

  @doc "The spans a calendar offers, as `{key, label}`."
  def units, do: @units

  @doc "The calendar span for a config: `\"week\"` or (for anything else) `\"month\"`."
  def unit(%Config{unit: "week"}), do: "week"
  def unit(_), do: "month"

  @doc "The date a calendar places a card on: `\"due\"` (default) or `\"start\"`."
  def place(%Config{place: "start"}), do: "start"
  def place(_), do: "due"

  @doc "The choices for `place/1`, as `{key, label}`."
  def places, do: Config.places()

  @doc """
  Builds the calendar for `board`. Returns a map with:

    * `:weeks` – rows of seven days, each `%{date, key, in_period?, today?, cards}`
    * `:weekdays` – the seven column labels
    * `:undated` – filtered cards without any date
    * `:milestones` – the tree's milestones by day key (ISO date)
    * `:elsewhere` – dated cards outside the shown range
    * `:title`, `:prev`, `:next`, `:unit`, `:shown`, `:hidden`
  """
  def build(board, %Config{} = config, today \\ Date.utc_today()) do
    unit = unit(config)
    place = place(config)
    on_day = if place == "start", do: &Card.starts_on/1, else: &Card.ends_on/1
    anchor = Config.anchor(config, today)
    {from, to, title, prev, next} = range(anchor, unit)

    col_pos = Map.new(board.columns, &{&1.id, &1.position})
    all = Enum.flat_map(board.columns, &(&1.cards ++ Swimlanes.placed_pages(&1)))

    cards =
      all
      |> Enum.filter(&Swimlanes.matches?(&1, config, today))
      |> Swimlanes.sort(config, col_pos)

    {dated, undated} = Enum.split_with(cards, on_day)
    by_day = Enum.group_by(dated, on_day)

    days =
      for date <- Date.range(from, to) do
        %{
          date: date,
          key: Date.to_iso8601(date),
          in_period?: unit == "week" or date.month == anchor.month,
          today?: date == today,
          past?: Date.compare(date, today) == :lt,
          cards: Map.get(by_day, date, [])
        }
      end

    shown_ids = days |> Enum.flat_map(& &1.cards) |> MapSet.new(& &1.id)

    milestones =
      (Map.get(board, :milestones) || [])
      |> Enum.filter(&Slipdock.Dates.within?(&1.date, from, to))
      |> Enum.group_by(&Date.to_iso8601(&1.date))

    %{
      milestones: milestones,
      weeks: Enum.chunk_every(days, 7),
      weekdays: Enum.map(Enum.take(days, 7), &Calendar.strftime(&1.date, "%a")),
      undated: undated,
      elsewhere: Enum.count(dated, &(not MapSet.member?(shown_ids, &1.id))),
      title: title,
      prev: Date.to_iso8601(prev),
      next: Date.to_iso8601(next),
      unit: unit,
      place: place,
      shown: length(cards),
      hidden: length(all) - length(cards)
    }
  end

  @doc """
  The attribute changes that put `card` on `date`. Placing by due date (the
  default): a card keeps its duration when it has both dates, a card with
  one date moves that date, and an undated card gets `date` as its due date.
  Placing by start date mirrors that: a card with both dates keeps its
  duration, a card with only a due date gains a start date (its due date
  moves along if it would come first), and an undated card gets `date` as
  its start date.
  """
  def move_attrs(card, date, place \\ "due")

  def move_attrs(%Card{start_date: %Date{} = s, due_date: %Date{} = d}, %Date{} = date, "due") do
    delta = Date.diff(date, d)
    %{"start_date" => Date.add(s, delta), "due_date" => date}
  end

  def move_attrs(%Card{start_date: %Date{}, due_date: nil}, %Date{} = date, "due"),
    do: %{"start_date" => date}

  def move_attrs(%Card{}, %Date{} = date, "due"), do: %{"due_date" => date}

  def move_attrs(%Card{start_date: %Date{} = s, due_date: %Date{} = d}, %Date{} = date, "start") do
    delta = Date.diff(date, s)
    %{"start_date" => date, "due_date" => Date.add(d, delta)}
  end

  def move_attrs(%Card{start_date: nil, due_date: %Date{} = d}, %Date{} = date, "start") do
    if Date.compare(date, d) == :gt,
      do: %{"start_date" => date, "due_date" => date},
      else: %{"start_date" => date}
  end

  def move_attrs(%Card{}, %Date{} = date, "start"), do: %{"start_date" => date}

  defp range(anchor, "week") do
    from = Date.beginning_of_week(anchor)
    to = Date.add(from, 6)

    title =
      cond do
        from.month == to.month ->
          "#{from.day} – #{Calendar.strftime(to, "%-d %B %Y")}"

        from.year == to.year ->
          "#{Calendar.strftime(from, "%-d %b")} – #{Calendar.strftime(to, "%-d %b %Y")}"

        true ->
          "#{Calendar.strftime(from, "%-d %b %Y")} – #{Calendar.strftime(to, "%-d %b %Y")}"
      end

    {from, to, title, Date.add(from, -7), Date.add(from, 7)}
  end

  defp range(anchor, "month") do
    first = Date.beginning_of_month(anchor)
    from = Date.beginning_of_week(first)
    to = first |> Date.end_of_month() |> Date.end_of_week()

    {from, to, Calendar.strftime(first, "%B %Y"), Date.shift(first, month: -1),
     Date.shift(first, month: 1)}
  end
end
