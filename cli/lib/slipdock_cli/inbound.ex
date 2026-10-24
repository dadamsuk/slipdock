defmodule SlipdockCLI.Inbound do
  @moduledoc false

  # Inbound email (#1242, W-1933): `inbound log` lists your last 50 messages
  # to the server's inbound addresses and what came of each, which is where
  # "I emailed it and nothing happened" gets its answer.

  import SlipdockCLI.Util

  alias SlipdockCLI.{HTTP, Render}

  @commands ~w(inbound)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("inbound", ["log"], o), do: HTTP.get("/inbound/log") |> out(o, &listing/1)

  def run("inbound", _args, _o), do: fail("usage: slipdock inbound log [--json]")

  @doc false
  def listing(%{"inbound" => []} = r) do
    IO.puts("No inbound mail yet. Mail you send to an address at #{r["domain"]} shows here.")
  end

  def listing(%{"inbound" => entries}) do
    Render.table(
      ["WHEN", "KIND", "OUTCOME", "SUBJECT", "WHY / WHAT IT MADE"],
      Enum.map(entries, fn e ->
        [
          e["at"] |> to_string() |> String.slice(0, 16) |> String.replace("T", " "),
          to_string(e["kind"]),
          outcome(e["outcome"]),
          e["subject"] |> Kernel.||("(no subject)") |> String.slice(0, 50),
          e["reason"] || e["link"] || ""
        ]
      end)
    )
  end

  defp outcome("accepted"), do: "accepted"
  defp outcome("rejected"), do: "bounced"
  defp outcome("dropped"), do: "ignored"
  defp outcome(other), do: to_string(other)
end
