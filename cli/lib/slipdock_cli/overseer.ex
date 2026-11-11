defmodule SlipdockCLI.Overseer do
  @moduledoc false

  # The overseer (#2068): `overseer <board>` shows where it stands (on or
  # off, its pacing bounds, the next pass, the last digest and the open
  # conditions); `--on`/`--off`, `--pool`, `--min-minutes`, `--max-minutes`,
  # `--idle-minutes` and `--email`/`--no-email` change it.

  import SlipdockCLI.Util

  alias SlipdockCLI.{HTTP, Render}

  @commands ~w(overseer)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("overseer", [ref], o) do
    case changes(o) do
      {:error, message} ->
        fail(message)

      changes when changes == %{} ->
        HTTP.get("/boards/#{enc(ref)}/overseer") |> out(o, &render/1)

      changes ->
        HTTP.patch("/boards/#{enc(ref)}/overseer", changes) |> out(o, &render/1)
    end
  end

  def run("overseer", _args, _o),
    do:
      fail(
        "usage: slipdock overseer <board> [--on | --off] [--pool P] [--min-minutes N] " <>
          "[--max-minutes N] [--idle-minutes N] [--email | --no-email] [--digest-at HH:MM]"
      )

  @doc false
  def changes(o) do
    if o[:on] && o[:off] do
      {:error, "--on or --off, not both"}
    else
      compact(%{
        "enabled" => if(o[:on], do: true, else: if(o[:off], do: false)),
        "pool" => o[:pool],
        "min_minutes" => o[:min_minutes],
        "max_minutes" => o[:max_minutes],
        "idle_minutes" => o[:idle_minutes],
        "email" => o[:email],
        # The morning digest of Housekeeping's work (#2781).
        "digest_at" => o[:digest_at]
      })
    end
  end

  @doc false
  def render(%{"overseer" => s}) do
    heading(s)

    if s["enabled"],
      do: IO.puts("  next pass: #{s["next_run_at"] || "now"}" <> job(s["open_job"]))

    digest(s["last_digest"])
    conditions(s["conditions"] || [])
    cleared(s["cleared_last_day"] || [])
  end

  defp heading(s) do
    IO.puts(
      Render.bold("Overseer: #{on_off(s["enabled"])}") <>
        Render.dim(
          "  pool #{s["pool"]} · every #{s["min_minutes"]}–#{s["max_minutes"]} min · " <>
            "idle after #{s["idle_minutes"]} min · email #{on_off(s["email"])}" <>
            if(s["digest_at"], do: " · Housekeeping digest at #{s["digest_at"]}", else: "")
        )
    )
  end

  defp on_off(true), do: "on"
  defp on_off(_), do: "off"

  defp digest(%{"body" => body, "health" => health, "at" => at}) do
    IO.puts("  last digest (#{health}, #{at}):")
    body |> String.split("\n") |> Enum.each(&IO.puts("    " <> &1))
  end

  defp digest(_), do: :ok

  defp conditions([]), do: IO.puts(Render.dim("  nothing open"))

  defp conditions(conditions) do
    IO.puts(Render.bold("Open (#{length(conditions)})"))

    Enum.each(conditions, fn c ->
      IO.puts("  [#{c["check"]}] ##{c["card_id"]} #{c["title"]}  " <> Render.dim(c["opened_at"]))
      IO.puts("      #{c["why"]}")
      IO.puts("      What to do: #{c["todo"]}")
    end)
  end

  defp cleared([]), do: :ok
  defp cleared(cleared), do: IO.puts(Render.dim("  cleared in the last day: #{length(cleared)}"))

  defp job(%{"id" => id, "status" => status}), do: "  (pass #{id} #{status})"
  defp job(_), do: ""
end
