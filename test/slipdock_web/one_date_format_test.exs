defmodule SlipdockWeb.OneDateFormatTest do
  @moduledoc """
  Every date written for a person goes through `SlipdockWeb.Dates` (#1719).
  A `Calendar.strftime` anywhere else in the web layer is a second format
  waiting to happen, unless it writes for a machine: the API, agent prompts
  and MCP resources, which keep ISO-ish stamps on purpose.
  """
  use ExUnit.Case, async: true

  @root "lib/slipdock_web"
  @allowed [
    # The formats themselves.
    "lib/slipdock_web/dates.ex",
    # Machine and agent text: ISO dates and UTC stamps an agent parses.
    "lib/slipdock_web/mcp/",
    "lib/slipdock_web/controllers/api/"
  ]

  defp stray(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> line =~ ~r/\bstrftime\(|\|>\s*Calendar\.strftime/ end)
  end

  test "no strftime outside SlipdockWeb.Dates and the machine formats" do
    hits =
      for path <- Path.wildcard(Path.join(@root, "**/*.{ex,heex}")),
          not Enum.any?(@allowed, &String.starts_with?(path, &1)),
          {line, n} <- stray(File.read!(path)),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == [],
           "Write dates with SlipdockWeb.Dates (W-1946 §Patterns, Dates), not strftime:\n" <>
             Enum.join(hits, "\n")
  end

  test "the scan finds a stray format" do
    assert [{_, 2}] = stray("x = 1\n{Calendar.strftime(at, \"%b %-d\")}\n")
    assert [{_, 1}] = stray("at |> Calendar.strftime(\"%H:%M\")")
    assert stray("Dates.short(at)") == []
  end
end
