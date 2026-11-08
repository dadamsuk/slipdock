defmodule SlipdockCLI.Now do
  @moduledoc false

  # Right now (#2110), the CLI door of #2103's snapshot: what is happening on
  # a board's tree, read from `GET /api/boards/:board/now` (`NowJSON` on the
  # server). The runners and the jobs each holds with their steps, the cards
  # in progress with where they sit and what holds them, and the queue.
  # `--json` gives the server's JSON as it is.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(now)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("now", [ref], o), do: HTTP.get("/boards/#{enc(ref)}/now") |> out(o, &render/1)
  def run("now", _, _o), do: fail("usage: slipdock now <board> [--json]")

  @doc "The snapshot, as text: a counts line, then runners, in progress and queued."
  def render(s) do
    IO.puts(Render.bold("Right now") <> " · " <> counts(s["counts"] || %{}))
    section("RUNNERS", s["runners"] || [], "no runners", &runners/1)
    section("IN PROGRESS", s["in_progress"] || [], "nothing in progress", &in_progress/1)
    section("QUEUED", s["queued"] || [], "nothing queued", &queued/1)
  end

  @doc "`2 runners (1 online, 1 working) · 3 in progress · 1 queued`."
  def counts(c) do
    "#{plural(c["runners"] || 0, "runner")} " <>
      "(#{c["online"] || 0} online, #{c["working"] || 0} working) · " <>
      "#{c["in_progress"] || 0} in progress · #{c["queued"] || 0} queued"
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  defp section(title, [], empty, _render) do
    IO.puts("\n" <> Render.bold(title))
    IO.puts("  " <> Render.dim(empty))
  end

  defp section(title, rows, _empty, render) do
    IO.puts("\n" <> Render.bold(title))
    render.(rows)
  end

  # A runner a line, the jobs it holds under it with their steps.
  defp runners(runners) do
    Enum.each(runners, fn r ->
      state = if r["online"], do: Render.green("online"), else: Render.dim("offline")
      session = if r["session"], do: Render.dim(" · session"), else: ""
      idle = if (r["jobs"] || []) == [], do: Render.dim(" · idle"), else: ""
      IO.puts("  #{r["name"]} (#{r["pool"]}) #{state}#{session}#{idle}")
      Enum.each(r["jobs"] || [], &IO.puts("    " <> job_line(&1)))
    end)
  end

  @doc "A job: its id, kind and status, its card, its step and how long it has been at it."
  def job_line(j) do
    step = if blank?(j["step"]), do: Render.dim("no step yet"), else: j["step"]

    "job ##{j["id"]} #{j["kind"]} #{j["status"]}  ##{j["card_id"]} #{j["card"]}  — #{step}" <>
      ago(j["step_at"] || j["since"])
  end

  defp in_progress(cards) do
    rows =
      Enum.map(cards, fn c ->
        [
          "##{c["id"]} #{c["title"]}",
          where(c),
          to_string(c["state"] || ""),
          c["holds"] || Render.dim("-"),
          loop(c["loop"]),
          Render.span(c["age"])
        ]
      end)

    Render.table(["CARD", "WHERE", "STATE", "HOLDS", "RUNNER", "AGE"], rows)
  end

  @doc "Where a card in progress sits: its board and list, and the epic over a sub-board."
  def where(%{"parent" => %{"id" => id}} = c), do: "#{c["board"]} › #{c["list"]} (in ##{id})"
  def where(c), do: "#{c["board"]} › #{c["list"]}"

  defp loop(%{"runner" => runner} = l), do: "#{runner} #{l["kind"]}" |> String.trim()
  defp loop(_), do: Render.dim("-")

  defp queued(jobs) do
    rows =
      Enum.map(jobs, fn j ->
        [
          "##{j["id"]}",
          "#{j["pool"]}/#{j["kind"]}",
          "##{j["card_id"]} #{j["card"]}",
          j["held"] || Render.dim("waiting for a runner"),
          span_since(j["since"])
        ]
      end)

    Render.table(["JOB", "POOL/KIND", "CARD", "HELD", "QUEUED"], rows)
  end

  defp ago(iso) do
    case span_since(iso) do
      "" -> ""
      span -> " · " <> span
    end
  end

  # How long since an ISO time, in the one unit that reads best; "" when unknown.
  defp span_since(iso) do
    case DateTime.from_iso8601(to_string(iso)) do
      {:ok, at, _} -> Render.span(max(DateTime.diff(DateTime.utc_now(), at), 0))
      _ -> ""
    end
  end

  defp blank?(s), do: Enum.member?([nil, ""], s)
end
