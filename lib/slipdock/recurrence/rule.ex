defmodule Slipdock.Recurrence.Rule do
  @moduledoc """
  When a recurring card comes round again (W-1802). Pure: no database, no
  clock but the one passed in.

  Two kinds:

    * **fixed** — a subset of iCalendar's RRULE: `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`,
      `INTERVAL`, `BYDAY` (with an ordinal in a monthly or yearly rule: `1MO`,
      `-1FR`)
      and `BYMONTHDAY` (`-1` is the last day). "Every Monday" is
      `FREQ=WEEKLY;BYDAY=MO`.
    * **after done** — `AFTER=3D` (or `2W`, `1M`): that long after the last
      one was completed, whatever day that was.

  A yearly rule happens in its start's month (there is no `BYMONTH`).

  A rule counts from its `start` date, the series' first day: it is what an
  `INTERVAL` is counted from, and where a rule that names no day takes one
  from ("every week" from a Wednesday is every Wednesday; "every month" from
  the 12th is the 12th).

  Occurrences are dates in the series' timezone; `next/4` puts one at a time
  of day there and hands back the UTC instant (see `Slipdock.Timezones` for
  what happens in a DST gap or overlap).

  A day of the month past the end of a short month — the 31st in April, the
  29th of February in 2027 — falls on that month's last day rather than
  being skipped, so "monthly on the 31st" happens every month.

  `parse_phrase/1` reads the short forms quick add and the CLI take
  (`mon`, `weekday`, `2w`, `month last fri`, `3d after`); `summary/1` writes
  a rule back out in words.
  """

  @enforce_keys [:kind]
  defstruct kind: :fixed,
            freq: :weekly,
            interval: 1,
            by_day: [],
            by_month_day: [],
            start: nil

  @type weekday :: 1..7
  @type t :: %__MODULE__{
          kind: :fixed | :after_done,
          freq: :daily | :weekly | :monthly | :yearly,
          interval: pos_integer,
          by_day: [{integer | nil, weekday}],
          by_month_day: [integer],
          start: Date.t() | nil
        }

  @max_interval 99
  @freqs %{"DAILY" => :daily, "WEEKLY" => :weekly, "MONTHLY" => :monthly, "YEARLY" => :yearly}
  @days ~w(MO TU WE TH FR SA SU)
  @day_names ~w(Mon Tue Wed Thu Fri Sat Sun)
  @long_day_names ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  ## Reading and writing the stored form

  @doc """
  Reads a stored rule: an RRULE subset (`FREQ=WEEKLY;BYDAY=MO`) or `AFTER=3D`.
  `start` is the date the series counts from. A leading `RRULE:` is allowed.
  """
  def parse(text, start \\ nil)

  def parse(text, start) when is_binary(text) do
    text = text |> String.trim() |> String.upcase() |> String.replace_prefix("RRULE:", "")

    with {:ok, parts} <- split_parts(text),
         {:ok, rule} <- from_parts(parts) do
      {:ok, %{rule | start: start}}
    end
  end

  def parse(_, _), do: {:error, "a rule is text, like FREQ=WEEKLY;BYDAY=MO"}

  defp split_parts(""), do: {:error, "the rule is empty"}

  defp split_parts(text) do
    text
    |> String.split(";", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn part, {:ok, acc} ->
      case String.split(part, "=", parts: 2) do
        [k, v] when k != "" and v != "" ->
          if Map.has_key?(acc, k),
            do: {:halt, {:error, "#{k} is given twice"}},
            else: {:cont, {:ok, Map.put(acc, k, v)}}

        _ ->
          {:halt, {:error, "#{inspect(part)} isn't KEY=VALUE"}}
      end
    end)
  end

  defp from_parts(%{"AFTER" => after_done} = parts) do
    with :ok <- only(parts, ["AFTER"]),
         {:ok, n, freq} <- after_amount(after_done) do
      {:ok, %__MODULE__{kind: :after_done, freq: freq, interval: n}}
    end
  end

  defp from_parts(%{"FREQ" => freq} = parts) do
    with :ok <- only(parts, ~w(FREQ INTERVAL BYDAY BYMONTHDAY)),
         {:ok, freq} <- freq(freq),
         {:ok, interval} <- interval(parts["INTERVAL"]),
         {:ok, by_day} <- by_day(parts["BYDAY"], freq),
         {:ok, by_month_day} <- by_month_day(parts["BYMONTHDAY"], freq),
         :ok <- not_both(by_day, by_month_day, freq) do
      {:ok,
       %__MODULE__{
         kind: :fixed,
         freq: freq,
         interval: interval,
         by_day: by_day,
         by_month_day: by_month_day
       }}
    end
  end

  defp from_parts(_), do: {:error, "a rule needs FREQ (or AFTER for after-done)"}

  defp only(parts, allowed) do
    case Map.keys(parts) -- allowed do
      [] -> :ok
      extra -> {:error, "#{Enum.join(Enum.sort(extra), ", ")} isn't supported"}
    end
  end

  defp freq(f) do
    case Map.fetch(@freqs, f) do
      {:ok, freq} -> {:ok, freq}
      :error -> {:error, "FREQ must be DAILY, WEEKLY, MONTHLY or YEARLY"}
    end
  end

  defp interval(nil), do: {:ok, 1}

  defp interval(text) do
    case Integer.parse(text) do
      {n, ""} when n in 1..@max_interval -> {:ok, n}
      _ -> {:error, "INTERVAL must be a whole number from 1 to #{@max_interval}"}
    end
  end

  defp after_amount(text) do
    case Regex.run(~r/^(\d+)([DWM])$/, text) do
      [_, n, unit] ->
        case Integer.parse(n) do
          {n, ""} when n in 1..@max_interval ->
            {:ok, n, %{"D" => :daily, "W" => :weekly, "M" => :monthly}[unit]}

          _ ->
            {:error, "AFTER must be 1 to #{@max_interval} days, weeks or months"}
        end

      nil ->
        {:error, "AFTER is a number and D, W or M, like 3D"}
    end
  end

  defp by_day(nil, _freq), do: {:ok, []}

  defp by_day(text, freq) do
    text
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case Regex.run(~r/^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$/, item) do
        [_, "", day] ->
          {:cont, {:ok, acc ++ [{nil, weekday(day)}]}}

        [_, day] ->
          {:cont, {:ok, acc ++ [{nil, weekday(day)}]}}

        [_, ord, day] ->
          n = String.to_integer(String.replace_prefix(ord, "+", ""))

          cond do
            freq not in [:monthly, :yearly] ->
              {:halt,
               {:error, "BYDAY with a number (#{item}) only goes with FREQ=MONTHLY or YEARLY"}}

            n == 0 or abs(n) > 5 ->
              {:halt, {:error, "the number in #{item} must be 1 to 5, or -1 to -5"}}

            true ->
              {:cont, {:ok, acc ++ [{n, weekday(day)}]}}
          end

        nil ->
          {:halt, {:error, "#{inspect(item)} isn't a day (MO, TU, … or 1MO, -1FR)"}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "BYDAY is empty"}
      {:ok, days} -> {:ok, Enum.uniq(days)}
      error -> error
    end
  end

  defp weekday(code), do: Enum.find_index(@days, &(&1 == code)) + 1

  defp by_month_day(nil, _freq), do: {:ok, []}

  defp by_month_day(_text, freq) when freq not in [:monthly, :yearly],
    do: {:error, "BYMONTHDAY only goes with FREQ=MONTHLY or YEARLY"}

  defp by_month_day(text, _freq) do
    text
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case Integer.parse(item) do
        {n, ""} when n in 1..31 or n in -31..-1 -> {:cont, {:ok, acc ++ [n]}}
        _ -> {:halt, {:error, "BYMONTHDAY must be 1 to 31, or -1 (the last day) to -31"}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "BYMONTHDAY is empty"}
      {:ok, days} -> {:ok, Enum.uniq(days)}
      error -> error
    end
  end

  defp not_both([_ | _], [_ | _], _),
    do: {:error, "give BYDAY or BYMONTHDAY, not both"}

  defp not_both(_, _, _), do: :ok

  @doc "The stored form: `FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH`, or `AFTER=3D`."
  def to_string(%__MODULE__{kind: :after_done, freq: freq, interval: n}),
    do: "AFTER=#{n}#{%{daily: "D", weekly: "W", monthly: "M"}[freq]}"

  def to_string(%__MODULE__{} = rule) do
    [
      "FREQ=" <> (rule.freq |> Atom.to_string() |> String.upcase()),
      rule.interval > 1 && "INTERVAL=#{rule.interval}",
      rule.by_day != [] && "BYDAY=" <> Enum.map_join(rule.by_day, ",", &day_code/1),
      rule.by_month_day != [] && "BYMONTHDAY=" <> Enum.join(rule.by_month_day, ",")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(";")
  end

  defp day_code({nil, d}), do: Enum.at(@days, d - 1)
  defp day_code({n, d}), do: "#{n}#{Enum.at(@days, d - 1)}"

  ## The next one

  @doc """
  The first occurrence strictly after `after` (a date), or nil for an
  after-done rule, which has no dates of its own. Nothing before the rule's
  `start` counts.
  """
  def next_date(%__MODULE__{kind: :after_done}, _after), do: nil

  def next_date(%__MODULE__{} = rule, %Date{} = after_date) do
    rule = %{rule | start: rule.start || Date.add(after_date, 1)}
    from = Enum.max([Date.add(after_date, 1), rule.start], Date)

    # Every candidate inside one whole period of the rule is looked at, so a
    # yearly rule every 99 years is the longest search there is.
    limit = search_days(rule)

    Enum.find_value(0..limit, fn i ->
      date = Date.add(from, i)
      if matches?(rule, date), do: date
    end)
  end

  defp search_days(%{freq: :daily, interval: n}), do: n + 7
  defp search_days(%{freq: :weekly, interval: n}), do: 7 * n + 7
  defp search_days(%{freq: :monthly, interval: n}), do: 31 * n + 31
  defp search_days(%{freq: :yearly, interval: n}), do: 366 * n + 366

  @doc """
  The first `n` occurrences after `after` (a date): what the Repeat… dialog
  shows. Empty for an after-done rule.
  """
  def upcoming(rule, after_date, n) do
    after_date
    |> Stream.unfold(fn d ->
      case next_date(rule, d) do
        nil -> nil
        next -> {next, next}
      end
    end)
    |> Enum.take(n)
  end

  @doc """
  When the next one is due, as a UTC instant at `time` of day in `zone`.

  For a fixed rule, the first occurrence whose moment is after `after` (a
  `DateTime`). For an after-done rule, `after` is when the last one was
  completed: the day it was completed on, in `zone`, plus the rule's
  amount.
  """
  def next(rule, after_dt, zone, time \\ ~T[07:00:00])

  def next(%__MODULE__{kind: :after_done} = rule, %DateTime{} = done_at, zone, time) do
    rule
    |> after_done_date(Slipdock.Timezones.today(zone, done_at))
    |> Slipdock.Timezones.to_utc(time, zone)
  end

  def next(%__MODULE__{} = rule, %DateTime{} = after_dt, zone, time) do
    local = Slipdock.Timezones.to_local(after_dt, zone)
    # Today's occurrence still counts if its time hasn't come yet.
    candidate = next_date(rule, Date.add(DateTime.to_date(local), -1))

    candidate =
      if candidate &&
           DateTime.compare(Slipdock.Timezones.to_utc(candidate, time, zone), after_dt) != :gt,
         do: next_date(rule, candidate),
         else: candidate

    candidate && Slipdock.Timezones.to_utc(candidate, time, zone)
  end

  @doc "The date an after-done rule falls on, counted from the day it was done."
  def after_done_date(%__MODULE__{kind: :after_done, freq: :daily, interval: n}, done),
    do: Date.add(done, n)

  def after_done_date(%__MODULE__{kind: :after_done, freq: :weekly, interval: n}, done),
    do: Date.add(done, 7 * n)

  def after_done_date(%__MODULE__{kind: :after_done, freq: :monthly, interval: n}, done),
    do: Date.shift(done, month: n)

  @doc """
  Whether a series that ends `ends` (`"never"`, `{"on", date}` or
  `{"after", count}`) may still make an occurrence on `date`, having made
  `made` already.
  """
  def within_end?("never", _date, _made), do: true

  def within_end?({"on", %Date{} = until}, %Date{} = date, _made),
    do: Date.compare(date, until) != :gt

  def within_end?({"after", count}, _date, made) when is_integer(count), do: made < count
  def within_end?(_, _, _), do: true

  @doc "Whether `date` is one of the rule's occurrences."
  def matches?(%__MODULE__{kind: :after_done}, _date), do: false

  def matches?(%__MODULE__{start: start} = rule, %Date{} = date) do
    start = start || date

    Date.compare(date, start) != :lt and in_period?(rule, start, date) and
      on_day?(rule, start, date)
  end

  defp in_period?(%{freq: :daily, interval: n}, start, date),
    do: rem(Date.diff(date, start), n) == 0

  defp in_period?(%{freq: :weekly, interval: n}, start, date) do
    weeks = div(Date.diff(Date.beginning_of_week(date), Date.beginning_of_week(start)), 7)
    rem(weeks, n) == 0
  end

  defp in_period?(%{freq: :monthly, interval: n}, start, date),
    do: rem((date.year - start.year) * 12 + date.month - start.month, n) == 0

  defp in_period?(%{freq: :yearly, interval: n}, start, date),
    do: rem(date.year - start.year, n) == 0 and date.month == start.month

  # Daily: any day, or only the days named.
  defp on_day?(%{freq: :daily, by_day: []}, _start, _date), do: true

  defp on_day?(%{freq: :daily, by_day: days}, _start, date),
    do: Enum.any?(days, fn {_, d} -> d == Date.day_of_week(date) end)

  # Weekly: the days named, or the start's.
  defp on_day?(%{freq: :weekly, by_day: []}, start, date),
    do: Date.day_of_week(date) == Date.day_of_week(start)

  defp on_day?(%{freq: :weekly, by_day: days}, _start, date),
    do: Enum.any?(days, fn {_, d} -> d == Date.day_of_week(date) end)

  # Monthly and yearly (inside the start's month): the days of the month
  # named, the weekdays named (the nth, or every one), or the start's day.
  defp on_day?(%{by_month_day: [_ | _] = mdays}, _start, date),
    do: Enum.any?(mdays, &month_day?(date, &1))

  defp on_day?(%{by_day: [_ | _] = days}, _start, date),
    do: Enum.any?(days, &nth_weekday?(date, &1))

  defp on_day?(_rule, start, date), do: month_day?(date, start.day)

  defp month_day?(date, n) when n > 0, do: date.day == min(n, Date.days_in_month(date))
  defp month_day?(date, n), do: date.day == Date.days_in_month(date) + n + 1

  defp nth_weekday?(date, {ord, wd}) do
    Date.day_of_week(date) == wd and
      case ord do
        nil -> true
        n when n > 0 -> div(date.day - 1, 7) + 1 == n
        n -> div(Date.days_in_month(date) - date.day, 7) + 1 == -n
      end
  end

  ## Phrases

  @doc """
  Reads the short forms quick add and the CLI take, with or without a leading
  "every": `day`, `weekday`, `3d`, `week`, `2w`, `mon`, `mon,thu`, `2w mon thu`,
  `month`, `month 1`, `month last`, `month last fri`, `month first mon`,
  `3m 15`, `year`, and any of those in days, weeks or months followed by
  `after` (`3d after`, `2w after done`). An RRULE is read as one.
  """
  def parse_phrase(text, start \\ nil)

  def parse_phrase(text, start) when is_binary(text) do
    trimmed = String.trim(text)

    if String.match?(trimmed, ~r/^(RRULE:)?(FREQ|AFTER)=/i) do
      parse(trimmed, start)
    else
      words =
        trimmed
        |> String.downcase()
        |> String.replace(",", " ")
        |> String.split()
        |> drop_every()

      with {:ok, rule} <- phrase(words), do: {:ok, %{rule | start: start}}
    end
  end

  def parse_phrase(_, _), do: {:error, "say how often, like \"mon\" or \"month 1\""}

  defp drop_every(["every" | rest]), do: rest
  defp drop_every(words), do: words

  @phrase_help "say how often: day, weekday, mon, 2w, month 1, month last fri, year, or 3d after"

  defp phrase([]), do: {:error, @phrase_help}

  defp phrase(words) do
    {after?, words} =
      case Enum.reverse(words) do
        ["done", "after" | rest] -> {true, Enum.reverse(rest)}
        ["after" | rest] -> {true, Enum.reverse(rest)}
        _ -> {false, words}
      end

    if after?, do: after_phrase(words), else: fixed_phrase(words)
  end

  defp after_phrase(words) do
    case period(words) do
      {:ok, freq, n, []} when freq in [:daily, :weekly, :monthly] ->
        {:ok, %__MODULE__{kind: :after_done, freq: freq, interval: n}}

      _ ->
        {:error, "after-done is days, weeks or months: 3d after, 2w after, month after"}
    end
  end

  defp fixed_phrase(["weekday"]),
    do: {:ok, weekly(1, Enum.map(1..5, &{nil, &1}))}

  defp fixed_phrase(["weekdays"]), do: fixed_phrase(["weekday"])

  defp fixed_phrase(words) do
    case period(words) do
      {:ok, :daily, n, []} ->
        {:ok, %__MODULE__{kind: :fixed, freq: :daily, interval: n}}

      {:ok, :weekly, n, days} ->
        with {:ok, days} <- weekdays(days), do: {:ok, weekly(n, days)}

      {:ok, :monthly, n, rest} ->
        with {:ok, rule} <- month_day(rest), do: {:ok, %{rule | interval: n}}

      {:ok, :yearly, n, []} ->
        {:ok, %__MODULE__{kind: :fixed, freq: :yearly, interval: n}}

      {:none, words} ->
        # Bare weekdays: "mon", "mon thu".
        with {:ok, days} <- weekdays(words), do: {:ok, weekly(1, days)}

      _ ->
        {:error, @phrase_help}
    end
  end

  defp weekly(n, days),
    do: %__MODULE__{kind: :fixed, freq: :weekly, interval: n, by_day: days}

  # The period and how many of it: "day", "3d", "3 days", "week", "2w",
  # "fortnight", "month", "3m", "year", and the words after it.
  defp period([word | rest]) do
    cond do
      word in ~w(day days daily d) -> {:ok, :daily, 1, rest}
      word in ~w(week weeks weekly w) -> {:ok, :weekly, 1, rest}
      word == "fortnight" -> {:ok, :weekly, 2, rest}
      word in ~w(month months monthly m) -> {:ok, :monthly, 1, rest}
      word in ~w(year years yearly annually y) -> {:ok, :yearly, 1, rest}
      m = Regex.run(~r/^(\d+)(d|w|m|y)$/, word) -> counted(m, rest)
      Regex.match?(~r/^\d+$/, word) -> counted_word(word, rest)
      true -> {:none, [word | rest]}
    end
  end

  defp period([]), do: :error

  defp counted([_, n, unit], rest) do
    n = String.to_integer(n)
    freq = %{"d" => :daily, "w" => :weekly, "m" => :monthly, "y" => :yearly}[unit]
    if n in 1..@max_interval, do: {:ok, freq, n, rest}, else: :error
  end

  defp counted_word(n, [unit | rest]) do
    case period([unit | rest]) do
      {:ok, freq, 1, rest} ->
        n = String.to_integer(n)
        if n in 1..@max_interval, do: {:ok, freq, n, rest}, else: :error

      _ ->
        :error
    end
  end

  defp counted_word(_, []), do: :error

  defp weekdays([]), do: {:ok, []}

  defp weekdays(words) do
    Enum.reduce_while(words, {:ok, []}, fn w, {:ok, acc} ->
      case day_number(w) do
        nil -> {:halt, {:error, "#{inspect(w)} isn't a day of the week"}}
        d -> {:cont, {:ok, acc ++ [{nil, d}]}}
      end
    end)
    |> case do
      {:ok, days} -> {:ok, Enum.uniq(days)}
      error -> error
    end
  end

  defp day_number(word) do
    Enum.find_value(Enum.with_index(@long_day_names, 1), fn {name, i} ->
      name = String.downcase(name)
      if String.length(word) >= 2 and String.starts_with?(name, word), do: i
    end)
  end

  @ordinals %{
    "first" => 1,
    "1st" => 1,
    "second" => 2,
    "2nd" => 2,
    "third" => 3,
    "3rd" => 3,
    "fourth" => 4,
    "4th" => 4,
    "fifth" => 5,
    "5th" => 5,
    "last" => -1
  }

  # After "month": nothing (the start's day), a day number, "last", or an
  # ordinal and a weekday.
  defp month_day([]), do: {:ok, monthly([], [])}
  defp month_day(["last"]), do: {:ok, monthly([], [-1])}

  defp month_day([ord, day]) when is_map_key(@ordinals, ord) do
    case day_number(day) do
      nil -> {:error, "#{inspect(day)} isn't a day of the week"}
      d -> {:ok, monthly([{@ordinals[ord], d}], [])}
    end
  end

  defp month_day([n]) do
    case Integer.parse(String.replace(n, ~r/(st|nd|rd|th)$/, "")) do
      {d, ""} when d in 1..31 -> {:ok, monthly([], [d])}
      _ -> {:error, "a day of the month is 1 to 31, or last"}
    end
  end

  defp month_day(_), do: {:error, "month takes a day (month 1), last, or last fri"}

  defp monthly(by_day, mdays),
    do: %__MODULE__{kind: :fixed, freq: :monthly, by_day: by_day, by_month_day: mdays}

  ## In words

  @doc """
  The rule in words: "Every 2 weeks on Mon and Thu", "Every month on the
  last Friday", "3 days after the last one is done". A rule that takes its
  day from `start` says it when `start` is known.
  """
  def summary(%__MODULE__{kind: :after_done, freq: freq, interval: n}),
    do: "#{amount(n, unit_word(freq))} after the last one is done"

  def summary(%__MODULE__{freq: :weekly, interval: 1, by_day: days})
      when length(days) == 5 do
    if Enum.sort(Enum.map(days, &elem(&1, 1))) == [1, 2, 3, 4, 5],
      do: "Every weekday",
      else: "Every week" <> weekly_days(days)
  end

  def summary(%__MODULE__{} = rule), do: every(rule) <> on(rule)

  @doc "`summary/1` with the time and timezone: \"Every Mon, 07:00 Europe/London\"."
  def summary(rule, %Time{} = time, zone),
    do: "#{summary(rule)}, #{Calendar.strftime(time, "%H:%M")} #{zone}"

  defp every(%{freq: freq, interval: 1}), do: "Every " <> unit_word(freq)
  defp every(%{freq: freq, interval: n}), do: "Every #{n} #{unit_word(freq)}s"

  defp on(%{freq: :daily, by_day: []}), do: ""
  defp on(%{freq: :daily, by_day: days}), do: weekly_days(days)
  defp on(%{freq: :weekly, by_day: [], start: nil}), do: ""

  defp on(%{freq: :weekly, by_day: [], start: start}),
    do: " on " <> Enum.at(@day_names, Date.day_of_week(start) - 1)

  defp on(%{freq: :weekly, by_day: days}), do: weekly_days(days)

  defp on(%{freq: freq, by_month_day: [_ | _] = mdays} = rule),
    do: " on the " <> join(Enum.map(mdays, &month_day_word/1)) <> in_month(freq, rule)

  defp on(%{freq: freq, by_day: [_ | _] = days} = rule),
    do: " on the " <> join(Enum.map(days, &nth_word/1)) <> in_month(freq, rule)

  defp on(%{freq: :monthly, start: nil}), do: ""
  defp on(%{freq: :monthly, start: start}), do: " on the " <> month_day_word(start.day)
  defp on(%{freq: :yearly, start: nil}), do: ""
  defp on(%{freq: :yearly, start: start}), do: " on " <> Calendar.strftime(start, "%-d %b")

  defp in_month(:yearly, %{start: %Date{} = start}),
    do: " of " <> Calendar.strftime(start, "%B")

  defp in_month(_, _), do: ""

  defp weekly_days(days),
    do: " on " <> join(Enum.map(days, fn {_, d} -> Enum.at(@day_names, d - 1) end))

  defp month_day_word(-1), do: "last day"
  defp month_day_word(n) when n < 0, do: "#{ordinal(-n)} last day"
  defp month_day_word(n), do: ordinal(n)

  defp nth_word({nil, d}), do: "every " <> Enum.at(@long_day_names, d - 1)
  defp nth_word({-1, d}), do: "last " <> Enum.at(@long_day_names, d - 1)
  defp nth_word({n, d}) when n < 0, do: "#{ordinal(-n)} last " <> Enum.at(@long_day_names, d - 1)
  defp nth_word({n, d}), do: ordinal(n) <> " " <> Enum.at(@long_day_names, d - 1)

  defp ordinal(n) when rem(n, 100) in 11..13, do: "#{n}th"
  defp ordinal(n) when rem(n, 10) == 1, do: "#{n}st"
  defp ordinal(n) when rem(n, 10) == 2, do: "#{n}nd"
  defp ordinal(n) when rem(n, 10) == 3, do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"

  defp unit_word(:daily), do: "day"
  defp unit_word(:weekly), do: "week"
  defp unit_word(:monthly), do: "month"
  defp unit_word(:yearly), do: "year"

  defp amount(1, unit), do: "1 #{unit}"
  defp amount(n, unit), do: "#{n} #{unit}s"

  defp join([one]), do: one
  defp join(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)
end
