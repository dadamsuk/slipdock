defmodule SlipdockCLI.Health do
  @moduledoc false

  # The health monitor (W-2310): work it found stuck on a board tree, what
  # it fixed and what it flagged for a person. `health <board>` lists them
  # (`--run` looks the tree over first); `health settings <board>
  # [<detector> key=value...]` shows or changes the detectors.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP

  @commands ~w(health)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("health", ["settings", ref | rest], o) do
    case settings_args(rest) do
      {:ok, nil} ->
        HTTP.get("/boards/#{enc(ref)}/health") |> out(o, &settings(&1["detectors"]))

      {:ok, body} ->
        HTTP.patch("/boards/#{enc(ref)}/health/settings", body)
        |> out(o, &settings(&1["detectors"]))

      {:error, message} ->
        fail(message)
    end
  end

  def run("health", [ref], o) do
    request =
      if o[:run],
        do: HTTP.post("/boards/#{enc(ref)}/health", %{}),
        else: HTTP.get("/boards/#{enc(ref)}/health")

    out(request, o, &listing/1)
  end

  def run("health", _args, _o) do
    fail(
      "usage: slipdock health <board> [--run] | health settings <board> [<detector> key=value...]"
    )
  end

  @doc false
  # `<detector> key=value...` as the settings body, or nil to only show them.
  def settings_args([]), do: {:ok, nil}

  def settings_args([_detector]),
    do: {:error, "say what to change: <detector> enabled=false, max_attempts=3, …"}

  def settings_args([detector | pairs]) do
    Enum.reduce_while(pairs, {:ok, %{"detector" => detector}}, fn pair, {:ok, acc} ->
      case String.split(pair, "=", parts: 2) do
        [k, v] when k != "" and v != "" -> {:cont, {:ok, Map.put(acc, k, v)}}
        _ -> {:halt, {:error, "settings are key=value, like minutes=30 (got #{inspect(pair)})"}}
      end
    end)
  end

  @doc false
  def listing(r) do
    case r["incidents"] || [] do
      [] ->
        IO.puts("Nothing stuck.")

      incidents ->
        IO.puts("Stuck now (#{length(incidents)})")
        Enum.each(incidents, &IO.puts("  " <> line(&1)))
    end

    case r["recent"] || [] do
      [] ->
        :ok

      recent ->
        IO.puts("\nLately")
        recent |> Enum.take(10) |> Enum.each(&IO.puts("  " <> line(&1)))
    end

    IO.puts("\n" <> last_run(r["last_run"]))
  end

  defp last_run(nil), do: "The monitor hasn't run yet."
  defp last_run(at) when is_binary(at), do: "Monitor last ran #{String.slice(at, 0, 16)}."

  @doc false
  def line(i) do
    card = if c = i["card"], do: " ##{c["id"]}", else: ""
    tries = if (i["attempts"] || 0) > 0, do: " (#{i["attempts"]} tried)", else: ""
    "##{i["id"]} [#{i["status"]}] #{i["detector"]}#{card}: #{i["summary"]}#{tries}"
  end

  @doc false
  def settings(detectors) do
    if detectors == [], do: IO.puts("No detectors.")

    Enum.each(detectors, fn d ->
      onoff = if d["enabled"], do: "on ", else: "off"

      extra =
        (d["settings"] || %{})
        |> Map.delete("enabled")
        |> Enum.sort()
        |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

      IO.puts(String.trim_trailing("#{onoff}  #{String.pad_trailing(d["key"], 20)} #{extra}"))
    end)
  end
end
