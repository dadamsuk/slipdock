defmodule SlipdockWeb.Dates do
  @moduledoc """
  The one way the app writes a date for a person to read (#1719, W-1946
  §Patterns "Dates").

  Day before month, month abbreviated, no leading zero, and the year only
  when it isn't this one:

  | function     | reads as                       |
  |--------------|--------------------------------|
  | `short/2`    | `18 Nov` (`18 Nov 2025`)       |
  | `long/2`     | `18 Nov 2026`                  |
  | `weekday/2`  | `Tue 18 Nov`                   |
  | `full/2`     | `Tuesday 18 November 2026`     |
  | `datetime/2` | `18 Nov, 11:43`                |
  | `time/2`     | `11:43`                        |
  | `exact/2`    | `18 Nov 2026, 11:43 GMT`       |
  | `range/3`    | `31 Oct → 5 Nov`               |
  | `relative/2` | `5 min ago`, `yesterday`, …    |

  Every function takes a `Date`, a `DateTime` or a `NaiveDateTime` (taken as
  UTC), and `nil`, which reads as `""`. A time of day is shown in the
  viewer's timezone: the `:zone` option, or else the one the current process
  was given with `put_zone/1` (`SlipdockWeb.UserAuth` does that for every
  signed-in page), or else UTC. A bare `Date` is a calendar day and is never
  shifted.

  `:today` and `:now` stand in for the clock, for tests.

  Machine formats (ISO 8601 in APIs, exports and agent prompts) are not this
  module's business: they use `Date.to_iso8601/1` and friends.
  """

  @zone_key {__MODULE__, :zone}
  @utc "Etc/UTC"

  @type value :: Date.t() | DateTime.t() | NaiveDateTime.t() | nil

  ## The viewer's timezone ---------------------------------------------------

  @doc "Sets the timezone this process writes times in (an IANA name); `nil` means UTC."
  def put_zone(zone) when is_binary(zone) and zone != "", do: Process.put(@zone_key, zone)
  def put_zone(_), do: Process.delete(@zone_key)

  @doc "The timezone this process writes times in."
  def zone, do: Process.get(@zone_key, @utc)

  ## Formats -----------------------------------------------------------------

  @doc "`18 Nov`, or `18 Nov 2025` when it isn't this year."
  def short(value, opts \\ [])
  def short(nil, _opts), do: ""

  def short(value, opts) do
    d = local_date(value, opts)
    if d.year == today(opts).year, do: day_month(d), else: day_month(d) <> " #{d.year}"
  end

  @doc "`18 Nov 2026`: always with the year."
  def long(value, opts \\ [])
  def long(nil, _opts), do: ""
  def long(value, opts), do: value |> local_date(opts) |> then(&"#{day_month(&1)} #{&1.year}")

  @doc "`Tue 18 Nov`, with the year when it isn't this one."
  def weekday(value, opts \\ [])
  def weekday(nil, _opts), do: ""

  def weekday(value, opts) do
    d = local_date(value, opts)
    Calendar.strftime(d, "%a ") <> short(d, opts)
  end

  @doc "`Tue`: the day of the week alone, for a date in the coming week."
  def day_name(value, opts \\ [])
  def day_name(nil, _opts), do: ""
  def day_name(value, opts), do: value |> local_date(opts) |> Calendar.strftime("%a")

  @doc "`Tuesday 18 November 2026`: for a `title`, where there is room."
  def full(value, opts \\ [])
  def full(nil, _opts), do: ""
  def full(value, opts), do: value |> local_date(opts) |> Calendar.strftime("%A %-d %B %Y")

  @doc "`18 Nov, 11:43`, with the year when it isn't this one; a bare date is `short/2`."
  def datetime(value, opts \\ [])
  def datetime(nil, _opts), do: ""
  def datetime(%Date{} = d, opts), do: short(d, opts)

  def datetime(value, opts) do
    local = local(value, opts)
    short(DateTime.to_date(local), opts) <> ", " <> clock(local)
  end

  @doc "`11:43`, in the viewer's timezone. A `Time` is written as it is."
  def time(value, opts \\ [])
  def time(nil, _opts), do: ""
  def time(%Time{} = t, _opts), do: Calendar.strftime(t, "%H:%M")
  def time(value, opts), do: value |> local(opts) |> clock()

  @doc """
  The whole moment, for a `title`: `18 Nov 2026, 11:43 GMT`. A bare date is
  `full/2`.
  """
  def exact(value, opts \\ [])
  def exact(nil, _opts), do: ""
  def exact(%Date{} = d, opts), do: full(d, opts)

  def exact(value, opts) do
    local = local(value, opts)
    "#{long(DateTime.to_date(local), opts)}, #{clock(local)} #{local.zone_abbr}"
  end

  @doc "`31 Oct → 5 Nov`, each end with its year when it isn't this one."
  def range(from, to, opts \\ []), do: short(from, opts) <> " → " <> short(to, opts)

  @doc """
  How long ago (or how far ahead) a moment is, as people say it:

  - `just now` under a minute; `5 min ago`; `3 h ago` earlier the same day
  - `yesterday`, then `3 days ago` up to a week
  - then the date, as `short/2`

  and the same ahead: `in 5 min`, `in 3 h`, `tomorrow`, `in 3 days`. Days
  are counted on the viewer's calendar, so 23:50 seen at 00:10 is
  `yesterday`'s, not `20 min ago`. Pair it with `exact/2` in a `title`
  (`SlipdockWeb.SlipdockComponents.timestamp/1` does).
  """
  def relative(value, opts \\ [])
  def relative(nil, _opts), do: ""
  def relative(%Date{} = d, opts), do: relative_day(d, today(opts), opts)

  def relative(value, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    at = local(value, opts)
    seconds = DateTime.diff(now, at)
    days = Date.diff(DateTime.to_date(at), DateTime.to_date(local(now, opts)))

    cond do
      days == 0 and seconds >= 0 and seconds < 60 -> "just now"
      days == 0 and seconds >= 0 and seconds < 3600 -> "#{div(seconds, 60)} min ago"
      days == 0 and seconds >= 0 -> "#{div(seconds, 3600)} h ago"
      days == 0 and seconds > -3600 -> "in #{max(div(-seconds, 60), 1)} min"
      days == 0 -> "in #{div(-seconds, 3600)} h"
      true -> relative_day(DateTime.to_date(at), DateTime.to_date(local(now, opts)), opts)
    end
  end

  defp relative_day(date, today, opts) do
    case Date.diff(date, today) do
      0 -> "today"
      -1 -> "yesterday"
      1 -> "tomorrow"
      n when n < 0 and n > -7 -> "#{-n} days ago"
      n when n > 0 and n < 7 -> "in #{n} days"
      _ -> short(date, Keyword.put(opts, :today, today))
    end
  end

  ## Helpers -----------------------------------------------------------------

  defp day_month(d), do: Calendar.strftime(d, "%-d %b")
  defp clock(dt), do: Calendar.strftime(dt, "%H:%M")

  defp today(opts) do
    Keyword.get_lazy(opts, :today, fn ->
      opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> local(opts) |> DateTime.to_date()
    end)
  end

  defp local_date(%Date{} = d, _opts), do: d
  defp local_date(value, opts), do: value |> local(opts) |> DateTime.to_date()

  defp local(%NaiveDateTime{} = n, opts), do: n |> DateTime.from_naive!(@utc) |> local(opts)

  defp local(%DateTime{} = dt, opts) do
    zone = Keyword.get_lazy(opts, :zone, &zone/0)

    case DateTime.shift_zone(dt, zone) do
      {:ok, shifted} -> shifted
      {:error, _} -> DateTime.shift_zone!(dt, @utc)
    end
  end
end
