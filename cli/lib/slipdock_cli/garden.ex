defmodule SlipdockCLI.Garden do
  @moduledoc false

  # The board gardener (W-1807): tidy-up suggestions a person approves or
  # dismisses. `garden <board>` lists the open ones (`--run` looks the board
  # over first); `garden apply|dismiss|undo <id>...` decides them; `garden
  # settings <board> [<check> key=value...]` shows or changes the checks.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP

  @commands ~w(garden)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("garden", [verb | ids], o) when verb in ~w(apply dismiss undo) do
    ids =
      case suggestion_ids(ids) do
        {:ok, ids} -> ids
        {:error, message} -> fail(message)
      end

    body =
      if verb == "apply", do: compact(%{"keep" => o[:keep], "choice" => o[:choice]}), else: %{}

    Enum.each(ids, fn id ->
      HTTP.post("/garden/suggestions/#{id}/#{verb}", body)
      |> out(o, fn r -> IO.puts("#{past(verb)} " <> line(r["suggestion"])) end)
    end)
  end

  def run("garden", ["settings", ref | rest], o) do
    case settings_args(rest) do
      {:ok, nil} ->
        HTTP.get("/boards/#{enc(ref)}/garden") |> out(o, &settings(&1["checks"]))

      {:ok, body} ->
        HTTP.patch("/boards/#{enc(ref)}/garden/settings", body) |> out(o, &settings(&1["checks"]))

      {:error, message} ->
        fail(message)
    end
  end

  def run("garden", [ref], o) do
    request =
      if o[:run],
        do: HTTP.post("/boards/#{enc(ref)}/garden", compact(%{"check" => o[:check]})),
        else:
          HTTP.get("/boards/#{enc(ref)}/garden", compact(%{check: o[:check]}) |> Enum.to_list())

    out(request, o, &listing/1)
  end

  def run("garden", _args, _o) do
    fail(
      "usage: slipdock garden <board> [--run] [--check K] | garden apply|dismiss|undo <id>... " <>
        "[--keep CARD] [--choice NAME] | garden settings <board> [<check> key=value...]"
    )
  end

  @doc false
  # Suggestion ids, `#12` or `12`.
  def suggestion_ids([]),
    do: {:error, "which suggestions? Give their ids, from slipdock garden <board>"}

  def suggestion_ids(args) do
    ids = Enum.map(args, &String.trim_leading(&1, "#"))

    if Enum.all?(ids, &String.match?(&1, ~r/^\d+$/)),
      do: {:ok, ids},
      else: {:error, "suggestion ids are numbers, like 12"}
  end

  @doc false
  # `<check> key=value...` as the settings body, or nil to only show them.
  def settings_args([]), do: {:ok, nil}

  def settings_args([_check]),
    do: {:error, "say what to change: <check> enabled=false, days=30, …"}

  def settings_args([check | pairs]) do
    Enum.reduce_while(pairs, {:ok, %{"check" => check}}, fn pair, {:ok, acc} ->
      case String.split(pair, "=", parts: 2) do
        [k, v] when k != "" and v != "" -> {:cont, {:ok, Map.put(acc, k, v)}}
        _ -> {:halt, {:error, "settings are key=value, like days=30 (got #{inspect(pair)})"}}
      end
    end)
  end

  defp past("apply"), do: "applied"
  defp past("dismiss"), do: "dismissed"
  defp past("undo"), do: "undid"

  @doc false
  def listing(%{"suggestions" => []} = r) do
    IO.puts("Nothing to tidy." <> last_run(r["last_run"]))
  end

  def listing(%{"suggestions" => suggestions} = r) do
    suggestions
    |> Enum.chunk_by(& &1["check"])
    |> Enum.each(fn [first | _] = group ->
      IO.puts("#{first["label"] || first["check"]} (#{length(group)})")

      Enum.each(group, fn s ->
        IO.puts("  " <> line(s))
        IO.puts("      → " <> steps(s["proposal"]))

        for {name, alt} <- s["alternatives"] || %{},
            do: IO.puts("      or --choice #{inspect(name)}: " <> steps(alt))

        if s["needs_keep"],
          do:
            IO.puts("      needs --keep: " <> Enum.map_join(s["cards"], " or ", &"##{&1["id"]}"))
      end)
    end)

    IO.puts(
      "\n#{length(suggestions)} suggestion(s)." <>
        last_run(r["last_run"]) <>
        " Apply: slipdock garden apply <id>; dismiss: slipdock garden dismiss <id>"
    )
  end

  defp last_run(nil), do: " The board hasn't been looked over yet: --run."

  defp last_run(%{"finished_at" => at}) when is_binary(at),
    do: " Last looked over #{String.slice(at, 0, 16)}."

  defp last_run(_), do: ""

  @doc false
  def line(s) do
    state = if s["state"] == "open", do: "", else: " [#{s["state"]}]"
    "##{s["id"]}#{state} #{s["explanation"]}"
  end

  @doc false
  # The steps in words: "complete #12, move #12 to list 34".
  def steps(steps) do
    Enum.map_join(steps, ", ", fn step ->
      card = step_card(step)

      case step["op"] do
        "complete" ->
          "complete #{card}"

        "move" ->
          "move #{card} to list #{step["column"]}"

        "archive" ->
          if step["page"], do: "archive page #{step["page"]}", else: "archive #{card}"

        "link_duplicate" ->
          "link #{card} as a duplicate of #{other(step)}"

        "flag" ->
          "flag #{card} #{step["flag"]}"

        "comment" ->
          "comment on #{card}: #{inspect(step["body"])}"

        "snooze" ->
          "snooze #{card} until #{step["until"]}"

        "redate" ->
          "re-date #{card} to #{step["due"]}"

        "rewrite_link" ->
          "rewrite [[#{step["from"]}]] to [[#{step["to"]}]] on page #{step["page"]}"

        "file_page" ->
          "file page #{step["page"]} into folder #{step["folder"]}"

        op ->
          op
      end
    end)
  end

  defp step_card(%{"card" => "pick"}), do: "the one not kept"
  defp step_card(%{"card" => id}), do: "##{id}"
  defp step_card(_), do: ""

  defp other(%{"other" => "keep"}), do: "the one kept"
  defp other(%{"other" => id}), do: "##{id}"

  @doc false
  def settings(checks) do
    Enum.each(checks, fn c ->
      onoff = if c["enabled"], do: "on ", else: "off"

      extra =
        (c["settings"] || %{})
        |> Enum.sort()
        |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

      IO.puts(String.trim_trailing("#{onoff}  #{String.pad_trailing(c["key"], 20)} #{extra}"))
    end)
  end
end
