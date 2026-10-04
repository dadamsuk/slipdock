defmodule Slipdock.TimeTracking do
  @moduledoc """
  Time spent on a card against its estimate.

  Both are stored as whole minutes. A card's `time_unit` — minutes, hours,
  days, weeks or months — is how it shows them and how a bare number typed
  into either is read, so changing the unit never changes the time recorded.
  Longer units are working time, as Jira counts it: a day is 8 hours, a week
  5 days, a month 4 weeks. That is what lets a timer, which measures the wall
  clock, add sensibly to an estimate given in days.

  Every way in — the card panel, the JSON API, the CLI — takes values through
  `parse/2`, which reads `90`, `1.5`, `90m`, `1.5h`, `2d`, `1w`, `1mo` and
  combinations like `1h 30m`.
  """

  @units [
    {"minutes", "Minutes", "m", 1},
    {"hours", "Hours", "h", 60},
    {"days", "Days", "d", 8 * 60},
    {"weeks", "Weeks", "w", 5 * 8 * 60},
    {"months", "Months", "mo", 4 * 5 * 8 * 60}
  ]

  @unit_keys Enum.map(@units, &elem(&1, 0))
  @default_unit "hours"

  @doc "The units as `{key, label}`, smallest first."
  def units, do: Enum.map(@units, fn {key, label, _, _} -> {key, label} end)

  def unit_keys, do: @unit_keys
  def default_unit, do: @default_unit

  @doc "Minutes in one of `unit`."
  def minutes_per(unit) do
    case List.keyfind(@units, unit, 0) do
      {_, _, _, n} -> n
      nil -> minutes_per(@default_unit)
    end
  end

  @doc "The short suffix for `unit` (`h` for hours)."
  def suffix(unit) do
    case List.keyfind(@units, unit, 0) do
      {_, _, s, _} -> s
      nil -> suffix(@default_unit)
    end
  end

  @doc """
  Reads a duration into whole minutes. A bare number is in `unit`; a number
  with a suffix (`m`, `h`, `d`, `w`, `mo`, or the unit's name) is in that
  unit, and several can be strung together (`1h 30m`). `nil` and `""` are
  `{:ok, nil}`, meaning cleared. Anything else is `:error`.
  """
  def parse(value, unit \\ @default_unit)
  def parse(nil, _unit), do: {:ok, nil}
  def parse(n, unit) when is_integer(n) or is_float(n), do: from_number(n, unit)

  def parse(text, unit) when is_binary(text) do
    case text |> String.trim() |> String.downcase() do
      "" ->
        {:ok, nil}

      text ->
        parts = Regex.scan(~r/(\d+(?:\.\d+)?|\.\d+)\s*([a-z]*)/, text)
        matched = Enum.map_join(parts, &hd/1) |> String.replace(~r/\s/, "")

        if parts != [] and matched == String.replace(text, ~r/[\s,]/, "") do
          Enum.reduce_while(parts, {:ok, 0}, fn [_, number, suffix], {:ok, acc} ->
            with {:ok, u} <- unit_for(suffix, unit),
                 {n, ""} <- Float.parse(leading_zero(number)) do
              {:cont, {:ok, acc + n * minutes_per(u)}}
            else
              _ -> {:halt, :error}
            end
          end)
          |> case do
            {:ok, minutes} -> {:ok, round(minutes)}
            :error -> :error
          end
        else
          :error
        end
    end
  end

  def parse(_, _), do: :error

  defp leading_zero("." <> _ = n), do: "0" <> n
  defp leading_zero(n), do: n

  defp from_number(n, _unit) when n < 0, do: :error
  defp from_number(n, unit), do: {:ok, round(n * minutes_per(unit))}

  defp unit_for("", unit), do: {:ok, unit}

  defp unit_for(suffix, _unit) do
    Enum.find_value(@units, :error, fn {key, _, short, _} ->
      singular = String.trim_trailing(key, "s")

      if suffix in [short, key, singular] or (short == "m" and suffix in ~w(min mins)) or
           (short == "h" and suffix in ~w(hr hrs)) or (short == "mo" and suffix == "mon"),
         do: {:ok, key}
    end)
  end

  @doc "`minutes` as a number of `unit`, to two places at most (`1.5`, `2`)."
  def in_unit(nil, _unit), do: nil

  def in_unit(minutes, unit) do
    value = Float.round(minutes / minutes_per(unit), 2)
    if value == trunc(value), do: trunc(value), else: value
  end

  @doc "`minutes` written in `unit` with its suffix — `1.5h`, `2d` — or nil."
  def format(nil, _unit), do: nil
  def format(minutes, unit), do: "#{in_unit(minutes, unit)}#{suffix(unit)}"

  @doc """
  Minutes on the card's running timer as of `now`: 0 when it isn't running.
  """
  def running(card, now \\ DateTime.utc_now())

  def running(%{timer_started_at: %DateTime{} = since}, now),
    do: max(div(DateTime.diff(now, since, :second) + 30, 60), 0)

  def running(_, _), do: 0

  @doc "Whether the card's timer is running."
  def running?(%{timer_started_at: %DateTime{}}), do: true
  def running?(_), do: false

  @doc "Time spent including whatever the running timer has counted so far."
  def spent(card, now \\ DateTime.utc_now()),
    do: (Map.get(card, :time_spent) || 0) + running(card, now)

  @doc """
  Spent as a percentage of the estimate, rounded — over 100 when the work has
  run past it. nil without an estimate.
  """
  def percent(card, now \\ DateTime.utc_now())

  def percent(%{time_estimate: est} = card, now) when is_integer(est) and est > 0,
    do: round(spent(card, now) * 100 / est)

  def percent(_, _), do: nil

  @doc """
  How the work stands against the estimate: `:under` below 80%, `:near` up to
  100%, `:over` beyond it, nil without an estimate.
  """
  def status(nil), do: nil
  def status(p) when p > 100, do: :over
  def status(p) when p >= 80, do: :near
  def status(_), do: :under

  @doc "Whether there is anything to show: an estimate, time spent, or a running timer."
  def tracked?(card) do
    (Map.get(card, :time_spent) || 0) > 0 or is_integer(Map.get(card, :time_estimate)) or
      running?(card)
  end

  @doc """
  Turns the time values a write carries into what the card stores:
  `"time_spent"` and `"time_estimate"` in any form `parse/2` reads, in the
  unit the write leaves the card in; `"log_time"` added to (or, negative,
  taken off) the time already spent. A value that can't be read is left for
  the changeset to reject.
  """
  def normalize_attrs(card, attrs) do
    unit =
      case Map.get(attrs, "time_unit") do
        u when u in @unit_keys -> u
        _ -> Map.get(card, :time_unit) || @default_unit
      end

    attrs
    |> convert("time_spent", unit)
    |> convert("time_estimate", unit)
    |> log(card, unit)
  end

  defp convert(attrs, key, unit) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        case parse(value, unit) do
          {:ok, minutes} -> Map.put(attrs, key, minutes)
          :error -> Map.put(attrs, key, "invalid")
        end

      :error ->
        attrs
    end
  end

  defp log(attrs, card, unit) do
    case Map.pop(attrs, "log_time") do
      {nil, attrs} ->
        attrs

      {value, attrs} ->
        {sign, value} = negative(value)
        base = Map.get(attrs, "time_spent") || Map.get(card, :time_spent) || 0

        case {parse(value, unit), base} do
          {{:ok, minutes}, base} when is_integer(base) and is_integer(minutes) ->
            Map.put(attrs, "time_spent", max(base + sign * minutes, 0))

          _ ->
            Map.put(attrs, "time_spent", "invalid")
        end
    end
  end

  defp negative(n) when is_number(n) and n < 0, do: {-1, -n}

  defp negative(text) when is_binary(text) do
    case String.trim(text) do
      "-" <> rest -> {-1, rest}
      "+" <> rest -> {1, rest}
      rest -> {1, rest}
    end
  end

  defp negative(value), do: {1, value}
end
