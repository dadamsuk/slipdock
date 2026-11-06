defmodule SlipdockWeb.RelativeTimeHelpers do
  @moduledoc """
  The label a test should expect for a moment taken off the real clock
  (#1888). `SlipdockWeb.Dates.relative/2` counts days on the calendar, so
  "5 min ago" taken at 00:02 UTC reads "yesterday", and "3 h ago" does
  until 03:00. A test that subtracts from `DateTime.utc_now/0` and asserts
  "5 min ago" fails in that window.

  `rendered_around/1` reads the clock either side of the render, and
  `expected_labels/4` gives the labels those readings allow: `label` while
  `at` is still today, "yesterday" once it isn't, and both when midnight
  fell during the render.

      at = DateTime.add(DateTime.utc_now(), -5 * 60)
      {{:ok, view, _}, before, later} = rendered_around(fn -> live(conn, ~p"/users") end)
      assert Enum.any?(expected_labels(at, "5 min ago", before, later), &has_element?(view, "#x", &1))
  """

  @doc "Runs `fun`, returning `{result, utc_now_before, utc_now_after}`."
  def rendered_around(fun) when is_function(fun, 0) do
    before = DateTime.utc_now()
    result = fun.()
    {result, before, DateTime.utc_now()}
  end

  @doc """
  The labels a moment `at` (earlier today, a day at most ago) may read as,
  rendered between `before` and `later`: `label` (`"5 min ago"`) for a
  reading on `at`'s day, `"yesterday"` for one the day after.
  """
  def expected_labels(%DateTime{} = at, label, %DateTime{} = before, %DateTime{} = later) do
    [before, later]
    |> Enum.map(fn now -> label_at(at, label, now) end)
    |> Enum.uniq()
  end

  defp label_at(at, label, now) do
    if Date.compare(DateTime.to_date(at), DateTime.to_date(now)) == :eq,
      do: label,
      else: "yesterday"
  end
end
