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
    HTTP.get("/boards/#{enc(ref)}/findings", query(o))
    |> out(o, &listing(&1, o))
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
      into -> {:ok, %{"action" => "merge", "into" => into, "note" => note(o)}}
    end
  end

  def body(action, o), do: {:ok, %{"action" => action, "note" => note(o)}}

  # `--note -` reads it from stdin (#2678).
  defp note(o), do: stdin_arg(o[:note], "--note")

  # First what waits on the person (#2123): the proposals drafted from the
  # findings. The findings after it are being handled, and are reference.
  @doc false
  def listing(data, o) do
    Enum.each(awaiting(Map.get(data, "awaiting", [])), &IO.puts/1)
    findings(data["findings"], o)
  end

  defp findings([], o) do
    IO.puts(
      if Enum.member?([nil, "open"], o[:status]), do: "No open findings.", else: "No findings."
    )
  end

  defp findings(findings, _o), do: Enum.each(findings, &IO.puts(line(&1)))

  @doc false
  def awaiting([]), do: []

  # Each by id, so what to decide is exactly these: on a sub-board they are
  # the root's, and other proposals on the board are not among them.
  def awaiting(proposals) do
    n = length(proposals)

    each =
      Enum.map(proposals, &"  proposal ##{&1["id"]} (from #{from(&1)}): #{&1["explanation"]}")

    # A proposal is a person's call, made on the board's Tidy-up page and
    # nowhere else (#2668, #2688).
    decide =
      "  Decide each on the board's Tidy-up page: " <>
        SlipdockCLI.Garden.tidy_url(hd(proposals)["board_id"])

    ["#{n} #{if n == 1, do: "proposal awaits", else: "proposals await"} you:" | each] ++
      [decide, ""]
  end

  defp from(p), do: p |> Map.get("findings", []) |> Enum.map_join(", ", &"##{&1}")

  @doc false
  def line(f, now \\ DateTime.utc_now()) do
    found = found(f["created_at"], now)
    card = if c = f["card"], do: " ##{c["id"]}", else: ""
    also = also(f)
    runner = runner(f)
    count = if (f["count"] || 1) > 1, do: " ×#{f["count"]}", else: ""
    status = if f["status"] == "open", do: "", else: " [#{f["status"]}]"
    note = if blank?(f["note"]), do: "", else: " — #{f["note"]}"
    into = if f["merged_into_id"], do: " → ##{f["merged_into_id"]}", else: ""
    proposal = proposal(f)

    "##{f["id"]}#{found}#{status} #{f["kind"]}#{runner} (#{f["source"]}#{card}#{also})#{count}: #{f["text"]}#{into}#{proposal}#{note}"
  end

  # When it was found (#2114), in UTC as the server sends it: "today 17:30"
  # for today's, the date for older ones, so this morning's leftovers read
  # apart from the last hour's. Nothing when the server sent no time.
  defp found(iso, now) do
    case DateTime.from_iso8601(to_string(iso)) do
      {:ok, at, _} ->
        if DateTime.to_date(at) == DateTime.to_date(now),
          do: " today " <> Calendar.strftime(at, "%H:%M"),
          else: " " <> Date.to_iso8601(DateTime.to_date(at))

      _ ->
        ""
    end
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

  # The garden proposal drafted for it once it was seen often enough (#1942).
  defp proposal(%{"proposal_id" => id} = f) when is_integer(id) do
    rule = if blank?(f["proposed_rule"]), do: "", else: " #{f["proposed_rule"]}"
    " [proposal ##{id}#{rule}]"
  end

  defp proposal(_f), do: ""

  defp blank?(v) when v in [nil, ""], do: true
  defp blank?(_), do: false

  defp changed(%{"finding" => f}), do: IO.puts("finding " <> line(f))
end
