defmodule SlipdockCLI.Ledger do
  @moduledoc false

  # The ledger (#1948): what shipped on a board tree since a time, a line per
  # card with who accepted it, its evidence, the should rules it missed and
  # where its time went, grouped by day. `ledger <board> [--since S]`.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP

  @commands ~w(ledger)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("ledger", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/ledger", since: since(o[:since])) |> out(o, &listing/1)
  end

  def run("ledger", _args, _o) do
    fail("usage: slipdock ledger <board> [--since DAYS|DATE|TIME]")
  end

  defp since(nil), do: nil
  defp since(s), do: to_string(s)

  @doc false
  def listing(%{"days" => []} = l) do
    IO.puts("Nothing shipped since #{l["since"]}.")
  end

  def listing(%{"days" => days} = l) do
    IO.puts("#{l["count"]} shipped since #{l["since"]} (#{l["timezone"]})")

    Enum.each(days, fn day ->
      IO.puts("\n## #{day["date"]}")
      Enum.each(day["items"], &(&1 |> lines() |> Enum.each(fn line -> IO.puts(line) end)))
    end)
  end

  @doc false
  def lines(i) do
    card = i["card"] || %{}

    head =
      "##{card["id"]} #{card["title"]}  [#{Enum.join(i["events"] || [], ", ")}]" <>
        profile(card["profile"]) <> waiting_for(i["waiting_for"]) <> subcards(i["subcards"])

    [head, "    " <> who(i)] ++
      evidence(i) ++ should(i) ++ links(i) ++ time(i["lead_time"])
  end

  # The card's profile (#1951), one word, when it has one.
  defp profile(p) when is_binary(p), do: "  profile:#{p}"
  defp profile(_), do: ""

  # Held for a person before merging (#1952): who it waits for.
  defp waiting_for(who) when is_binary(who), do: "  waiting for #{who}"
  defp waiting_for(_), do: ""

  defp subcards(%{"total" => t, "done" => d, "on_ledger" => n}),
    do: "  #{d}/#{t} subcards, #{n} here"

  defp subcards(_), do: ""

  defp who(i) do
    accepted =
      case i["accepted_by"] do
        %{"name" => name} -> "accepted by #{name}"
        _ -> "not verified"
      end

    case i["audit"] do
      %{"verdict" => v} -> accepted <> "; audit #{v}"
      _ -> accepted
    end
  end

  defp evidence(%{"evidence" => e}) when is_binary(e) and e != "", do: ["    evidence: " <> e]
  defp evidence(_), do: []

  defp should(%{"should_broken" => [_ | _] = rules}),
    do: ["    should missed: " <> Enum.map_join(rules, ", ", & &1["id"])]

  defp should(_), do: []

  defp links(i) do
    pr = if Enum.member?([nil, ""], i["pr"]), do: [], else: ["pr " <> i["pr"]]

    deploys =
      for d <- i["deploys"] || [],
          do: "deployed to #{d["environment"]} #{String.slice(d["sha"] || "", 0, 7)}"

    case pr ++ deploys do
      [] -> []
      parts -> ["    " <> Enum.join(parts, "; ")]
    end
  end

  defp time(%{"seconds" => s, "phases" => phases}) when is_integer(s) and map_size(phases) > 0 do
    top =
      phases
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(3)
      |> Enum.map_join(", ", fn {phase, secs} -> "#{phase} #{duration(secs)}" end)

    ["    lead time #{duration(s)}: #{top}"]
  end

  defp time(_), do: []

  @doc false
  def duration(s) when s < 60, do: "#{s}s"
  def duration(s) when s < 3600, do: "#{div(s, 60)}m"
  def duration(s) when s < 86_400, do: "#{div(s, 3600)}h#{rem(div(s, 60), 60)}m"
  def duration(s), do: "#{div(s, 86_400)}d#{rem(div(s, 3600), 24)}h"
end
