defmodule SlipdockWeb.RelativeTimeParityTest do
  # The browser rewrites relative times with `assets/js/relative_time.js`
  # (#2025), so its words have to be `Dates.relative/2`'s. Both are held to
  # the same table: this side here, the JavaScript in relative_time.test.js.
  use ExUnit.Case, async: true

  alias SlipdockWeb.Dates

  @external_resource "assets/js/relative_time_cases.json"
  @cases "assets/js/relative_time_cases.json"
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("cases")

  test "the shared table has the cases the ticker needs" do
    says = Enum.map(@cases, & &1["says"])

    for label <- ["just now", "18 min ago", "3 h ago", "yesterday", "2 days ago", "11 Nov 2025"] do
      assert label in says
    end
  end

  for %{"at" => at, "now" => now, "zone" => zone, "says" => says} <- @cases do
    test "#{at} seen at #{now} in #{zone} says #{says}" do
      {:ok, at, 0} = DateTime.from_iso8601(unquote(at))
      {:ok, now, 0} = DateTime.from_iso8601(unquote(now))

      assert Dates.relative(at, now: now, zone: unquote(zone)) == unquote(says)
    end
  end
end
