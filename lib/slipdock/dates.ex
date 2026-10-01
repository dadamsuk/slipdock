defmodule Slipdock.Dates do
  @moduledoc """
  Date buckets at the precisions a card can be scheduled at: day, week,
  month, quarter, half-year and year. A bucket is identified by its first
  day; `bucket_start/2` and `bucket_end/2` snap a date to the bucket that
  contains it, `shift/3` moves a date by whole buckets, and `label/2` names
  a bucket the way a roadmap would ("Q1 2027", "H2 2027", "Mar 2027").
  """

  @precisions [
    {"day", "Day"},
    {"week", "Week"},
    {"month", "Month"},
    {"quarter", "Quarter"},
    {"half", "Half-year"},
    {"year", "Year"}
  ]

  @doc "The precisions as `{key, label}`."
  def precisions, do: @precisions
  def precision_keys, do: Enum.map(@precisions, &elem(&1, 0))

  def precision_label(key) do
    case List.keyfind(@precisions, key, 0) do
      {_, label} -> label
      nil -> key
    end
  end

  @doc "The first day of the bucket containing `date`."
  def bucket_start(%Date{} = d, "day"), do: d
  def bucket_start(%Date{} = d, "week"), do: Date.beginning_of_week(d)
  def bucket_start(%Date{} = d, "month"), do: Date.beginning_of_month(d)
  def bucket_start(%Date{} = d, "quarter"), do: Date.new!(d.year, div(d.month - 1, 3) * 3 + 1, 1)

  def bucket_start(%Date{} = d, "half"),
    do: Date.new!(d.year, if(d.month <= 6, do: 1, else: 7), 1)

  def bucket_start(%Date{} = d, "year"), do: Date.new!(d.year, 1, 1)
  def bucket_start(nil, _), do: nil

  @doc "The last day of the bucket containing `date`."
  def bucket_end(%Date{} = d, "day"), do: d
  def bucket_end(%Date{} = d, unit), do: d |> bucket_start(unit) |> shift(unit, 1) |> Date.add(-1)
  def bucket_end(nil, _), do: nil

  @doc "`date` moved by `n` buckets (negative to go back)."
  def shift(%Date{} = d, "day", n), do: Date.shift(d, day: n)
  def shift(%Date{} = d, "week", n), do: Date.shift(d, week: n)
  def shift(%Date{} = d, "month", n), do: Date.shift(d, month: n)
  def shift(%Date{} = d, "quarter", n), do: Date.shift(d, month: 3 * n)
  def shift(%Date{} = d, "half", n), do: Date.shift(d, month: 6 * n)
  def shift(%Date{} = d, "year", n), do: Date.shift(d, year: n)

  @doc "Roughly how many days a bucket spans, for turning a drag in days into buckets."
  def approx_days("day"), do: 1
  def approx_days("week"), do: 7
  def approx_days("month"), do: 30
  def approx_days("quarter"), do: 91
  def approx_days("half"), do: 182
  def approx_days("year"), do: 365

  @doc "A short name for the bucket containing `date`."
  def label(%Date{} = d, "day"), do: Calendar.strftime(d, "%-d %b %Y")

  def label(%Date{} = d, "week") do
    start = bucket_start(d, "week")
    "w/c #{Calendar.strftime(start, "%-d %b %Y")}"
  end

  def label(%Date{} = d, "month"), do: Calendar.strftime(d, "%b %Y")
  def label(%Date{} = d, "quarter"), do: "Q#{div(d.month - 1, 3) + 1} #{d.year}"
  def label(%Date{} = d, "half"), do: "H#{if d.month <= 6, do: 1, else: 2} #{d.year}"
  def label(%Date{} = d, "year"), do: Integer.to_string(d.year)
  def label(nil, _), do: nil

  @doc """
  A name for the range `from`–`to`: the bucket's own name when the range is
  exactly one bucket at `unit`, else the two dates.
  """
  def range_label(%Date{} = from, %Date{} = to, unit) when unit != "day" do
    if bucket_start(from, unit) == from and bucket_end(from, unit) == to,
      do: label(from, unit),
      else: "#{Calendar.strftime(from, "%-d %b %Y")} – #{Calendar.strftime(to, "%-d %b %Y")}"
  end

  def range_label(%Date{} = from, %Date{} = to, _unit) when from == to,
    do: Calendar.strftime(from, "%-d %b %Y")

  def range_label(%Date{} = from, %Date{} = to, _unit),
    do: "#{Calendar.strftime(from, "%-d %b %Y")} – #{Calendar.strftime(to, "%-d %b %Y")}"

  def range_label(_, _, _), do: nil

  @doc "Whether `date` falls inside the range (either end may be nil, meaning open)."
  def within?(%Date{} = date, from, to) do
    (is_nil(from) or Date.compare(date, from) != :lt) and
      (is_nil(to) or Date.compare(date, to) != :gt)
  end

  def within?(nil, _, _), do: false
end
