defmodule Slipdock.Timezones do
  @moduledoc """
  People's own timezones: an IANA name on the user (`users.timezone`), and the
  arithmetic that turns "this date at 07:00 where I am" into a UTC instant.

  A person with no timezone yet is on `Etc/UTC`. The browser sets it on the
  first signed-in page that connects (see `SlipdockWeb.UserAuth`), and they
  can change it under Account. Recurring cards and snooze read it; the older
  `schedule` automation trigger stays in UTC.

  The database is the `tz` package's, compiled in, so nothing is fetched at
  runtime.
  """

  @default "Etc/UTC"

  # The canonical zones, for the Account picker. Links ("US/Eastern",
  # "Europe/Kiev") are still accepted by `valid?/1`: a browser may send one.
  @tab [:code.priv_dir(:tz), "tzdata*", "zone1970.tab"]
       |> Path.join()
       |> Path.wildcard()
       |> Enum.max(fn -> "" end)
  @external_resource @tab

  @zones (case File.read(@tab) do
            {:ok, body} ->
              body
              |> String.split("\n")
              |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
              |> Enum.map(&(&1 |> String.split("\t") |> Enum.at(2)))
              |> Enum.reject(&is_nil/1)

            {:error, _} ->
              []
          end)
         |> Enum.concat([@default])
         |> Enum.uniq()
         |> Enum.sort()

  @doc "The timezone of somebody who has not said: `Etc/UTC`."
  def default, do: @default

  @doc "Every canonical IANA zone name, sorted, for a picker."
  def all, do: @zones

  @doc "`all/0`, with `current` in it even when it is a link rather than a canonical name."
  def options(current) do
    if current in @zones, do: @zones, else: Enum.sort([current | @zones])
  end

  @doc "Whether `name` is a zone the database knows (canonical or a link)."
  def valid?(name) when is_binary(name) and name != "" do
    match?({:ok, _}, DateTime.now(name))
  end

  def valid?(_), do: false

  @doc "This person's timezone, or the default when they have none."
  def of(%{timezone: tz}) when is_binary(tz) and tz != "", do: tz
  def of(_), do: @default

  @doc """
  The UTC instant of `date` at `time` in `zone`.

  A wall-clock time that does not exist (the hour skipped when the clocks go
  forward) is taken as the moment just after the gap, and one that happens
  twice (the hour repeated when they go back) as the first of the two: "07:00
  every day" should never be skipped, and never happen twice.
  """
  def to_utc(%Date{} = date, %Time{} = time, zone) do
    case DateTime.new(date, time, zone) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
      {:error, reason} -> raise ArgumentError, "bad zone #{inspect(zone)}: #{inspect(reason)}"
    end
  end

  @doc "`utc` as a local date and time in `zone`."
  def to_local(%DateTime{} = utc, zone), do: DateTime.shift_zone!(utc, zone)

  @doc "Today's date in `zone`."
  def today(zone, now \\ DateTime.utc_now()), do: now |> to_local(zone) |> DateTime.to_date()
end
