defmodule SlipdockCLI.Findings do
  @moduledoc false

  # Findings (W-2310 §Findings): what each card taught, from the `Findings:`
  # block of closing comments and the system's own signals, kept on the
  # tree's root board. `findings <board>` lists them; `finding <id>
  # dismiss|promote|merge|reopen` triages one.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP

  @commands ~w(findings finding)
  @actions ~w(dismiss promote merge reopen)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("findings", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/findings", query(o)) |> out(o, &listing(&1, o))
  end

  def run("findings", _args, _o) do
    fail(
      "usage: slipdock findings <board> [--status open|promoted|dismissed|merged|all] [--kind K] [--source S] [--card ID] [--days N] [--scope board|runner|all]"
    )
  end

  def run("finding", [id, action], o) when action in @actions do
    case body(action, o) do
      {:ok, body} -> HTTP.patch("/findings/#{enc(id)}", body) |> out(o, &changed/1)
      {:error, message} -> fail(message)
    end
  end

  def run("finding", _args, _o) do
    fail(
      "usage: slipdock finding <id> dismiss|promote|reopen [--note TEXT] | finding <id> merge --into ID"
    )
  end

  @doc false
  def query(o) do
    [
      status: o[:status],
      kind: o[:kind] |> List.wrap() |> List.last(),
      source: o[:source],
      card: o[:card],
      since: o[:days],
      scope: o[:scope]
    ]
  end

  @doc false
  def body("merge", o) do
    case o[:into] do
      nil -> {:error, "merge needs --into <finding id>: the one it joins"}
      into -> {:ok, %{"action" => "merge", "into" => into, "note" => o[:note]}}
    end
  end

  def body(action, o), do: {:ok, %{"action" => action, "note" => o[:note]}}

  @doc false
  def listing(%{"findings" => []}, o) do
    IO.puts(
      if Enum.member?([nil, "open"], o[:status]), do: "No open findings.", else: "No findings."
    )
  end

  def listing(%{"findings" => findings}, _o) do
    Enum.each(findings, &IO.puts(line(&1)))
  end

  @doc false
  def line(f) do
    card = if c = f["card"], do: " ##{c["id"]}", else: ""
    also = also(f)
    runner = runner(f)
    count = if (f["count"] || 1) > 1, do: " ×#{f["count"]}", else: ""
    status = if f["status"] == "open", do: "", else: " [#{f["status"]}]"
    note = if blank?(f["note"]), do: "", else: " — #{f["note"]}"
    into = if f["merged_into_id"], do: " → ##{f["merged_into_id"]}", else: ""

    "##{f["id"]}#{status} #{f["kind"]}#{runner} (#{f["source"]}#{card}#{also})#{count}: #{f["text"]}#{into}#{note}"
  end

  # The other cards a lesson was said on, merged into this one (#1941).
  defp also(f) do
    own = get_in(f, ["card", "id"])

    case for(c <- f["cards"] || [], c["id"] != own, do: "##{c["id"]}") do
      [] -> ""
      ids -> ", also " <> Enum.join(ids, " ")
    end
  end

  defp runner(%{"scope" => "runner"} = f) do
    case f["runner"] do
      %{"name" => name} -> " [runner #{name}]"
      _ -> " [runner]"
    end
  end

  defp runner(_f), do: ""

  defp blank?(v) when v in [nil, ""], do: true
  defp blank?(_), do: false

  defp changed(%{"finding" => f}), do: IO.puts("finding " <> line(f))
end
