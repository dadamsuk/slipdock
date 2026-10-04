defmodule SlipdockCLI.Automations do
  @moduledoc false

  # Board automation rules, the presets and vocabulary they are written in,
  # the calls they have made, and the alerts they raise.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(automations automation automation-help alerts dismiss automation-presets new-automation set-automation run-automation callbacks delete-automation)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  ## Automations and alerts ---------------------------------------------------

  def run("automations", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/automations")
    |> out(o, &Render.automations(&1["automations"]))
  end

  def run("automation", [ref, rule], o) do
    HTTP.get("/boards/#{enc(ref)}/automations/#{enc(rule)}")
    |> out(o, &Render.automation(&1["automation"]))
  end

  # The grammar a --spec has to be written in, straight from the server.
  def run("automation-help", [], o),
    do: HTTP.get("/automations/vocabulary") |> out(o, &Render.vocabulary/1)

  def run("alerts", [], o), do: HTTP.get("/alerts") |> out(o, &Render.alerts(&1["alerts"]))

  def run("dismiss", ids, o) do
    cond do
      o[:all] ->
        HTTP.delete("/alerts")
        |> out(o, fn r -> IO.puts("dismissed #{r["dismissed"]} alert(s)") end)

      ids == [] ->
        fail("pass alert ids (see `slipdock alerts`) or --all")

      true ->
        Enum.each(ids, fn id ->
          HTTP.delete("/alerts/#{enc(id)}")
          |> out(o, fn _ -> IO.puts("dismissed alert ##{id}") end)
        end)
    end
  end

  def run("automation-presets", [], o),
    do: HTTP.get("/automations/presets") |> out(o, &Render.automation_presets(&1["presets"]))

  def run("new-automation", [ref | words], o) do
    body =
      cond do
        o[:preset] ->
          compact(%{
            "preset" => o[:preset],
            "params" => preset_params(words),
            "name" => o[:name]
          })

        o[:spec] ->
          compact(%{
            "spec" => spec_json(o[:spec]),
            "name" => o[:name] || nonblank(Enum.join(words, " ")),
            "scope" => scope_of(o[:tree]),
            "text" => nonblank(Enum.join(words, " "))
          })

        words != [] ->
          %{"text" => Enum.join(words, " ")}

        true ->
          fail("describe the rule in words, or pass --spec (see `slipdock automation-help`)")
      end

    HTTP.post("/boards/#{enc(ref)}/automations", body)
    |> out(o, fn r ->
      a = r["automation"]
      IO.puts("added automation ##{a["id"]}: #{a["name"]}")
      IO.puts(Render.dim(a["summary"]))
    end)
  end

  def run("set-automation", [ref, rule], o) do
    body =
      compact(%{
        "enabled" => cond_bool(o[:on], o[:off]),
        "name" => o[:name],
        "spec" => o[:spec] && spec_json(o[:spec]),
        "text" => o[:text],
        "scope" => scope_of(o[:tree])
      })

    if body == %{}, do: fail("nothing to change — pass --on, --off, --name, --spec or --text")

    HTTP.patch("/boards/#{enc(ref)}/automations/#{enc(rule)}", body)
    |> out(o, fn r ->
      a = r["automation"]
      IO.puts("##{a["id"]} #{a["name"]} is #{if a["enabled"], do: "on", else: "off"}")
      IO.puts(Render.dim(a["summary"]))
    end)
  end

  def run("run-automation", [ref, rule], o) do
    HTTP.post("/boards/#{enc(ref)}/automations/#{enc(rule)}/run", %{})
    |> out(o, fn r ->
      a = r["automation"]

      IO.puts(
        case r["fired"] do
          0 -> "nothing matched “#{a["name"]}” right now"
          1 -> "“#{a["name"]}” ran once"
          n -> "“#{a["name"]}” ran #{n} times"
        end
      )

      if a["last_error"], do: IO.puts(Render.dim("last error: " <> a["last_error"]))
    end)
  end

  def run("callbacks", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/automations/callbacks", limit: o[:limit])
    |> out(o, &Render.callbacks(&1["callbacks"]))
  end

  def run("delete-automation", [ref, rule], o) do
    HTTP.delete("/boards/#{enc(ref)}/automations/#{enc(rule)}")
    |> out(o, fn _ -> IO.puts("deleted automation #{rule}") end)
  end

  def run(cmd, _args, _o), do: bad_usage(cmd)

  ## Helpers ------------------------------------------------------------------

  # A spec is JSON: inline, from a file, or from stdin with `--spec -`.
  # field=value words, for a preset's form.
  defp preset_params(words) do
    Map.new(words, fn word ->
      case String.split(word, "=", parts: 2) do
        [key, value] when key != "" -> {key, value}
        _ -> fail("preset values go as field=value, e.g. column=Doing (got “#{word}”)")
      end
    end)
  end

  defp spec_json("-"), do: decode_spec(IO.read(:stdio, :eof))

  defp spec_json(source) do
    if File.regular?(source), do: decode_spec(File.read!(source)), else: decode_spec(source)
  end

  defp decode_spec(text) when is_binary(text) do
    case :json.decode(text) do
      %{} = spec -> spec
      _ -> fail("--spec must be a JSON object (see `slipdock automation-help`)")
    end
  rescue
    _ -> fail("--spec isn't valid JSON (see `slipdock automation-help`)")
  end

  defp decode_spec(_), do: fail("could not read the spec")

  # --tree watches the board's subcards too; --no-tree goes back to the board alone.
  defp scope_of(true), do: "tree"
  defp scope_of(false), do: "board"
  defp scope_of(nil), do: nil
end
