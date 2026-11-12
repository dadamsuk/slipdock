defmodule SlipdockCLI.Render do
  @moduledoc "Human-readable output for API responses."

  alias SlipdockCLI.Ledger

  @flag_glyphs %{
    "flagged" => "⚑",
    "blocked" => "⛔",
    "review" => "👁",
    "waiting" => "⏳",
    "starred" => "★"
  }

  # OTP's :json would print Elixir's nil as the string "nil"; emit JSON null.
  def json(data), do: IO.puts(json_string(data))

  @doc "The same JSON as `json/1`, returned rather than printed — for writing to a file."
  def json_string(data) do
    formatted =
      :json.format(data, fn
        nil, _enc, _state -> "null"
        other, enc, state -> :json.format_value(other, enc, state)
      end)

    IO.iodata_to_binary(formatted)
  end

  def boards(boards) do
    # The STATE and OWNER columns only turn up when there is something to say
    # in them, so the everyday listing stays as narrow as it was.
    any_archived? = Enum.any?(boards, & &1["archived_at"])
    any_shared? = Enum.any?(boards, & &1["shared"])

    rows =
      Enum.map(boards, fn b ->
        [
          to_string(b["id"]),
          b["code"] || "",
          b["shortcut"] || "",
          b["name"]
        ] ++
          if(any_archived?, do: [if(b["archived_at"], do: "archived", else: "")], else: []) ++
          if(any_shared?, do: [if(b["shared"], do: owner_name(b), else: "")], else: []) ++
          [
            "#{b["cards"]}",
            "#{b["completed"]}",
            b["description"] || ""
          ]
      end)

    headers =
      ["ID", "CODE", "KEY", "NAME"] ++
        if(any_archived?, do: ["STATE"], else: []) ++
        if(any_shared?, do: ["OWNER"], else: []) ++
        ["CARDS", "DONE", "DESCRIPTION"]

    table(headers, rows)
  end

  # Whose board it is: the owner's name, their email when they have not given
  # one, and "nobody yet" for a board nobody has claimed.
  def owner_name(%{"owner" => %{} = owner}),
    do: owner["name"] || owner["email"] || "nobody yet"

  def owner_name(_board), do: "nobody yet"

  def templates([]), do: IO.puts(dim("no templates"))

  def templates(templates) do
    rows =
      Enum.map(templates, fn t ->
        lists =
          Enum.map_join(t["columns"], " · ", fn c ->
            c["name"] <> if(c["wip_limit"], do: "/#{c["wip_limit"]}", else: "")
          end)

        # Built in: the same for everyone, and read-only. The rest are yours.
        # A server older than template owners doesn't say either way.
        whose =
          case t["system"] do
            true -> "built-in"
            false -> "you"
            nil -> ""
          end

        [to_string(t["id"]), t["name"], whose, lists, t["description"] || ""]
      end)

    table(["ID", "NAME", "OWNER", "LISTS", "DESCRIPTION"], rows)
  end

  @doc """
  The brake, first, when the board's runner work is held (#1116): one line
  per pause, so a session working without a pool sees it and stops.
  """
  def paused(pauses) when is_list(pauses) and pauses != [] do
    Enum.each(pauses, fn p -> IO.puts(bold("PAUSED") <> " #{p["scope"]}: #{p["line"]}") end)
  end

  def paused(_), do: :ok

  # The board's lanes, when there is something to say: advisory (#1972),
  # and its shared paths (#1971).
  defp lanes_lines(b) do
    if b["lane_mode"] == "advise", do: IO.puts(dim("lanes: advise (overlaps are told, not held)"))
    shared_paths_line(b["shared_paths"])
  end

  defp shared_paths_line([_ | _] = globs),
    do: IO.puts(dim("shared paths (hold no lane): " <> Enum.join(globs, ", ")))

  defp shared_paths_line(_globs), do: :ok

  # The card in progress its paths overlap (#1972), and what that does.
  defp lane_overlap_line(%{"card" => id, "title" => title, "mode" => "advise"} = o),
    do:
      IO.puts(
        indent(
          dim(
            "overlaps ##{id} “#{title}” in progress, advisory: an agent may start" <>
              broad_side(o)
          )
        )
      )

  defp lane_overlap_line(%{"card" => id, "title" => title} = o),
    do:
      IO.puts(
        indent(
          dim(
            "overlaps ##{id} “#{title}” in progress: an agent can't start this" <> broad_side(o)
          )
        )
      )

  defp lane_overlap_line(_overlap), do: :ok

  # Whose broad glob makes the overlap (#2698).
  defp broad_side(%{"broad" => side, "broad_paths" => globs}) do
    whose = %{"this" => "this card's", "other" => "its", "both" => "both cards'"}[side]
    " (#{whose || side} broad #{Enum.join(globs, ", ")})"
  end

  defp broad_side(_overlap), do: ""

  # A card's paths one per line, those shared on the board (#1971) and
  # those that claim a whole top-level directory (#2698) marked.
  defp paths_text(paths, shared, broad) do
    shared = shared || []
    broad = broad || []

    Enum.map_join(paths, "\n", fn path ->
      cond do
        Enum.member?(shared, path) -> path <> dim("  shared")
        Enum.member?(broad, path) -> path <> yellow("  broad")
        true -> path
      end
    end)
  end

  # Why a broad glob is marked (#2698), as the server says it.
  defp broad_line([_ | _], reason),
    do: IO.puts(indent(dim("broad: " <> (reason || "it overlaps most cards"))))

  defp broad_line(_broad, _reason), do: :ok

  def board(b) do
    IO.puts(
      bold("#{b["name"]}") <>
        "  (board ##{b["id"]}#{if b["code"], do: " · #{b["code"]}"}#{if b["shortcut"], do: " · key #{b["shortcut"]}"}, #{b["color"]}#{if b["simple"], do: " · simple"}#{if not Enum.member?([nil, "board"], b["default_view"]), do: " · opens on #{b["default_view"]}"}#{if b["archived_at"], do: " · archived"})"
    )

    if pc = b["parent_card"] do
      IO.puts(dim("sub-board of card ##{pc["id"]} “#{pc["title"]}” on board ##{pc["board_id"]}"))
    end

    if b["description"], do: IO.puts(dim(b["description"]))

    if b["kind"] == "sprints",
      do: IO.puts(dim("sprint board: each card is a sprint — slipdock sprint / sprint-add"))

    if b["owner"], do: IO.puts(dim("owner: " <> owner_name(b)))
    # What in this tree waits on you (#2095).
    waiting_count_line(b)

    lanes_lines(b)

    tags = Enum.map(b["tags"], & &1["name"])
    if tags != [], do: IO.puts(dim("tags: " <> Enum.join(tags, ", ")))

    Enum.each(b["columns"], fn col ->
      wip = if col["wip_limit"], do: "/#{col["wip_limit"]}", else: ""
      IO.puts("")

      pages = col["pages"] || []

      IO.puts(
        bold("## #{col["name"]}") <>
          dim(
            "  #{length(col["cards"])}#{wip} cards" <>
              if(pages == [], do: "", else: ", #{length(pages)} page(s)") <>
              " (column ##{col["id"]})" <> list_note(col)
          )
      )

      # Cards and placed wiki pages share one order in the list, so the CLI
      # prints them the way the board draws them rather than in two groups.
      (Enum.map(col["cards"], &{&1["position"], 0, {:card, &1}}) ++
         Enum.map(pages, &{&1["board_position"], 1, {:page, &1}}))
      |> Enum.sort()
      |> Enum.each(fn
        {_, _, {:card, card}} ->
          board_card(card)

        {_, _, {:page, page}} ->
          IO.puts("  " <> page_line(page))
      end)
    end)
  end

  # The lists nobody takes work from when asked what next: a Triage list is
  # for a person, a Scheduled one (#2100) is worked by feed rules.
  defp list_note(%{"category" => "triage"}), do: " · triage: for a person, never pick from it"

  defp list_note(%{"category" => "scheduled"}),
    do: " · scheduled: worked by feed rules, never pick from it"

  # A Housekeeping one (#2777) is worked by runners after the ready list.
  defp list_note(%{"category" => "housekeeping"}),
    do: " · housekeeping: worked by runners after the ready list"

  defp list_note(_col), do: ""

  # `waiting_on_me` (#2095): the tree's count when anything is on you, and
  # an epic's glance line when anything waits in its tree.
  defp waiting_count_line(%{"waiting_on_me" => %{"count" => n}}) when is_integer(n) and n > 0,
    do: IO.puts("Waiting on you: #{n}  " <> dim("slipdock work"))

  defp waiting_count_line(_), do: :ok

  # A card in `slipdock board`'s lists, with an epic's glance line under it.
  defp board_card(card) do
    IO.puts("  " <> card_line(card, false))
    waiting_line(card, "        ⏸ ")
  end

  defp waiting_line(%{"waiting_on_me" => %{"line" => line}}, prefix) when is_binary(line),
    do: IO.puts(prefix <> line)

  defp waiting_line(_, _prefix), do: :ok

  defp page_line(p) do
    facets = page_facets(p)

    dim("#{p["code"]}") <>
      "  " <> p["title"] <> if(facets == "", do: "", else: "  " <> dim(facets))
  end

  def columns(cols) do
    rows =
      Enum.map(cols, fn c ->
        [
          to_string(c["id"]),
          c["name"],
          to_string(c["cards"]),
          to_string(c["wip_limit"] || "-"),
          c["color"] || "-",
          list_order(c)
        ]
      end)

    table(["ID", "NAME", "CARDS", "WIP", "COLOR", "ORDER"], rows)
  end

  # How the web app draws the list: "-" for board order and no groups.
  def list_order(c) do
    [
      c["sort_by"] && "#{c["sort_by"]}#{if c["sort_dir"] == "desc", do: " desc"}",
      c["group_by"] && "by #{c["group_by"]}"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "-"
      parts -> Enum.join(parts, ", ")
    end
  end

  def tags(tags) do
    table(
      ["ID", "NAME", "COLOR"],
      Enum.map(tags, &[to_string(&1["id"]), &1["name"], &1["color"]])
    )
  end

  def activity(items) do
    Enum.each(items, fn a ->
      IO.puts(
        dim(String.slice(a["at"] || "", 0, 16) |> String.replace("T", " ")) <>
          "  " <> a["message"]
      )
    end)
  end

  # `slipdock pulse`: the board's flow numbers, then each list's traffic.
  @doc """
  `slipdock work`: "Waiting on you" first, in the server's order (oldest
  first), each with why and for how long, a wait's choices numbered for
  `slipdock answer --choice N`; then the assigned cards by section.
  """
  def work(%{"waiting" => waiting, "sections" => sections} = r) do
    hidden = hidden_line(r)
    if waiting != [] or hidden, do: waiting_section(waiting, hidden)

    Enum.each(sections, fn s ->
      IO.puts(bold("#{s["label"]} (#{length(s["cards"])})"))

      Enum.each(s["cards"], fn c ->
        due = if c["due_date"], do: dim("  due #{c["due_date"]}"), else: ""

        IO.puts(
          "  ##{c["id"]} #{c["title"]}#{due}  " <>
            dim("#{Enum.join(c["path"] || [], " › ")} · #{c["column"]}")
        )
      end)
    end)

    if waiting == [] and sections == [] and is_nil(hidden),
      do: IO.puts(dim("nothing waiting on you, nothing assigned"))
  end

  defp waiting_section(waiting, hidden) do
    IO.puts(bold("Waiting on you (#{length(waiting)})"))
    if hidden, do: IO.puts(dim("  " <> hidden))

    Enum.each(waiting, fn i ->
      c = i["card"]
      IO.puts("  ##{c["id"]} #{c["title"]}  " <> dim(since(i["since"])))
      IO.puts("      #{i["text"]}" <> choices(i["wait"]))
      todo(i["condition"])
      IO.puts(dim("      #{Enum.join(i["path"] || [], " › ")} · #{c["column"]}"))
    end)
  end

  # "3 waiting · 2 dismissed · 1 board muted" (#2069), so the hiding is never
  # silent; nil when nothing is hidden.
  defp hidden_line(r) do
    dismissed = r["dismissed_count"] || 0
    boards = length(r["muted_boards"] || [])
    muted = r["muted_count"] || 0

    if dismissed + boards > 0 do
      [
        "#{length(r["waiting"])} waiting",
        dismissed > 0 && "#{dismissed} dismissed (slipdock work --dismissed)",
        boards > 0 &&
          "#{boards} #{if boards == 1, do: "board", else: "boards"} muted " <>
            "(#{Enum.map_join(r["muted_boards"], ", ", & &1["name"])}; #{muted} hidden)"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")
    end
  end

  @doc "`slipdock work --dismiss`: what came off the list, and for which cause."
  def work_dismissed(%{"dismissed" => i}) do
    c = i["card"]
    IO.puts("dismissed ##{c["id"]} #{c["title"]}: #{i["text"]}")
    IO.puts(dim("  a new cause shows it again; undo: slipdock work --undismiss #{c["id"]}"))
  end

  @doc "`slipdock work --undismiss`."
  def work_undismissed(%{"undismissed" => %{"card_id" => id}}),
    do: IO.puts("##{id} is back on your list while its cause stands")

  @doc "`slipdock work --dismissed`: what you dismissed whose cause still stands."
  def work_dismissed_list(%{"dismissed" => []}),
    do: IO.puts(dim("nothing dismissed"))

  def work_dismissed_list(%{"dismissed" => items}) do
    IO.puts(bold("Dismissed (#{length(items)})"))

    Enum.each(items, fn i ->
      c = i["card"]
      IO.puts("  ##{c["id"]} #{c["title"]}  " <> dim(since(i["since"])))
      IO.puts("      #{i["text"]}")
      IO.puts(dim("      #{Enum.join(i["path"] || [], " › ")} · #{c["column"]}"))
    end)

    IO.puts(dim("undo one: slipdock work --undismiss <card>"))
  end

  @doc "`slipdock work --mute` / `--unmute`."
  def work_muted(%{"muted" => b}),
    do: IO.puts("muted #{b["name"]}: its tree stays off your Waiting on you (undo: --unmute)")

  def work_muted(%{"unmuted" => b}),
    do: IO.puts("unmuted #{b["name"]}: its tree is back on your Waiting on you")

  # An overseer condition's what to do (#2068), under its item.
  defp todo(%{"todo" => todo}) when is_binary(todo), do: IO.puts("      What to do: #{todo}")
  defp todo(_), do: :ok

  @doc """
  `slipdock multiboard`: each section's heading (none for the grid), then its
  cards with the list they are in — and the board too where the heading
  does not already say it.
  """
  def multiboard(%{"sections" => sections, "by" => by} = r) do
    if m = r["multiboard"],
      do: IO.puts(bold("#{m["name"]}") <> dim("  ##{m["id"]} · #{m["color"]}"))

    Enum.each(sections, fn s ->
      if s["label"], do: IO.puts(bold("#{s["label"]} (#{length(s["cards"])})"))
      if s["cards"] == [], do: IO.puts(dim("  no cards"))

      Enum.each(s["cards"], fn c ->
        where =
          case by do
            "list" -> ""
            "grid" -> dim("  #{c["board"]} › #{c["column"]}")
            _ -> dim("  #{c["column"]}")
          end

        IO.puts("  ##{c["id"]} #{c["title"]}" <> where)
      end)
    end)

    if sections == [],
      do: IO.puts(dim("no lists chosen: pass --list, or pick them on the Multiboard page"))
  end

  @doc "Saved multiboards (#1482): one line each."
  def multiboards(%{"multiboards" => []}),
    do: IO.puts(dim("no saved multiboards: save-multiboard <name>, or Save on the page"))

  def multiboards(%{"multiboards" => saved}) do
    Enum.each(saved, fn m ->
      n = length(m["lists"])

      IO.puts(
        "##{m["id"]} #{bold(m["name"])}  " <>
          dim(
            "#{m["color"]} · #{n} #{if n == 1, do: "list", else: "lists"} · top #{m["top"]} by #{m["by"]}"
          )
      )
    end)
  end

  defp choices(%{"choices" => [_ | _] = choices}) do
    numbered =
      choices |> Enum.with_index(1) |> Enum.map_join("  ", fn {c, n} -> "[#{n}] #{c}" end)

    "  " <> dim(numbered)
  end

  defp choices(_), do: ""

  # How long ago an ISO time was, in the one unit that reads best.
  defp since(iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, at, _} -> span(max(DateTime.diff(DateTime.utc_now(), at), 0))
      _ -> ""
    end
  end

  def pulse(p) do
    t = p["time_to_done"]
    m = p["moves_24h"]

    IO.puts(
      "#{p["in_progress"]} in progress · #{p["waiting"]} waiting#{oldest_wait(p["oldest_wait_at"])}"
    )

    IO.puts("#{p["done_7d"]} done in 7 days, #{p["done_today"]} today")

    IO.puts(
      "time to done: P50 #{span(t["p50"])} · P85 #{span(t["p85"])} over #{t["cards"]} cards" <>
        if(t["lead_time"] > 0, do: dim(" (#{t["lead_time"]} from when made)"), else: "")
    )

    IO.puts("moves in 24h: #{m["forward"]} forward · #{m["back"]} back · #{m["total"]} in all")

    Enum.each(p["lists"], fn l ->
      IO.puts(
        "  #{l["name"]}  in #{l["in_7d"]} · out #{l["out_7d"]}" <>
          dim(if l["usual_stay"], do: "  usually #{span(l["usual_stay"])}", else: "")
      )
    end)
  end

  # One line per day, then the weeks (90 days) and the cycle time.
  def flow(f) do
    IO.puts("last #{f["days"]} days (#{f["since"]} to #{f["until"]}, #{f["timezone"]})")
    IO.puts(dim("  date        backlog ready doing done  completed added open"))

    Enum.each(f["series"], fn d ->
      IO.puts(
        "  #{d["date"]}  " <>
          Enum.map_join(
            [
              {d["backlog"], 7},
              {d["ready"], 5},
              {d["doing"], 5},
              {d["done"], 5},
              {d["completed"], 9},
              {d["added"], 5},
              {d["open"], 4}
            ],
            " ",
            fn {n, w} -> String.pad_leading(to_string(n), w) end
          )
      )
    end)

    if f["days"] == 90 do
      IO.puts("completed by week:")
      Enum.each(f["weeks"], &IO.puts("  #{&1["week"]}  #{&1["completed"]}"))
    end

    c = f["cycle"]
    IO.puts("cycle time: P50 #{span(c["p50"])} · P85 #{span(c["p85"])} over #{c["cards"]} cards")
  end

  @doc """
  A board's quality numbers (#1796, `GET /boards/:b/quality`); `all_rules`
  (`--rules`) lists every broken rule rather than the five most broken.
  """
  def quality(q, all_rules \\ false) do
    v = q["verified"]
    p = q["previous"]
    IO.puts("last #{q["days"]} days (#{q["since"]} to #{q["until"]})")

    if v["accepted"] == 0 do
      IO.puts("first-time-right: " <> dim("no cards accepted in the window"))
    else
      IO.puts(
        "first-time-right: #{share(v["rate"])} (#{v["first_time_right"]} of #{v["accepted"]} accepted)" <>
          quality_before(p)
      )

      IO.puts(
        "rework: #{v["rejections"]} rejections, #{v["per_card"]} per card" <>
          if(v["reopened"] > 0, do: " · #{v["reopened"]} reopened", else: "")
      )
    end

    if v["in_rework"] > 0,
      do: IO.puts("in rework now: #{v["in_rework"]} rejected, not yet accepted")

    if q["areas"] != [] do
      IO.puts(dim("  area                              cards  right  rejections  per card"))
      Enum.each(q["areas"], &IO.puts(quality_area(&1)))
    end

    j = q["jobs"]

    if j["jobs"] == 0 do
      IO.puts("jobs: " <> dim("none finished in the window"))
    else
      r = j["per_100"]

      IO.puts(
        "jobs: #{j["jobs"]} finished · per 100: #{r["timeouts"]} timeouts, #{r["failed"]} failed, " <>
          "#{r["requeues"]} requeues, #{r["gave_up"]} give-ups"
      )
    end

    h = q["health"]

    IO.puts(
      "health: #{h["incidents"]} incidents · #{h["fixed"]} fixed, #{h["flagged"]} flagged, " <>
        "#{h["cleared"]} cleared, #{h["open"]} open"
    )

    quality_rejections(q["rejections"], all_rules)

    case q["audits"] do
      %{"audits" => n} = a when n > 0 ->
        IO.puts("audits: #{n} · #{a["agreed"]} agreed, #{a["disagreed"]} disagreed")

      _ ->
        :ok
    end
  end

  @quality_top_rules 5

  # Rejections in parts (#1798): what failed, then the rules most broken.
  defp quality_rejections(%{"rejections" => n} = r, all_rules) when n > 0 do
    parts = Enum.map_join(r["by_part"], ", ", &"#{&1["count"]} #{part_name(&1["part"])}")
    unparted = if r["unparted"] > 0, do: "#{r["unparted"]} naming no part", else: nil

    IO.puts(
      "rejections: #{n} · " <>
        Enum.join(Enum.reject([parts, unparted], &Enum.member?([nil, ""], &1)), ", ")
    )

    if r["disputed_lines"] > 0, do: IO.puts("disputed Handbook lines: #{r["disputed_lines"]}")

    rules = r["by_rule"]
    shown = if all_rules, do: rules, else: Enum.take(rules, @quality_top_rules)

    if shown != [] do
      IO.puts(dim("  rule        broken  page"))
      Enum.each(shown, &IO.puts(quality_rule(&1)))
    end

    if length(rules) > length(shown),
      do: IO.puts(dim("  … #{length(rules) - length(shown)} more: --rules lists them all"))
  end

  defp quality_rejections(_r, _all_rules),
    do: IO.puts("rejections: " <> dim("none in the window"))

  defp quality_rule(rule) do
    page =
      case rule["page"] do
        %{"code" => code, "title" => title} -> "#{code} #{title}"
        _ -> dim("not in the handbook")
      end

    id = Enum.join(Enum.reject([rule["id"], rule["severity"]], &is_nil/1), " ")

    "  " <>
      String.pad_trailing(id, 12) <>
      String.pad_leading(to_string(rule["count"]), 6) <> "  " <> page
  end

  defp part_name("ask"), do: "the ask"
  defp part_name("bar"), do: "the bar"
  defp part_name("rules"), do: "the rules"
  defp part_name("suite"), do: "the suite"
  defp part_name("handbook_line"), do: "the Handbook line"
  defp part_name("mutants"), do: "a surviving mutant"
  defp part_name(other), do: other

  defp quality_area(a) do
    name = if a["code"], do: "#{a["code"]} #{a["title"]}", else: a["title"]

    "  " <>
      String.pad_trailing(String.slice(name, 0, 32), 32) <>
      String.pad_leading(to_string(a["cards"]), 7) <>
      String.pad_leading(share(a["rate"]), 7) <>
      String.pad_leading(to_string(a["rejections"]), 12) <>
      String.pad_leading(to_string(a["per_card"]), 10)
  end

  defp share(nil), do: "–"
  defp share(r), do: "#{round(r * 100)}%"

  defp quality_before(%{"accepted" => n, "rate" => rate}) when n > 0,
    do: dim(" · #{share(rate)} the window before")

  defp quality_before(_), do: ""

  def runner_stats(%{"runners" => []}), do: IO.puts(dim("no runners take work from this board"))

  def runner_stats(s) do
    IO.puts("last #{s["days"]} days")

    Enum.each(s["runners"], fn r ->
      o = r["outcomes"]
      w = r["waits"]

      IO.puts(
        "#{r["name"]} (#{r["pool"]}) · #{r["status"]}" <>
          case r["current"] do
            nil -> ""
            c -> " · job ##{c["job_id"]} card ##{c["card_id"]} for #{span(c["elapsed"])}"
          end
      )

      IO.puts(
        "  #{o["done"]} done · #{o["parked"]} parked · #{o["failed"]} failed · #{o["running"]} running" <>
          if(r["success_rate"], do: " · #{round(r["success_rate"] * 100)}% succeeded", else: "")
      )

      IO.puts(
        "  job P50 #{span(r["duration"]["p50"])} · queue wait P50 #{span(r["queue_wait"]["p50"])}"
      )

      IO.puts(
        "  waits on people #{w["opened"]} (#{w["open"]} open, answered in #{span(w["answer"]["p50"])})" <>
          " · reopened #{r["reopened"]["count"]}"
      )
    end)

    if s["recent_jobs"] != [] do
      IO.puts("recent jobs:")

      Enum.each(s["recent_jobs"], fn j ->
        IO.puts(
          "  ##{j["job_id"]}  #{j["outcome"]}#{if j["reason"], do: ": #{j["reason"]}", else: ""}" <>
            "  #{span(j["duration"])}  card ##{j["card_id"]} #{j["title"]}"
        )
      end)
    end
  end

  defp oldest_wait(nil), do: ""

  defp oldest_wait(at),
    do: " (oldest since #{String.slice(at, 0, 16) |> String.replace("T", " ")})"

  # Seconds as the one unit that reads best, as the web app's strip has it.
  @doc false
  def span(nil), do: "-"
  def span(s) when s < 60, do: "<1m"
  def span(s) when s < 3600, do: "#{div(s, 60)}m"
  def span(s) when s < 86_400, do: "#{div(s, 3600)}h"
  def span(s), do: "#{div(s, 86_400)}d"

  def cards(cards) do
    if cards == [],
      do: IO.puts(dim("no cards")),
      else: Enum.each(cards, &IO.puts(card_line(&1, true)))
  end

  # A card's profile (#1951): a mark in its line, a field on the card.
  defp profile_mark(%{"profile" => p}) when is_binary(p), do: "profile:#{p}"
  defp profile_mark(_c), do: nil

  # Where it came from (#2018), beside it: "feature · inferred".
  defp profile_field(%{"profile" => p, "profile_source" => s}) when is_binary(p) and is_binary(s),
    do: field("Profile", "#{p} · #{profile_source_text(s)}")

  defp profile_field(%{"profile" => p}) when is_binary(p), do: field("Profile", p)
  defp profile_field(_c), do: nil

  defp profile_source_text("inferred"), do: "inferred"
  defp profile_source_text(source), do: "set by #{source}"

  def card_line(c, with_column?) do
    done = if c["completed"], do: "✓ ", else: ""
    title = if c["completed"], do: dim(c["title"]), else: c["title"]

    meta =
      [
        if(with_column? and c["column"], do: "[#{c["column"]}]"),
        if(c["priority"] != "none", do: "prio:#{c["priority"]}"),
        flags(c["flags"]),
        if(c["tags"] != [], do: "tags:" <> Enum.join(c["tags"], ",")),
        # Its profile (#1951), one word.
        profile_mark(c),
        if(c["start_date"], do: "start:#{c["start_date"]}"),
        if(c["due_date"], do: "due:#{c["due_date"]}"),
        if(c["percent_complete"], do: "#{c["percent_complete"]}%"),
        if(t = time_text(c), do: "⏱" <> t),
        if(c["blocked"],
          do:
            "🔒blocked-by:" <>
              Enum.map_join(
                Enum.reject(c["blocked_by"] || [], &(&1["completed"] or &1["released"])),
                ",",
                &"##{&1["id"]}"
              )
        ),
        if(c["sub_board"],
          do:
            "⊞#{c["sub_board"]["completed"]}/#{c["sub_board"]["total"]}" <>
              if(n = c["sub_board"]["awaiting"], do: " (#{n} awaiting verification)", else: "")
        ),
        # Waiting for a second agent (#1624).
        if(c["verify_state"] == "pending", do: "⏳awaiting verification"),
        if(c["verify_state"] == "merging", do: "⇄merging"),
        # Held for a person before merging (#1952).
        held_mark(c["verify_state"]),
        stand_in_text(c["stand_in_for"]),
        if((c["blocks"] || []) != [],
          do: "blocks:" <> Enum.map_join(c["blocks"], ",", &"##{&1["id"]}")
        ),
        if(c["checklist"]["total"] > 0,
          do: "☑#{c["checklist"]["done"]}/#{c["checklist"]["total"]}"
        ),
        if(c["comments"] != [], do: "💬#{length(c["comments"])}"),
        if(c["recurrence"], do: "↻"),
        if(c["snoozed_until"], do: "💤" <> String.slice(to_string(c["snoozed_until"]), 0, 10)),
        loop_mark(c["loop"]),
        driver_text(c["driver"]),
        age_text(c),
        if(c["archived_at"], do: "(archived)")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    state = if s = c["state"], do: "  ▸ " <> s, else: ""

    "#" <>
      String.pad_trailing(to_string(c["id"]), 4) <> done <> title <> "  " <> dim(meta) <> state
  end

  # The runner loop holding the card (#2027), beside its assignees but not
  # one of them: `⟳Mac Studio·verify`.
  defp loop_mark(%{} = loop), do: "⟳" <> loop_text(loop, "·")
  defp loop_mark(_), do: nil

  defp loop_text(loop, sep),
    do: "#{loop["runner"] || "a runner"}#{sep}#{loop["kind"]}"

  # Who is driving the card (#1117): only on a tree where agents work.
  # The Origin line (#2778), when the card has one.
  defp origin_field(c), do: if(o = origin_text(c), do: field("Origin", o))

  # Who or what made the card (#2778): `agent (job #12)`, `sweep`, or nil.
  defp origin_text(%{"origin" => origin, "origin_job_id" => job}) when is_binary(origin),
    do: if(job, do: "#{origin} (job ##{job})", else: origin)

  defp origin_text(_card), do: nil

  defp driver_text("agent"), do: "🤖agent"
  defp driver_text("human"), do: "👤human"
  defp driver_text(_), do: nil

  # How long the card has sat in its list, and how far past the usual (#1117).
  @doc false
  def age_text(%{"age" => age} = c) when is_integer(age) do
    case c["over_usual"] do
      over when is_integer(over) -> "⏳#{span(age)} (#{span(over)} over usual, stuck)"
      _ -> "⏳#{span(age)}"
    end
  end

  def age_text(_), do: nil

  # A stand-in sprint planning left where a card used to be: which card it
  # stands for, and how that card is doing.
  defp stand_in_text(nil), do: nil
  defp stand_in_text(s), do: "↪stand-in-for:##{s["id"]}(#{s["status"]})"

  defp stand_in_where(%{"board_id" => id}) when not is_nil(id), do: " on board ##{id}"
  defp stand_in_where(_), do: ""

  @time_suffix %{
    "minutes" => "m",
    "hours" => "h",
    "days" => "d",
    "weeks" => "w",
    "months" => "mo"
  }

  # "1.5h/4h 38%", or "1.5h" without an estimate; nil when nothing is tracked.
  # `long` spells it out for the card view.
  defp time_text(c, long \\ false)

  defp time_text(%{"time" => %{} = t}, long) do
    suffix = @time_suffix[t["unit"]] || "h"
    spent = (t["spent_minutes"] || 0) > 0
    running = t["timer_running"] == true

    if spent or t["estimate"] != nil or running do
      fmt = &"#{&1}#{suffix}"

      base =
        cond do
          t["estimate"] && long ->
            "#{fmt.(t["spent"])} spent of #{fmt.(t["estimate"])} estimated (#{t["percent"]}%#{if t["percent"] > 100, do: " — over", else: ""})"

          t["estimate"] ->
            "#{fmt.(t["spent"])}/#{fmt.(t["estimate"])} #{t["percent"]}%"

          long ->
            "#{fmt.(t["spent"])} spent, no estimate"

          true ->
            fmt.(t["spent"])
        end

      base <>
        cond do
          running and long -> " · timer running since #{t["timer_started_at"]}"
          running -> "▶"
          true -> ""
        end <> if(long, do: " · shown in #{t["unit"]}", else: "")
    end
  end

  defp time_text(_, _), do: nil

  # A recurring card's series in a line: the rule in words and what is next.
  defp recurrence_text(r) do
    state =
      cond do
        r["ended_at"] -> "ended"
        r["paused"] -> "paused"
        r["next_on"] -> "next due #{r["next_on"]}, made #{local_at(r["next_at"])}"
        r["kind"] == "after_done" -> "next counted from when this one is done"
        true -> "nothing more to come"
      end

    "#{r["summary"]} · #{state} · on_missed #{r["on_missed"]}#{ends_text(r)}"
  end

  defp local_at(nil), do: "-"

  defp local_at(at),
    do: at |> to_string() |> String.slice(0, 16) |> String.replace("T", " ") |> Kernel.<>(" UTC")

  defp ends_text(%{"ends" => "on", "ends_on" => d}), do: " · ends #{d}"
  defp ends_text(%{"ends" => "after", "count" => n, "made" => made}), do: " · #{made} of #{n}"
  defp ends_text(_), do: ""

  @doc "`slipdock repeat <id>`: the card's series, or that it has none."
  def recurrence(%{"card" => id, "recurrence" => nil}), do: IO.puts("##{id} doesn't repeat.")

  def recurrence(%{"card" => id, "recurrence" => r} = body) do
    whose =
      if body["current"] == false,
        do: dim(" (an earlier instance; the series is on ##{r["card_id"]} now)"),
        else: ""

    IO.puts(bold("##{id} repeats: ") <> recurrence_text(r) <> whose)
    IO.puts("  rule      #{r["rule"]}  (from #{r["starts_on"]})")
    IO.puts("  made at   #{r["at"]} #{r["timezone"]}" <> lead_text(r["lead_days"]))

    if (r["upcoming"] || []) != [],
      do: IO.puts("  coming    " <> Enum.join(r["upcoming"], ", "))
  end

  defp lead_text(n) when is_integer(n) and n > 0, do: ", #{n} day(s) before it is due"
  defp lead_text(_), do: ""

  @doc "`slipdock recurring <board>`: every series on the board, soonest first."
  def recurring(%{"recurring" => []}), do: IO.puts(dim("nothing on this board repeats"))

  def recurring(%{"recurring" => list}) do
    Enum.each(list, fn r ->
      IO.puts(
        "#" <>
          String.pad_trailing(to_string(r["card"]["id"]), 5) <>
          "↻ " <> r["card"]["title"] <> "  " <> dim(recurrence_text(r))
      )
    end)
  end

  # A card's handoff, first of its fields: read before anything else. On a
  # finished card (#2022) its outcome comes first instead, and a handoff
  # left after it finished is what is still to do.
  defp handoff_fields(h, label \\ "Left off") do
    field(label, bold(h["next_step"]) <> "  " <> dim(handoff_by(h)))
    if h["body"], do: IO.puts(indent(h["body"], "              "))
  end

  defp not_shipped_field(%{"text" => text}), do: field("Not shipped", yellow(text))
  defp not_shipped_field(_), do: :ok

  # A finished card's outcome first, else its handoff, else nothing.
  defp standing(%{"outcome" => %{}} = c), do: {:outcome, c}
  defp standing(%{"handoff" => %{} = h}), do: {:handoff, h}
  defp standing(_c), do: nil

  defp where_it_stands({:outcome, c}), do: outcome_fields(c)
  defp where_it_stands({:handoff, h}), do: handoff_fields(h)

  # A finished card's outcome, and the note written before it finished,
  # folded to its first line: history, not where it stands.
  defp outcome_fields(c) do
    field("Outcome", bold(c["outcome"]["text"]))
    if h = c["handoff"], do: handoff_fields(h, "Still to do")

    if h = c["last_handoff"],
      do: field("Last note", dim("before it finished: #{h["next_step"]} · #{handoff_by(h)}"))
  end

  defp handoff_by(h) do
    who =
      cond do
        b = h["by"] -> b["name"] || b["email"]
        h["via"] == "runner" -> "a runner"
        true -> "someone"
      end

    job = if h["job_id"], do: " · job ##{h["job_id"]}", else: ""
    "#{who} · #{String.slice(to_string(h["at"]), 0, 16)} · #{h["via"]}#{job}"
  end

  @doc "A wait in a line: on whom, what it needs, and the choices."
  def wait_line(w) do
    choices =
      case w["choices"] || [] do
        [] ->
          ""

        list ->
          "  " <>
            dim(
              list
              |> Enum.with_index(1)
              |> Enum.map_join("  ", &choice_item(&1, w["default_choice"]))
            )
      end

    "waits on #{person(w["on"]) || "anyone"}#{question_kind(w)}: #{w["needs"]}" <>
      choices <> questions(w)
  end

  # A choice, numbered; the proposed one (#2096) marked.
  defp choice_item({c, n}, n), do: "#{n}. #{c} (proposed)"
  defp choice_item({c, n}, _default), do: "#{n}. #{c}"

  # The kind of question it asks (#1949), which picked who it went to.
  defp question_kind(%{"question" => q}) when is_binary(q) and q != "", do: " (#{q})"
  defp question_kind(_w), do: ""

  # A series (#1220): each question on its own numbered line.
  defp questions(w) do
    case w["questions"] || [] do
      [] ->
        ""

      list ->
        list
        |> Enum.with_index(1)
        |> Enum.map_join("", fn {q, n} -> "\n    #{n}. #{q}" end)
    end
  end

  @doc """
  What a wait was answered with: the choice's text, then the words; for a
  series, each question's answer on its own line.
  """
  def wait_answer(w) do
    whole =
      [w["choice_text"], w["answer"]]
      |> Enum.reject(&Enum.member?([nil, ""], &1))
      |> Enum.join(" — ")

    case w["questions"] || [] do
      [] ->
        whole

      list ->
        answers = w["answers"] || []

        pairs =
          list
          |> Enum.with_index()
          |> Enum.map_join("", fn {q, i} ->
            a = Enum.at(answers, i)

            "\n    #{i + 1}. #{q}\n       → #{if Enum.member?([nil, ""], a), do: "(not answered)", else: a}"
          end)

        if whole == "", do: pairs, else: pairs <> "\n    " <> whole
    end
  end

  @doc "`slipdock waits <id>` (#1220): every question asked, newest first, and how it ended."
  def waits(%{"card" => id, "waits" => []}), do: IO.puts("##{id} has asked no questions")

  def waits(%{"card" => id, "waits" => waits}) do
    IO.puts(bold("##{id} questions") <> dim(" · newest first"))

    for w <- waits do
      by = person(w["opened_by"]) || "someone"
      at = String.slice(to_string(w["opened_at"]), 0, 16)
      IO.puts("\n" <> bold(wait_line(w)) <> "  " <> dim("asked by #{by} · #{at}"))

      case w["close_reason"] do
        nil ->
          IO.puts("  " <> dim("open"))

        "answered" ->
          IO.puts("  answered by #{person(w["closed_by"]) || "someone"}: " <> wait_answer(w))

        reason ->
          closer = if p = person(w["closed_by"]), do: " by #{p}", else: ""
          IO.puts("  " <> dim(String.replace(reason, "_", " ") <> closer))
      end
    end
  end

  defp person(nil), do: nil
  defp person(p), do: p["name"] || p["email"]

  # A card's open wait, beside its handoff: what it is held on.
  defp wait_fields(w) do
    by = person(w["opened_by"]) || "someone"
    kind = if w["kind"] == "agent", do: " (agent)", else: ""
    job = if w["job_id"], do: " · job ##{w["job_id"]}", else: ""

    field(
      "Waiting",
      bold(wait_line(w)) <>
        "  " <> dim("#{by}#{kind} · #{String.slice(to_string(w["opened_at"]), 0, 16)}#{job}")
    )
  end

  @doc """
  `slipdock timeline <id>` (#1131): each list the card sat in, its waits and
  its jobs, oldest first, with when, for how long and who. Times are UTC.
  """
  def timeline(%{"card" => id, "timeline" => t}) do
    IO.puts(bold("##{id} timeline") <> dim(" · since #{stamp(t["from"])} UTC"))

    timeline_lane("Lists", t["stays"], fn s ->
      {s["list"], timeline_how(s["how"]) <> if(s["unsure"], do: " (time uncertain)", else: "")}
    end)

    timeline_lane("Waits", t["waits"], fn w ->
      {"on #{w["on"]}", w["needs"] <> if(w["reason"], do: " (#{w["reason"]})", else: "")}
    end)

    timeline_lane("Jobs", t["jobs"], fn j ->
      {"##{j["id"]} #{j["status"]}", "#{j["pool"]} · #{j["kind"]}" <> on_runner(j["runner"])}
    end)
  end

  defp timeline_lane(_title, [], _row), do: :ok

  defp timeline_lane(title, spans, row) do
    IO.puts("\n" <> title)

    Enum.each(spans, fn span ->
      {what, note} = row.(span)
      long = span(span["seconds"]) <> if(span["open"], do: " so far", else: "")

      IO.puts(
        "  #{stamp(span["from"])}  #{String.pad_trailing(what, 16)} " <>
          String.pad_trailing(long, 10) <> " " <> dim(String.trim(note))
      )
    end)
  end

  defp timeline_how(%{"by" => by, "kind" => kind}) when is_binary(by), do: "#{kind} by #{by}"
  defp timeline_how(%{"backfilled" => true}), do: "recovered from the log"
  defp timeline_how(%{"kind" => kind}), do: kind
  defp timeline_how(_), do: ""

  defp on_runner(nil), do: ""
  defp on_runner(name), do: " · #{name}"

  @doc "`slipdock handoff <id>`: the current handoff, then every write before it."
  def handoff_history(%{"card" => id, "handoff" => current, "history" => history}) do
    case current do
      nil -> IO.puts("##{id} has no handoff.")
      h -> IO.puts(bold("##{id} left off: #{h["next_step"]}") <> "\n" <> (h["body"] || ""))
    end

    if history != [] do
      IO.puts("\nHistory")

      Enum.each(history, fn h ->
        what = if h["cleared"], do: dim("(cleared)"), else: h["next_step"]
        IO.puts("  #{what}  #{dim(handoff_by(h))}")
      end)
    end
  end

  # How the work ships, on a board that ships by pull request (#1655); a
  # security card's PR is to be neutral (#1794).
  defp put_labelled(_label, nil), do: :ok
  defp put_labelled(label, text), do: IO.puts(indent(label <> ": " <> text))

  defp shipping_block(sh) do
    neutral = if sh["neutral"], do: " · security: a neutral PR", else: ""
    IO.puts("")
    IO.puts(bold("Ships by pull request") <> dim("  branch #{sh["branch"]}#{neutral}"))
    IO.puts(indent(sh["instructions"]))
  end

  # A card's suggested handbook reading (#1265): what a pass reads before it
  # builds, and the gate it closes through.
  defp handbook_block(h) do
    IO.puts("")
    IO.puts(bold("Handbook") <> dim("  read before building; close with a Handbook: line"))

    case h["suggested"] || [] do
      [] -> IO.puts("  " <> dim("nothing in particular: see the index"))
      suggested -> Enum.each(suggested, &IO.puts("  " <> suggestion(&1)))
    end

    card_rules(h)
    IO.puts("  " <> dim("index: slipdock handbook #{h["board"]} (#{h["index_page"]})"))
  end

  # The rules for the card's lane paths (#1774), when it has some.
  defp card_rules(%{"rules" => rules} = h) when is_list(rules) do
    IO.puts(bold("Rules") <> dim("  for the card's paths; keep to them, cite them by id"))

    case rules do
      [] -> IO.puts("  " <> dim("none cover these paths"))
      rules -> Enum.each(rules, &rule_line/1)
    end

    if (h["rules_more"] || 0) > 0,
      do:
        IO.puts(
          "  " <>
            dim("… and #{h["rules_more"]} more: slipdock handbook #{h["board"]} --paths …")
        )
  end

  defp card_rules(_), do: :ok

  defp rule_line(r) do
    sev = if r["severity"] == "must", do: bold("must"), else: "should"
    IO.puts("  #{r["id"]} #{sev}  #{r["text"]}")

    where = if r["section"], do: "#{r["page"]} §#{section_leaf(r["section"])}", else: r["page"]
    IO.puts("      " <> dim("check: #{r["check"]} · #{where}"))
  end

  @doc "`slipdock handbook <board> --paths …`: the rules that apply to them."
  def handbook_for_paths(%{"handbook" => nil, "board" => b}),
    do:
      IO.puts(
        "#{b["code"]} keeps no handbook (`slipdock tools install-board handbook --board #{b["code"]}`)"
      )

  def handbook_for_paths(%{"handbook" => h}) do
    paths = h["paths"] || []

    # The pages whose `covers:` take the paths in (#1787): what a reconcile
    # reads. A server older than that sends none, and prints no block.
    if pages = h["pages"], do: covering_pages(pages)

    IO.puts(
      bold("Rules") <>
        dim("  #{h["board"]} · #{length(paths)} path#{if length(paths) == 1, do: "", else: "s"}")
    )

    case h["rules"] || [] do
      [] -> IO.puts("  " <> dim("none cover these paths"))
      rules -> Enum.each(rules, &rule_line/1)
    end
  end

  defp covering_pages(pages) do
    IO.puts(bold("Pages") <> dim("  whose covers: take these paths in"))
    if pages == [], do: IO.puts("  " <> dim("none"))
    Enum.each(pages, &covering_page/1)
    IO.puts("")
  end

  defp covering_page(p) do
    n = p["paths"] || 0
    plural = if n == 1, do: "", else: "s"

    IO.puts(
      "  #{p["code"]} #{p["title"]}  " <>
        dim("#{n} path#{plural} · slipdock page read #{p["code"]}")
    )
  end

  defp suggestion(s) do
    where =
      if s["section"],
        do: "slipdock page section #{s["page"]} \"#{s["section"]}\"",
        else: "slipdock page read #{s["page"]}"

    "#{s["page"]} #{s["title"]}#{if s["section"], do: " §" <> section_leaf(s["section"]), else: ""}  " <>
      dim("#{s["why"]} · #{where}")
  end

  defp section_leaf(path), do: path |> String.split("/") |> List.last()

  @doc "`slipdock handbook <card>`: the card's suggested reading, or that there is none."
  def handbook_for_card(%{"handbook" => %{} = h} = c) do
    IO.puts(bold("##{c["id"]} #{c["title"]}"))
    handbook_block(h)
  end

  def handbook_for_card(c),
    do:
      IO.puts(
        "##{c["id"]}: its board keeps no handbook (`slipdock tools install-board handbook --board B`)"
      )

  @doc "`slipdock handbook <board>`: the index and the decisions."
  def handbook(%{"handbook" => nil, "board" => b}),
    do:
      IO.puts(
        "#{b["code"]} keeps no handbook (`slipdock tools install-board handbook --board #{b["code"]}`)"
      )

  def handbook(%{"handbook" => h}) do
    IO.puts(bold("Handbook") <> dim("  #{h["board"]} · index #{h["index_page"]}"))

    Enum.each(h["index"], fn p ->
      IO.puts(
        "  #{p["code"]} #{p["title"]}" <>
          if(p["summary"], do: dim(" — " <> p["summary"]), else: "")
      )

      if p["read_when"], do: IO.puts("      " <> dim("read when: " <> p["read_when"]))
    end)

    if (h["more"] || 0) > 0,
      do: IO.puts("  " <> dim("… and #{h["more"]} more pages in the folder"))

    case h["decisions"] || [] do
      [] ->
        :ok

      decisions ->
        IO.puts(bold("Decisions"))
        Enum.each(decisions, &IO.puts("  #{&1["code"]} #{&1["title"]}"))
    end

    handbook_rules(h["rules"])
  end

  # How many rules the handbook has, and the items that don't parse (#1773).
  defp handbook_rules(%{"count" => count} = r) do
    problems = r["problems"] || []

    IO.puts(
      bold("Rules") <>
        dim("  #{count} (#{r["must"] || 0} must)") <>
        if(problems == [], do: "", else: dim(" · #{length(problems)} not read"))
    )

    Enum.each(problems, fn p ->
      IO.puts("  " <> red("#{p["page"]} line #{p["line"]}: #{p["problem"]}"))
      IO.puts("      " <> dim(p["item"]))
    end)
  end

  defp handbook_rules(_), do: :ok

  # Both ends of an incident (#1946): what caused it, and what it caused.
  defp incident_fields(c) do
    if text = incident_text(c), do: field("Incident", text)

    Enum.each(c["incidents"] || [], fn i ->
      missed = if i["missed_by"], do: " (missed by #{i["missed_by"]})", else: ""
      field("Incidents", "caused incident ##{i["id"]} #{i["title"]}#{missed}")
    end)
  end

  # "caused by #12 Title · missed by ci", from the card's own fields and,
  # where the server sent it, the cause's title.
  defp incident_text(c) do
    if c["caused_by"] || c["missed_by"], do: incident_line(c)
  end

  @doc """
  A card's lead time for `slipdock card` (#1954): how long, how it ended,
  its three longest phases and what its jobs spent (tokens only when the
  logs carried them). Nil when the card says nothing about it.
  """
  def lead_time_text(%{"seconds" => s} = lt) when is_integer(s) do
    top =
      (lt["phases"] || %{})
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(3)
      |> Enum.map_join(", ", fn {phase, secs} -> "#{phase} #{Ledger.duration(secs)}" end)

    "#{Ledger.duration(s)} (#{lt["ends"]})" <>
      if(top == "", do: "", else: ": #{top}") <> Ledger.spent(get_in(lt, ["cost", "total"]))
  end

  def lead_time_text(_), do: nil

  # Its lead time, and what its jobs spent beside it (#1954).
  # Where its latest deploy attempt failed, until one succeeds (#2820).
  defp deploy_failed_fields(c) do
    Enum.each(
      c["deploy_failed"] || [],
      &field("Deploy", String.replace_prefix(&1["text"], "Deploy ", ""))
    )
  end

  defp lead_time_fields(lt) do
    if text = lead_time_text(lt), do: field("Lead time", text)
    if r = rollup_text(lt), do: field("Subcards", r)
  end

  @doc """
  An epic's subcards rolled up beside its lead time (#1954): their lead
  times added up and what was spent on them and on the epic's own jobs.
  Nil on a card with no subcards.
  """
  def rollup_text(%{"rollup" => %{"subcards" => n, "seconds" => s} = r}) do
    "#{n} added up, #{Ledger.duration(s)}" <> Ledger.spent(get_in(r, ["cost", "total"]))
  end

  def rollup_text(_), do: nil

  defp incident_line(c) do
    cause =
      case {c["caused_by"], c["caused_by_card"]} do
        {nil, _} -> "cause not named"
        {id, %{"title" => title}} -> "caused by ##{id} #{title}"
        {id, _} -> "caused by ##{id}"
      end

    if m = c["missed_by"], do: cause <> " · missed by #{m}", else: cause
  end

  # Merged, awaiting release, or released, on a batched board (#2834).
  defp release_field(%{"text" => text}), do: field("Release", text)
  defp release_field(_release), do: :ok

  def card(c) do
    IO.puts(
      bold("##{c["id"]} #{c["title"]}") <> if(c["completed"], do: "  ✓ completed", else: "")
    )

    field(
      "Board/column",
      "board ##{c["board_id"]} · #{c["column"]} (column ##{c["column_id"]}, position #{c["position"]})"
    )

    if stands = standing(c), do: where_it_stands(stands)
    if w = c["wait"], do: wait_fields(w)
    if s = c["state"], do: field("State", s)
    if d = c["driver"], do: field("Driver", d)
    origin_field(c)
    if a = age_text(c), do: field("In list", a)
    # Where it has shipped, and the deploy it says caused it (#1134).
    Enum.each(
      c["shipped"] || [],
      &field("Shipped", String.replace_prefix(&1["text"], "Shipped ", ""))
    )

    deploy_failed_fields(c)

    # Merged, and no deploy names it after the board's minutes (#2819).
    not_shipped_field(c["not_shipped"])
    if i = c["incident_of"], do: field("Incident of", "deploy ##{i}")
    release_field(c["release"])
    lead_time_fields(c["lead_time"])

    field("Priority", c["priority"])

    field(
      "Flags",
      if(c["flags"] == [], do: "-", else: flags_text(c["flags"], c["flag_attention"]))
    )

    field("Tags", if(c["tags"] == [], do: "-", else: Enum.join(c["tags"], ", ")))
    # What kind of change it is (#1951), when it has a profile.
    profile_field(c)
    field("Start", c["start_date"] || "-")
    field("Due", c["due_date"] || "-")
    field("% complete", if(p = c["percent_complete"], do: "#{p}%", else: "-"))
    field("Time", time_text(c, true) || "-")
    field("Assignee", assignees(c, &"#{&1["name"]} <#{&1["email"]}>") || "-")
    loop_field(c["loop"])
    field("Cover", c["color"] || "-")
    if borders = borders_line(c), do: field("Borders", borders)
    field("Blocked by", dependency_list(c["blocked_by"], c["board_id"]))
    field("Blocks", dependency_list(c["blocks"], c["board_id"]))
    incident_fields(c)

    if not Enum.member?([nil, []], c["links"]) do
      field(
        "Links",
        Enum.map_join(c["links"], "; ", fn l ->
          arrow = if l["direction"] == "out", do: "→", else: "←"

          "#{l["kind"]} #{arrow} ##{l["card"]["id"]} #{l["card"]["title"]}#{if l["card"]["board"], do: " (#{l["card"]["board"]})", else: ""} [link ##{l["id"]}]"
        end)
      )
    end

    if not Enum.member?([nil, []], c["urls"]) do
      field(
        "Web links",
        Enum.map_join(c["urls"], "; ", fn u ->
          "#{u["label"]} #{u["url"]} (added #{String.slice(to_string(u["added_at"]), 0, 10)}) [url ##{u["id"]}]"
        end)
      )
    end

    if not Enum.member?([nil, []], c["attachments"]) do
      field("Files", Enum.map_join(c["attachments"], "; ", &attachment_line/1))
    end

    if not Enum.member?([nil, "day"], c["date_precision"]),
      do: field("Precision", c["date_precision"])

    if c["stated_health"], do: field("Reported", c["stated_health"])
    if (c["votes"] || 0) > 0, do: field("Votes", c["votes"])

    if not Enum.member?([nil, %{}], c["fields"]) do
      field("Fields", Enum.map_join(c["fields"], " · ", fn {k, v} -> "#{k}=#{v}" end))
    end

    if not Enum.member?([nil, %{}], c["scores"]) do
      field("Scores", Enum.map_join(c["scores"], " · ", fn {k, v} -> "#{k}=#{score(v)}" end))
    end

    if not Enum.member?([nil, []], c["docs"]) do
      field(
        "Docs",
        Enum.map_join(c["docs"], "; ", fn d ->
          "#{if d["pinned"], do: "★ ", else: ""}#{d["code"]} #{d["title"]}"
        end)
      )
    end

    if s = c["stand_in_for"] do
      field("Stand-in", "for ##{s["id"]}" <> stand_in_where(s) <> " · #{s["status"]}")
    end

    if z = c["snooze"] do
      note = if z["note"], do: " — #{z["note"]}", else: ""
      field("Snoozed", "until #{local_at(z["until"])}#{note}")
    end

    cond do
      rec = c["recurrence"] -> field("Repeats", recurrence_text(rec))
      c["series_id"] -> field("Repeats", "an earlier instance of series ##{c["series_id"]}")
      true -> :ok
    end

    copied_from_field(c["copied_from"])

    if sb = c["sub_board"] do
      lists = Enum.map_join(sb["columns"], ", ", &"#{&1["name"]} (#{&1["cards"]})")
      field("Subcards", "board ##{sb["id"]} · #{sb["completed"]}/#{sb["total"]} done · #{lists}")
    end

    # What in its tree waits on you (#2095), and on others.
    waiting_line(c, "")

    if r = c["rollup"] do
      field(
        "Rolled up",
        "#{r["done"]}/#{r["total"]} leaves done · #{r["health"]} · #{rollup_cell(r)}"
      )
    end

    findings_field(c)
    if c["archived_at"], do: field("Archived", c["archived_at"])
    field("Created", by_line(c["inserted_at"], c["created_by"]))
    field("Updated", by_line(c["updated_at"], c["updated_by"]))

    if not Enum.member?([nil, ""], c["description"]) do
      IO.puts("")
      IO.puts(bold("Description"))
      IO.puts(indent(c["description"]))
    end

    if not Enum.member?([nil, ""], c["bar"]) do
      IO.puts("")
      IO.puts(bold("Bar") <> dim(if c["bar_locked_at"], do: "  locked", else: "  not locked yet"))
      IO.puts(indent(c["bar"]))
    end

    if not Enum.member?([nil, []], c["paths"]) do
      IO.puts("")
      IO.puts(bold("Paths"))
      c["paths"] |> paths_text(c["paths_shared"], c["paths_broad"]) |> indent() |> IO.puts()
      broad_line(c["paths_broad"], c["paths_broad_reason"])
      lane_overlap_line(c["lane_overlap"])
    end

    if state = c["verify_state"] do
      IO.puts("")
      rejected = if n = c["verify_rejections"], do: dim("  · rejected #{n}×"), else: ""
      IO.puts(bold("Verification") <> "  " <> verify_line(state, c) <> rejected)
      if note = c["verify_note"], do: IO.puts(indent(note))
      if sha = c["merge_sha"], do: IO.puts(indent("merged as " <> sha))

      put_verify_checks(state, c["verify_checks"])
    end

    if Enum.any?(
         ~w(evidence evidence_commit evidence_branch evidence_tests evidence_suite evidence_pr evidence_no_code),
         &c[&1]
       ) do
      IO.puts("")
      at = if s = c["evidence_commit"], do: "  at #{s}", else: ""
      on = if b = c["evidence_branch"], do: " on #{b}", else: ""
      IO.puts(bold("Evidence") <> dim(at <> on))
      if c["evidence"], do: IO.puts(indent(c["evidence"]))
      if pr = c["evidence_pr"], do: IO.puts(indent("pull request: " <> pr))
      put_labelled("no code", c["evidence_no_code"])
      if s = c["evidence_suite"], do: IO.puts(indent("suite: " <> suite_text(s)))
      for t <- c["evidence_tests"] || [], do: IO.puts(indent("test: " <> t))
    end

    # How the work ships, on a board that ships by pull request (#1655).
    if sh = c["shipping"], do: shipping_block(sh)

    if h = c["handbook"], do: handbook_block(h)

    if c["checklist"]["total"] > 0 do
      IO.puts("")
      IO.puts(bold("Checklist") <> dim("  #{c["checklist"]["done"]}/#{c["checklist"]["total"]}"))

      Enum.each(c["checklist"]["items"], fn i ->
        IO.puts(
          "  [#{if i["done"], do: "x", else: " "}] #{i["text"]}  " <> dim("(item ##{i["id"]})")
        )
      end)
    end

    if c["comments"] != [] do
      IO.puts("")
      IO.puts(bold("Comments"))

      Enum.each(c["comments"], fn m ->
        IO.puts("  " <> dim("#{m["inserted_at"]}#{comment_author(m)} (comment ##{m["id"]})"))
        IO.puts(indent(m["body"], "    "))
      end)
    end
  end

  # Who wrote it; nothing for a comment from before authors were kept, or a
  # server that does not send them.
  defp comment_author(%{"author" => %{"name" => name}}) when is_binary(name), do: " #{name}"
  defp comment_author(_), do: ""

  defp score(nil), do: "-"
  defp score(v) when is_float(v), do: Float.round(v, 2)
  defp score(v), do: v

  def fields(nil), do: IO.puts(dim("no fields"))
  def fields([]), do: IO.puts(dim("no fields"))

  def fields(fields) do
    table(
      ["ID", "NAME", "KEY", "KIND", "SUM", "DETAILS"],
      Enum.map(fields, fn f ->
        [
          to_string(f["id"]),
          f["name"],
          "{#{f["key"]}}",
          f["kind"],
          if(f["sum"], do: "yes", else: ""),
          field_details(f)
        ]
      end)
    )
  end

  @doc "One attached file: name, size, and the id `detach` takes."
  def attachment_line(a) do
    off = if a["hide_on_card"], do: " (not on the card front)", else: ""

    off =
      off <>
        case a["transcript_status"] do
          "running" -> " (transcribing)"
          "done" -> " (transcribed)"
          "failed" -> " (transcription failed)"
          _ -> ""
        end

    off =
      off <>
        case a["text_status"] do
          "done" -> " (text read)"
          "failed" -> " (text couldn't be read)"
          _ -> ""
        end

    "#{a["filename"]} (#{a["content_type"]}, #{size(a["size"])}) #{a["url"]}#{off} [attachment ##{a["id"]}]"
  end

  defp size(n) when is_integer(n) and n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp size(n) when is_integer(n) and n >= 1024, do: "#{div(n, 1024)} KB"
  defp size(n), do: "#{n} B"

  def field_line(f), do: "##{f["id"]} #{f["name"]} {#{f["key"]}} (#{f["kind"]})"

  defp field_details(%{"kind" => "select", "options" => options}),
    do:
      Enum.map_join(
        options,
        ", ",
        &"#{&1["label"]}#{if &1["weight"], do: "=#{&1["weight"]}", else: ""}"
      )

  defp field_details(%{"kind" => "formula", "config" => %{"expression" => e}}), do: e
  defp field_details(%{"kind" => "formula"}), do: "weighted"
  defp field_details(%{"kind" => "rating", "config" => c}), do: "1–#{c["max"] || 5}"

  defp field_details(%{"config" => c}) when is_map(c) do
    [c["min"] && "min #{c["min"]}", c["max"] && "max #{c["max"]}", c["unit"]]
    |> Enum.reject(&Enum.member?([nil, false], &1))
    |> Enum.join(" ")
  end

  defp field_details(_), do: ""

  def milestones([]), do: IO.puts(dim("no milestones"))

  def milestones(milestones) do
    table(
      ["ID", "DATE", "NAME", "COLOUR"],
      Enum.map(milestones, &[to_string(&1["id"]), &1["date"], &1["name"], &1["color"] || ""])
    )
  end

  def views([]), do: IO.puts(dim("no saved views"))

  def views(views) do
    rows =
      Enum.map(views, fn v ->
        c = v["config"]

        [
          to_string(v["id"]),
          v["name"],
          "#{c["rows"]} x #{c["cols"]}",
          "#{c["sort"]} #{if c["dir"] == "desc", do: "↓", else: "↑"}",
          v["url"]
        ]
      end)

    table(["ID", "NAME", "AXES (ROWS x COLS)", "SORT", "URL"], rows)
  end

  def favourites([]),
    do: IO.puts(dim("nothing favourited — try: slipdock fav list <board> \"In Progress\""))

  def favourites(favourites) do
    rows =
      Enum.map(favourites, fn f ->
        [
          f["kind"],
          f["name"],
          (f["board"] && f["board"]["code"]) || "",
          to_string(f["resource_id"]),
          f["url"]
        ]
      end)

    table(["KIND", "NAME", "BOARD", "ID", "URL"], rows)
  end

  def hotkeys([]),
    do:
      IO.puts(
        dim("no hotkeys — try: slipdock hotkey <board> 1, then Ctrl+Shift+1 in the web app")
      )

  def hotkeys(hotkeys) do
    rows =
      Enum.map(hotkeys, fn
        %{"vault" => _} = h ->
          ["Ctrl+Shift+#{h["digit"]}", "Your wiki", "wiki", ""]

        %{"wiki" => _} = h ->
          ["Ctrl+Shift+#{h["digit"]}", "Your wiki", "wiki", ""]

        h ->
          [
            "Ctrl+Shift+#{h["digit"]}",
            h["board"]["name"],
            h["board"]["code"] || "",
            to_string(h["board"]["id"])
          ]
      end)

    table(["KEY", "OPENS", "CODE", "ID"], rows)
  end

  def header_links(%{"header_links" => []} = r),
    do:
      IO.puts(
        dim("nothing pinned — try: slipdock header add board <board> --icon star") <>
          icons_line(r)
      )

  def header_links(%{"header_links" => links} = r) do
    rows =
      Enum.map(links, fn
        %{"vault" => _} = l ->
          [to_string(l["id"]), l["icon"], "Your wiki", "wiki", ""]

        %{"wiki" => _} = l ->
          [to_string(l["id"]), l["icon"], "Your wiki", "wiki", ""]

        %{"board" => b} = l ->
          [to_string(l["id"]), l["icon"], b["name"], b["code"] || "", to_string(b["id"])]
      end)

    table(["ID", "ICON", "OPENS", "CODE", "TARGET"], rows)
    IO.puts(icons_line(r))
  end

  defp icons_line(%{"icons" => [_ | _] = icons}),
    do: "\n" <> dim("icons: " <> Enum.join(icons, " "))

  defp icons_line(_), do: ""

  def automations([]), do: IO.puts(dim("no automations"))

  def automations(rules) do
    rows =
      Enum.map(rules, fn r ->
        [
          to_string(r["id"]),
          if(r["enabled"], do: "on", else: dim("off")),
          r["name"],
          r["trigger"] <> if(r["scheduled"], do: " ⏱", else: ""),
          runs(r),
          fit(r["summary"] || "", 60)
        ]
      end)

    table(["ID", "STATE", "NAME", "TRIGGER", "RUNS", "WHAT IT DOES"], rows)
  end

  defp runs(%{"run_count" => 0}), do: dim("never")
  defp runs(%{"run_count" => n, "last_error" => nil}), do: "#{n}"
  defp runs(%{"run_count" => n}), do: "#{n} ⚠"

  def automation(r) do
    IO.puts(bold("##{r["id"]} #{r["name"]}") <> if(r["enabled"], do: "", else: dim("  (off)")))
    field("What it does", r["summary"])
    if r["source"], do: field("Described as", "“#{r["source"]}”")

    field(
      "Trigger",
      r["trigger"] <> if(r["scheduled"], do: " (checked on a timer)", else: " (on the event)")
    )

    field(
      "Scope",
      if(r["scope"] == "tree", do: "this board and its subcards", else: "this board")
    )

    field(
      "Runs",
      "#{r["run_count"]}#{if r["last_run_at"], do: ", last #{r["last_run_at"]}", else: ""}"
    )

    if r["last_error"], do: field("Last error", r["last_error"])
    IO.puts("")
    IO.puts(dim("spec:"))
    IO.puts(indent(pretty(r["spec"])))
  end

  @doc """
  Semantic search results: one block per card, with the snippets that
  matched beneath it.

  Not a table. A row of columns is right when every result is the same shape;
  here the interesting part is a paragraph of someone's writing, and the
  point of showing it is that the reader can see *why* the card came back
  rather than taking the ranking on trust. `--full` prints the whole matching
  text instead of a snippet, for when the answer itself is in the comment.
  """
  def search_results(%{"results" => []} = r, _opts) do
    IO.puts(dim("nothing close enough to #{inspect(r["query"])}"))
  end

  def search_results(%{"results" => results}, opts) do
    # `search` passes `full: o[:full]`, which is nil without --full.
    full? = opts[:full] == true

    Enum.each(results, fn result ->
      IO.puts(bold(result_heading(result)) <> "  " <> dim(strength(result["score"])))
      IO.puts(dim("   " <> result_where(result)))

      result["matches"]
      |> Enum.take(if full?, do: 99, else: 2)
      |> Enum.each(fn m ->
        label = if (m["section"] || "") != "", do: m["section"], else: kind_label(m["kind"])
        IO.puts(dim("   [#{label}] ") <> snippet(m, full?))
        # Where it is: the comment, update or transcript part, not just the card.
        if full? and m["url"], do: IO.puts(dim("     " <> m["url"]))
      end)

      IO.puts("")
    end)

    pages = Enum.count(results, &(&1["kind"] == "page"))
    files = Enum.count(results, &(&1["kind"] == "file"))
    cards = length(results) - pages - files

    IO.puts(
      dim(
        [
          cards > 0 && "#{cards} card#{if cards == 1, do: "", else: "s"}",
          pages > 0 && "#{pages} page#{if pages == 1, do: "", else: "s"}",
          files > 0 && "#{files} file#{if files == 1, do: "", else: "s"}"
        ]
        |> Enum.filter(& &1)
        |> Enum.join(", ")
        |> case do
          "" -> "nothing"
          text -> text
        end
      )
    )
  end

  defp result_heading(%{"kind" => "page", "page" => page}), do: "#{page["code"]} #{page["title"]}"
  defp result_heading(%{"kind" => "file", "file" => file}), do: file["name"]
  defp result_heading(%{"card" => card}), do: "##{card["id"]} #{card["title"]}"

  defp result_where(%{"kind" => "page", "page" => page}) do
    "#{page["board"]["name"]} › wiki" <>
      if(page["summary"], do: " · #{page["summary"]}", else: "")
  end

  defp result_where(%{"kind" => "file", "file" => file}),
    do: "#{file["board"]["name"]} › wiki · file"

  defp result_where(%{"card" => card}) do
    "#{card["board"]["name"]}" <>
      if(card["column"], do: " › #{card["column"]["name"]}", else: "") <> facets(card)
  end

  @doc "The assistant's answer, with what it searched for and what it read."
  def answer(%{"answer" => answer} = r) do
    if r["searches"] != [] do
      IO.puts(dim("searched: " <> Enum.map_join(r["searches"], "; ", &inspect/1)))
      IO.puts("")
    end

    IO.puts(answer)

    if r["sources"] != [] do
      IO.puts("")
      IO.puts(dim("what it looked at:"))

      Enum.each(r["sources"], fn s ->
        handle = if s["kind"] == "page", do: s["code"] || "page", else: "##{s["id"]}"
        IO.puts(dim("  #{handle} ") <> s["title"] <> dim("  #{s["board"]}"))
      end)
    end
  end

  @doc """
  The caller's saved queries. Grouped by mode, because a phrase you search
  for and a question you ask a model are different kinds of thing even when
  the words match, and the id is shown so `unsave --id N` has something to
  take hold of.
  """
  def saved_queries(%{"saved" => []}), do: IO.puts(dim("nothing saved yet"))

  def saved_queries(%{"saved" => saved}) do
    for {mode, label} <- [{"search", "SEARCHES"}, {"ask", "QUESTIONS"}],
        rows = Enum.filter(saved, &(&1["mode"] == mode)),
        rows != [] do
      IO.puts(bold(label))
      Enum.each(rows, fn q -> IO.puts("  " <> dim(to_string(q["id"])) <> "  " <> q["text"]) end)
      IO.puts("")
    end
  end

  @doc "What the semantic index holds right now."
  def search_status(r) do
    field("Available", if(r["available"], do: "yes", else: "no — run mix slipdock.reindex"))
    field("Model", r["model"] <> if(r["dimensions"], do: " (#{r["dimensions"]}d)", else: ""))
    field("Chunks", r["chunks"])
    field("Cards", r["cards"])
    if r["pages"], do: field("Pages", r["pages"])
    if r["queued"] > 0, do: field("Queued", r["queued"])
  end

  # A cosine similarity means nothing to a reader; three bands say the part
  # that matters, which is how much to trust the hit.
  defp strength(score) when is_number(score) and score >= 0.55, do: "strong"
  defp strength(score) when is_number(score) and score >= 0.38, do: "good"
  defp strength(_), do: "loose"

  defp kind_label("status_update"), do: "status"
  defp kind_label("page_section"), do: "page section"
  defp kind_label(kind), do: kind

  defp facets(card) do
    [
      card["completed"] && "done",
      not Enum.member?([nil, "none"], card["priority"]) && "priority #{card["priority"]}",
      card["due_date"] && "due #{card["due_date"]}",
      card["archived"] && "archived"
    ]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> ""
      parts -> " · " <> Enum.join(parts, " · ")
    end
  end

  # A chunk opens by naming where it lives, which the block above has already
  # said. Drop that preamble — for a card it is the board and title lines, for
  # a comment or update the single "Comment on card X" line — and show what is
  # left, which is what someone actually wrote.
  @snippet_cap 180
  defp snippet(%{"kind" => kind, "text" => text}, full?) when kind in ["page", "page_section"] do
    text
    |> String.split("\n")
    |> Enum.reject(
      &(String.starts_with?(&1, "Board: ") or String.starts_with?(&1, "Page: ") or
          String.starts_with?(&1, "Wiki page "))
    )
    |> Enum.join(" ")
    |> render_snippet(full?)
  end

  defp snippet(%{"kind" => "card", "text" => text}, full?) do
    text
    |> String.split("\n")
    |> Enum.reject(&(String.starts_with?(&1, "Board: ") or String.starts_with?(&1, "Card: ")))
    |> Enum.join("\n")
    |> render_snippet(full?)
  end

  defp snippet(%{"text" => text}, full?) do
    case String.split(to_string(text), "\n", parts: 2) do
      [_preamble, rest] -> rest
      [only] -> only
    end
    |> render_snippet(full?)
  end

  defp render_snippet(body, full?) do
    if full? do
      String.trim(body)
    else
      one_line = body |> String.replace(~r/\s+/u, " ") |> String.trim()

      if String.length(one_line) > @snippet_cap,
        do: String.slice(one_line, 0, @snippet_cap) <> "…",
        else: one_line
    end
  end

  ## Wiki --------------------------------------------------------------------

  def pages([]), do: IO.puts(dim("no pages"))

  def pages(pages) do
    rows =
      Enum.map(pages, fn p ->
        [
          p["code"] || "",
          p["title"],
          state(p),
          page_facets(p),
          p["summary"] || "",
          stamp(p["updated_at"])
        ]
      end)

    table(["CODE", "TITLE", "STATE", "FACETS", "SUMMARY", "UPDATED"], rows)
  end

  # The card facets a page carries, as one line — the same vocabulary a card's
  # line uses, so a doc reads like the work beside it.
  defp page_facets(p) do
    [
      not Enum.member?([nil, "none"], p["priority"]) && "prio:#{p["priority"]}",
      (p["flags"] || []) != [] && flags(p["flags"]),
      (p["tags"] || []) != [] && "tags:" <> Enum.join(p["tags"], ","),
      p["assignee"] && "@#{p["assignee"]["name"] || p["assignee"]["email"]}",
      p["start_date"] && "start:#{p["start_date"]}",
      p["due_date"] && "due:#{p["due_date"]}",
      p["percent_complete"] && "#{p["percent_complete"]}%",
      p["completed"] && "✓ written",
      p["color"] && "cover:#{p["color"]}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("  ")
  end

  defp state(p) do
    [
      if(p["archived_at"], do: "archived"),
      if(p["status"] == "draft", do: "draft"),
      if(p["template"], do: "template")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc "The page tree, one line per page, nesting shown by indent."
  def page_tree(nodes, depth \\ 0) do
    if nodes == [] and depth == 0 do
      IO.puts(dim("no pages"))
    else
      Enum.each(nodes, fn p ->
        IO.puts(
          String.duplicate("  ", depth) <>
            p["title"] <>
            "  " <>
            dim("#{p["code"]} · #{p["slug"]}#{if p["status"] == "draft", do: " · draft"}")
        )

        page_tree(p["children"] || [], depth + 1)
      end)
    end
  end

  @doc """
  A board's filing: folders, nested, with the pages in each and then the
  pages filed nowhere.
  """
  def folders(folders, pages, short? \\ false) do
    if folders == [] and pages == [] do
      IO.puts(dim("nothing written"))
    else
      folder_nodes(folders, 0, short?)
      page_tree_lines(pages, 0)
    end
  end

  @doc "What to call a folder: its short name if asked for and it has one, else its title."
  def folder_name(%{"short_name" => short}, true) when is_binary(short), do: short
  def folder_name(f, _short?), do: f["title"] || f["name"]

  defp folder_nodes(nodes, depth, short?) do
    Enum.each(nodes, fn f ->
      IO.puts(
        String.duplicate("  ", depth) <>
          bold(folder_name(f, short?)) <> "/  " <> dim(f["slug"]) <> also_in(f)
      )

      folder_nodes(f["folders"] || [], depth + 1, short?)
      page_tree_lines(f["pages"] || [], depth + 1)
    end)
  end

  defp page_tree_lines(nodes, depth) do
    Enum.each(nodes, fn p ->
      IO.puts(
        String.duplicate("  ", depth) <>
          p["title"] <>
          "  " <>
          dim("#{p["code"]} · #{p["slug"]}#{if p["status"] == "draft", do: " · draft"}")
      )

      page_tree_lines(p["children"] || [], depth + 1)
    end)
  end

  @doc """
  One level of the wiki tree: folders with how many pages are beneath them,
  pages with their code, files with their type, and how many rows each one
  would open onto.
  """
  def tree_rows([]), do: IO.puts(dim("nothing here"))

  def tree_rows(rows) do
    Enum.each(rows, fn row ->
      under = if (row["count"] || 0) > 0, do: dim("  ▸ #{row["count"]}"), else: ""

      line =
        case row["kind"] do
          "folder" ->
            bold(row["title"]) <> "/  " <> dim("#{row["pages"]} page(s) · folder:#{row["id"]}")

          "file" ->
            row["title"] <> "  " <> dim("#{row["content_type"]} · file #{row["id"]}")

          _ ->
            marks =
              [
                row["draft"] && "draft",
                row["template"] && "template",
                row["archived"] && "archived"
              ]
              |> Enum.filter(& &1)
              |> Enum.map_join("", &(" · " <> &1))

            row["title"] <> "  " <> dim("#{row["code"]} · page:#{row["id"]}#{marks}")
        end

      IO.puts(line <> under)
    end)
  end

  @doc "A folder's organise (#791): where each item goes, then what happened."
  def organise(%{"plan" => plan} = r) do
    Enum.each(plan, fn e ->
      IO.puts("#{e["key"]}  #{e["title"]}  /#{e["from"]} → /#{e["to"]}")
    end)

    cond do
      r["dry_run"] && plan == [] ->
        IO.puts("nothing here would move")

      r["dry_run"] ->
        IO.puts("dry run: #{length(plan)} item(s) would move — nothing was changed")

      true ->
        IO.puts("moved #{r["moved"]} item(s), made #{r["folders_made"]} folder(s)")

        Enum.each(r["skipped"] || [], fn s ->
          IO.puts("left where it was: #{s["title"]} (#{s["reason"]})")
        end)
    end
  end

  @doc "One folder, after it has been made, renamed or moved, and where else it is filed."
  def folder(f) do
    dress = Enum.reject([f["icon"], f["color"]], &Enum.member?([nil, ""], &1))
    dress = if dress == [], do: "", else: " · " <> Enum.join(dress, " ")
    IO.puts(bold(f["path"]) <> "  " <> dim("#{f["slug"]} · id #{f["id"]}#{dress}"))

    for place <- f["also_in"] || [],
        do: IO.puts("  also in " <> place["path"] <> "  " <> dim(place["board"] || ""))
  end

  # A folder also filed elsewhere (#808), on its line in a listing.
  defp also_in(%{"also_in" => [_ | _] = places}),
    do: dim("  ↪ also in " <> Enum.map_join(places, ", ", & &1["path"]))

  defp also_in(_folder), do: ""

  @doc "Who a page or folder is shared with (#820)."
  def grants([]), do: IO.puts(dim("not shared with anyone"))

  def grants(grants) do
    Enum.each(grants, fn g ->
      who =
        cond do
          g["group"] -> "group " <> g["group"]["name"]
          g["user"] -> g["user"]["email"]
          true -> "?"
        end

      IO.puts(String.pad_trailing(grant_level(g), 12) <> who)
    end)
  end

  def grant_level(%{"level" => "write"}), do: "can edit"
  def grant_level(%{"level" => "comment"}), do: "can comment"
  def grant_level(_), do: "read only"

  @doc "What other people have shared with you, by owner (#820)."
  def shared([]), do: IO.puts(dim("nothing is shared with you"))

  def shared(groups) do
    Enum.each(groups, fn %{"owner" => owner, "items" => items} ->
      IO.puts(bold("from " <> (owner["name"] || owner["email"])))
      Enum.each(items, &shared_item(&1, 1))
    end)
  end

  defp shared_item(%{"kind" => "folder"} = f, depth) do
    IO.puts(share_indent(depth) <> f["name"] <> "/  " <> dim(level(f)))
    Enum.each(f["folders"] || [], &shared_item(&1, depth + 1))
    Enum.each(f["pages"] || [], &shared_item(&1, depth + 1))
    Enum.each(f["files"] || [], &IO.puts(share_indent(depth + 1) <> &1["name"]))
  end

  defp shared_item(%{"kind" => "page"} = p, depth),
    do:
      IO.puts(
        share_indent(depth) <>
          String.pad_trailing(p["code"] || "", 9) <> p["title"] <> "  " <> dim(level(p))
      )

  defp level(item), do: grant_level(item)

  defp share_indent(depth), do: String.duplicate("  ", depth)

  @doc "Every board's wiki at once: boards as the top level, folders inside."
  def wiki([]), do: IO.puts(dim("no boards"))

  def wiki(boards) do
    Enum.each(boards, fn b ->
      IO.puts("")
      IO.puts(bold(b["name"]) <> "  " <> dim(b["code"] || ""))
      folder_nodes(b["folders"] || [], 1, false)
      page_tree_lines(b["pages"] || [], 1)

      if (b["folders"] || []) == [] and (b["pages"] || []) == [],
        do: IO.puts("  " <> dim("nothing written"))
    end)
  end

  @doc "A page in full, as its Markdown source with a header above it."
  def page(p) do
    IO.puts(bold(p["title"]) <> "  " <> dim("#{p["code"]} · #{p["slug"]}"))
    facets = page_facets(p)
    if facets != "", do: IO.puts(dim(facets))

    IO.puts(
      dim(
        "board #{p["board_id"]} · #{p["status"]}#{if p["archived_at"], do: " · archived"}#{page_stamps(p)} · hash #{p["content_hash"] || "-"}"
      )
    )

    if p["summary"], do: IO.puts(dim(p["summary"]))
    IO.puts("")
    IO.puts(p["body"] || "")
  end

  # When it was created and last updated (#790), each left out when the
  # server did not say (an older one sends no created stamp).
  defp page_stamps(p) do
    [{"created", p["inserted_at"]}, {"updated", p["updated_at"]}]
    |> Enum.reject(fn {_label, at} -> is_nil(at) end)
    |> Enum.map_join(fn {label, at} -> " · #{label} #{stamp(at)}" end)
  end

  def revisions([]), do: IO.puts(dim("no history"))

  def revisions(revisions) do
    rows =
      Enum.map(revisions, fn r ->
        [
          to_string(r["id"]),
          stamp(r["at"]),
          author(r),
          [r["via"], r["agent"]] |> Enum.reject(&is_nil/1) |> Enum.join(" · "),
          to_string(r["byte_size"]),
          r["summary"] || ""
        ]
      end)

    table(["REV", "WHEN", "WHO", "HOW", "BYTES", "WHY"], rows)
  end

  defp author(%{"author" => %{"name" => name}}) when is_binary(name) and name != "", do: name
  defp author(%{"author" => %{"email" => email}}), do: email
  defp author(_), do: ""

  @doc "A diff as the API returns it: hunks of equal, deleted and inserted lines."
  def diff([]), do: IO.puts(dim("no change"))

  def diff(hunks) do
    Enum.each(hunks, fn %{"op" => op, "lines" => lines} ->
      Enum.each(lines, fn line ->
        case op do
          "ins" -> IO.puts(green("+ " <> line))
          "del" -> IO.puts(red("- " <> line))
          _ -> IO.puts(dim("  " <> line))
        end
      end)
    end)
  end

  def sections([]), do: IO.puts(dim("no headings"))

  def sections(sections) do
    Enum.each(sections, fn s ->
      IO.puts(String.duplicate("  ", (s["level"] || 1) - 1) <> s["path"])
    end)
  end

  @doc "What a page points at, what points at it, and what it wanted but did not find."
  def page_links(%{"outgoing" => out, "incoming" => incoming, "unresolved" => unresolved}) do
    section("Points at", out, fn l ->
      target = l["target"] || %{}
      pin = if l["pinned"], do: " " <> bold("pinned"), else: ""

      "#{l["kind"]}  #{target["title"] || target["name"] || l["raw"]}  " <>
        dim("#{target["url"] || ""}#{if l["count"] > 1, do: " ×#{l["count"]}"}") <> pin
    end)

    section("Linked from", incoming, fn l ->
      "#{l["page"]["title"]}  " <> dim("#{l["page"]["code"]} · #{l["page"]["url"]}")
    end)

    section("Wanted (written, never created)", unresolved, fn l ->
      "#{l["raw"]}" <> dim(if l["count"] > 1, do: " ×#{l["count"]}", else: "")
    end)
  end

  defp section(_title, [], _fun), do: :ok

  defp section(title, rows, fun) do
    IO.puts(bold(title))
    Enum.each(rows, fn row -> IO.puts("  " <> fun.(row)) end)
    IO.puts("")
  end

  def wanted([]), do: IO.puts(dim("nothing wanted — every link lands somewhere"))

  def wanted(wanted) do
    rows =
      Enum.map(wanted, fn w ->
        [
          w["title"],
          to_string(w["count"]),
          Enum.map_join(w["from"] || [], ", ", & &1["title"])
        ]
      end)

    table(["WANTED PAGE", "LINKS", "LINKED FROM"], rows)
  end

  def resolved(%{"found" => true, "page" => p, "write_as" => write_as}) do
    IO.puts("#{p["title"]}  " <> dim("#{p["code"]} · #{p["url"]}"))
    IO.puts("write it as " <> bold(write_as))
  end

  def resolved(%{"found" => false, "write_as" => write_as} = r) do
    IO.puts(dim(r["note"] || "no page answers to that yet"))
    IO.puts("write it as " <> bold(write_as) <> dim("  (it becomes a wanted page)"))

    case r["near"] || [] do
      [] ->
        :ok

      near ->
        IO.puts("")
        IO.puts(bold("Nearest:"))
        Enum.each(near, fn p -> IO.puts("  #{p["title"]}  " <> dim(p["code"])) end)
    end
  end

  @doc "The grammar a ```slipdock block is written in, straight from the server."
  def query_help(v) do
    IO.puts(bold("Views") <> "  " <> Enum.join(v["views"], " · "))
    IO.puts(bold("Settings") <> "  " <> Enum.join(v["settings"], " · "))
    IO.puts(bold("Filter fields") <> "  " <> Enum.join(v["fields"], " · "))
    IO.puts("")
    IO.puts(bold("Operators"))

    table(
      ["WRITE", "MEANS"],
      Enum.map(v["operators"], &[&1["write"], &1["means"]])
    )

    IO.puts("")
    IO.puts(bold("Values") <> "  " <> Enum.join(v["values"], " · "))
    IO.puts("")
    IO.puts(bold("Example"))
    IO.puts(indent(v["example"]))
    IO.puts(dim(v["note"]))
  end

  @doc "What a block would answer, without writing it anywhere."
  def query_answer(%{"ok" => false, "error" => error}) do
    IO.puts(:stderr, "that block would not answer: " <> error)
    System.halt(1)
  end

  def query_answer(%{"ok" => true, "answer" => answer}), do: query_result(answer)

  defp query_result(%{"kind" => "count", "count" => count}),
    do: IO.puts("#{count} card#{if count == 1, do: "", else: "s"}")

  defp query_result(%{"kind" => "progress"} = a),
    do:
      IO.puts(
        "#{a["done"]} of #{a["total"]} done (#{a["percent"]}%)#{if a["label"], do: " — " <> a["label"], else: ""}"
      )

  defp query_result(%{"kind" => "list", "cards" => cards}) do
    if cards == [],
      do: IO.puts(dim("no cards match")),
      else: Enum.each(cards, &IO.puts("##{&1["id"]}  #{&1["title"]}"))
  end

  defp query_result(%{"kind" => "groups", "groups" => groups}) do
    Enum.each(groups, fn group ->
      IO.puts(bold(group["label"] || "") <> dim("  #{length(group["cards"])}"))
      Enum.each(group["cards"], &IO.puts("  ##{&1["id"]}  #{&1["title"]}"))
    end)
  end

  defp query_result(%{"kind" => "table"} = a) do
    if a["rows"] == [],
      do: IO.puts(dim("no cards match")),
      else: table(a["headers"], Enum.map(a["rows"], & &1["cells"]))
  end

  defp query_result(_), do: IO.puts(dim("nothing to show"))

  def card_pages([]), do: IO.puts(dim("nothing written about this card yet"))

  def card_pages(pages) do
    rows =
      Enum.map(pages, fn p ->
        [
          if(p["pinned"], do: "pinned", else: ""),
          p["page"]["code"],
          p["page"]["title"],
          p["page"]["summary"] || "",
          p["page"]["url"]
        ]
      end)

    table(["", "CODE", "TITLE", "SUMMARY", "URL"], rows)
  end

  def skills([]), do: IO.puts(dim("this server ships no skills"))

  def skills(skills) do
    rows =
      Enum.map(skills, fn s ->
        [
          s["name"],
          s["sha"],
          to_string(length(s["files"] || [])),
          fit(s["description"] || "", 70)
        ]
      end)

    table(["SKILL", "VERSION", "FILES", "DESCRIPTION"], rows)
  end

  defp stamp(nil), do: ""

  defp stamp(iso) do
    case DateTime.from_iso8601(to_string(iso)) do
      {:ok, at, _} -> Calendar.strftime(at, "%Y-%m-%d %H:%M")
      _ -> to_string(iso)
    end
  end

  def callbacks([]), do: IO.puts(dim("no callbacks yet"))

  def callbacks(calls) do
    rows =
      Enum.map(calls, fn c ->
        [
          stamp(c["at"]),
          if(c["ok"], do: to_string(c["status"]), else: "⚠ " <> fit(c["error"] || "failed", 30)),
          c["method"] <> " " <> fit(c["url"], 50),
          c["rule"] || dim("(deleted rule)"),
          fit(c["card"] || "", 30)
        ]
      end)

    table(["WHEN", "RESULT", "CALL", "RULE", "CARD"], rows)
  end

  def runners([]),
    do:
      IO.puts(
        dim(
          "no runners — connect one with `slipdock runner new <board> --pool P` (a machine by default)"
        )
      )

  def runners(runners) do
    rows =
      Enum.map(runners, fn r ->
        [
          to_string(r["id"]),
          r["name"],
          r["pool"],
          if(r["last_seen_at"], do: stamp(r["last_seen_at"]), else: dim("never")),
          if(r["current_job_id"], do: "job ##{r["current_job_id"]}", else: dim("idle")),
          lacks_cell(r),
          drift_cell(r)
        ]
      end)

    table(["ID", "NAME", "POOL", "LAST SEEN", "NOW", "LACKS", "SKILLS · CLI"], rows)
  end

  # Its installed skills and CLI against what the server serves (#1795):
  # `current`, `drifted (slipdock-loop)`, `old`, `unknown` (never said).
  @doc false
  def drift_cell(%{"session" => true}), do: dim("-")

  def drift_cell(r) do
    d = r["drift"] || %{}
    "skills " <> skills_state(d) <> " · cli " <> (d["cli"] || "unknown")
  end

  defp skills_state(%{"skills" => "drifted", "drifted_skills" => names}),
    do: "drifted (#{Enum.join(names, ", ")})"

  defp skills_state(d), do: d["skills"] || "unknown"

  # Its skills and CLI against the server's (#1795), and the kinds it lacks.
  defp installed_lines(r) do
    d = r["drift"] || %{}
    IO.puts("lacks:     " <> lacks_cell(r))
    IO.puts("skills:    " <> skills_state(d))
    IO.puts("cli:       " <> (d["cli"] || "unknown"))
  end

  # The kinds its board needs that it doesn't take (#1658). The SCRIPT
  # column that said whether its shell script was current went with the
  # scripts (#2582).
  defp lacks_cell(r) do
    case r["missing_kinds"] do
      [_ | _] = kinds -> Enum.join(kinds, ", ")
      _ -> dim("-")
    end
  end

  # What a runner is: a session, a machine's, or one with a token of its own,
  # which since #2582 is a retired shell runner.
  defp runner_kind(%{"session" => true}), do: "Claude session"
  defp runner_kind(%{"machine_id" => id}) when not is_nil(id), do: "a machine's runner"
  defp runner_kind(_), do: "runner with its own token: a retired shell runner"

  # One runner in full: what it is, who made it, what it is doing now, how
  # its jobs have ended, its latest jobs and the rules that feed its pool.
  def runner(r) do
    runner_header(r)
    unless r["session"], do: installed_lines(r)
    runner_work(r)
  end

  # What it is, who made it, when it was seen and what it takes.
  defp runner_header(r) do
    IO.puts("runner ##{r["id"]} #{r["name"]}  pool #{r["pool"]}  (#{runner_kind(r)})")
    if r["settings"]["scenario"], do: IO.puts("setup:     #{r["settings"]["scenario"]}")

    if r["created_by"],
      do: IO.puts("made:      #{stamp(r["created_at"])} by #{r["created_by"]}"),
      else: IO.puts("made:      #{stamp(r["created_at"])}")

    IO.puts("seen:      " <> if(r["last_seen_at"], do: stamp(r["last_seen_at"]), else: "never"))

    # The kinds it said it takes on its last claim (#1656).
    case r["kinds"] do
      [_ | _] = kinds -> IO.puts("takes:     " <> Enum.join(kinds, ", "))
      _ -> IO.puts("takes:     " <> dim("not said (an older runner: no merge jobs)"))
    end
  end

  # Its API token and the job it holds, then its jobs.
  defp runner_work(r) do
    if t = r["api_token"] do
      IO.puts("api token: #{t["label"] || "##{t["id"]}"} (#{t["scope"]})")
    end

    case r["current_job"] do
      nil ->
        IO.puts("now:       idle")

      j ->
        IO.puts("now:       job ##{j["id"]} #{j["status"]} on card ##{j["card_id"]} #{j["card"]}")
    end

    runner_jobs(r)
  end

  # How its jobs ended, the rules that feed its pool, and its latest jobs.
  defp runner_jobs(r) do
    counts =
      (r["job_counts"] || %{})
      |> Enum.sort()
      |> Enum.map_join(", ", fn {status, n} -> "#{n} #{status}" end)

    IO.puts(
      "jobs:      #{r["jobs_total"] || 0}" <> if(counts == "", do: "", else: " (#{counts})")
    )

    case r["rules"] || [] do
      [] -> IO.puts("rules:     " <> dim("none send cards to this pool"))
      rules -> IO.puts("rules:     " <> Enum.map_join(rules, ", ", &"##{&1["id"]} #{&1["name"]}"))
    end

    if (r["recent_jobs"] || []) != [] do
      IO.puts("\nlatest jobs:")
      jobs(r["recent_jobs"])
    end
  end

  def runner_setup(setup) do
    IO.puts(setup["title"])
    IO.puts(setup["intro"] <> "\n")

    setup["steps"]
    |> Enum.with_index(1)
    |> Enum.each(fn {step, n} ->
      IO.puts("#{n}. #{step["text"]}")
      if step["code"], do: IO.puts("\n" <> indent(step["code"], "    ") <> "\n")
    end)

    Enum.each(setup["warnings"] || [], &IO.puts("\n⚠ " <> &1))
    IO.puts("\n" <> dim(setup["cost"]))
  end

  def jobs([]), do: IO.puts(dim("no jobs"))

  def jobs(jobs) do
    rows =
      Enum.map(jobs, fn j ->
        [
          to_string(j["id"]),
          job_status(j),
          "#" <> to_string(j["card_id"]) <> " " <> fit(j["card"] || "", 30),
          fit(j["step"] || "", 40),
          j["pool"] <> "/" <> j["kind"],
          j["runner"] || dim("-"),
          stamp(j["finished_at"] || j["started_at"] || j["claimed_at"] || j["queued_at"])
        ]
      end)

    table(["JOB", "STATUS", "CARD", "STEP", "POOL/KIND", "RUNNER", "WHEN"], rows)
  end

  # What becomes of a job's live log (#1872): kept as a page, deleted, or
  # when it goes.
  defp job_log_fate(j) do
    cond do
      j["transcript_page_id"] ->
        IO.puts("log:      kept as page ##{j["transcript_page_id"]}")

      j["transcript_deleted_at"] ->
        IO.puts("log:      deleted #{stamp(j["transcript_deleted_at"])}")

      j["transcript_expires_at"] ->
        IO.puts(
          "log:      #{j["transcript_lines"]} lines, deleted #{stamp(j["transcript_expires_at"])} " <>
            "unless kept (slipdock job #{j["id"]} --keep)"
        )

      true ->
        :ok
    end
  end

  def job(j) do
    IO.puts("job ##{j["id"]}  #{job_status(j)}  card ##{j["card_id"]}  #{j["pool"]}/#{j["kind"]}")
    if j["runner"], do: IO.puts("runner:   #{j["runner"]} (attempt #{j["attempts"]})")
    if j["exit_code"], do: IO.puts("exit:     #{j["exit_code"]}")
    if j["error"], do: IO.puts("error:    #{j["error"]}")
    if j["step"], do: IO.puts("step:     #{j["step"]} (#{stamp(j["step_at"])})")
    IO.puts("queued:   #{stamp(j["queued_at"])}")
    if j["finished_at"], do: IO.puts("finished: #{stamp(j["finished_at"])}")
    job_log_fate(j)
    IO.puts("\nprompt:\n" <> indent(j["prompt"] || ""))

    case j["output"] || j["log_tail"] do
      text when text in [nil, ""] -> :ok
      text -> IO.puts("\nlog (tail):\n" <> indent(text))
    end
  end

  defp job_status(%{"cancel_requested" => true, "status" => s}) when s in ~w(claimed running),
    do: s <> " (stopping)"

  defp job_status(%{"status" => "queued", "waiting_on" => reason}) when is_binary(reason),
    do: "queued (waiting: #{reason})"

  defp job_status(%{"status" => "parked"}), do: "parked (waiting on a person)"
  defp job_status(%{"status" => s}), do: s

  def alerts([]), do: IO.puts(dim("no alerts"))

  def alerts(alerts) do
    rows =
      Enum.map(alerts, fn a ->
        [
          to_string(a["id"]),
          severity(a["severity"]),
          a["title"],
          a["card"] || "",
          a["board"] || ""
        ]
      end)

    table(["ID", "LEVEL", "ALERT", "CARD", "BOARD"], rows)
  end

  defp severity("urgent"), do: "‼"
  defp severity("warning"), do: "!"
  defp severity(_), do: dim("i")

  @doc "The automation vocabulary, as the help an agent needs to write a spec."
  def automation_presets(presets) do
    presets
    |> Enum.chunk_by(& &1["group"])
    |> Enum.each(fn group ->
      IO.puts(bold(String.upcase(hd(group)["group"])))

      for p <- group do
        IO.puts("  " <> String.pad_trailing(p["key"], 20) <> p["description"])

        fields =
          Enum.map_join(p["fields"], "  ", fn f ->
            name = if f["required"], do: f["name"] <> "*", else: f["name"]

            hint =
              cond do
                f["options"] -> "=" <> Enum.join(f["options"], "|")
                f["default"] -> "=#{f["default"]}"
                true -> ""
              end

            name <> hint
          end)

        IO.puts(dim("      " <> fields))
      end

      IO.puts("")
    end)

    IO.puts(dim("* required. slipdock new-automation <board> --preset KEY field=value ..."))
  end

  def vocabulary(%{"vocabulary" => v, "example" => example}) do
    IO.puts(bold("TRIGGERS") <> dim("  (exactly one, as \"trigger\")"))

    for t <- v["triggers"] do
      clock =
        cond do
          t["scheduled"] -> " ⏱"
          t["feed"] -> " ↻"
          true -> ""
        end

      IO.puts("  " <> String.pad_trailing(t["type"] <> clock, 20) <> t["description"])
      if keys(t) != "", do: IO.puts(dim("      keys: " <> keys(t)))
    end

    IO.puts("")
    IO.puts(bold("CONDITIONS") <> dim("  (any number, all must hold; field / op / value)"))
    IO.puts("  fields: " <> Enum.join(v["condition_fields"], " "))
    IO.puts("  ops:    " <> Enum.join(v["condition_ops"], " "))

    IO.puts("")
    IO.puts(bold("ACTIONS") <> dim("  (one or more)"))

    for a <- v["actions"] do
      IO.puts("  " <> String.pad_trailing(a["type"], 20) <> a["description"])
      if keys(a) != "", do: IO.puts(dim("      keys: " <> keys(a)))
    end

    IO.puts("")
    IO.puts(bold("PLACEHOLDERS") <> dim("  (in any text an action sends)"))
    IO.puts(indent(Enum.join(v["placeholders"], " ")))

    IO.puts("")
    IO.puts(bold("EXAMPLE"))
    IO.puts(indent(pretty(example)))
  end

  defp keys(%{"required" => required, "optional" => optional}) do
    Enum.map_join(Enum.map(required, &(&1 <> "*")) ++ optional, ", ", & &1)
  end

  # Pretty JSON, so a spec can be copied out, edited and passed back in.
  defp pretty(data) do
    data
    |> then(
      &:json.format(&1, fn
        nil, _e, _s -> "null"
        o, e, s -> :json.format_value(o, e, s)
      end)
    )
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  defp table_fields do
    %{
      "id" => {"ID", fn c -> "##{c["id"]}" end},
      "title" => {"TITLE", fn c -> if(c["completed"], do: "✓ ", else: "") <> c["title"] end},
      "column" => {"LIST", fn c -> c["column"] || "" end},
      "priority" =>
        {"PRIORITY", fn c -> if(c["priority"] == "none", do: "", else: c["priority"]) end},
      "assignee" => {"ASSIGNEE", fn c -> assignees(c, & &1["name"]) || "" end},
      "flags" => {"FLAGS", fn c -> flags(c["flags"]) || "" end},
      "tags" => {"TAGS", fn c -> Enum.join(c["tags"] || [], ",") end},
      "start" => {"START", fn c -> c["start_date"] || "" end},
      "due" => {"DUE", fn c -> c["due_date"] || "" end},
      "completed" => {"DONE", fn c -> if(c["completed"], do: "yes", else: "") end},
      "percent" => {"%", fn c -> if(p = c["percent_complete"], do: "#{p}%", else: "") end},
      "time" => {"TIME", fn c -> time_text(c) || "" end},
      "checklist" =>
        {"CHECKLIST",
         fn c ->
           if(c["checklist"]["total"] > 0,
             do: "#{c["checklist"]["done"]}/#{c["checklist"]["total"]}",
             else: ""
           )
         end},
      "comments" =>
        {"COMMENTS",
         fn c -> if(c["comments"] == [], do: "", else: to_string(length(c["comments"]))) end},
      "deps" => {"DEPS", fn c -> deps_cell(c) end},
      "subcards" =>
        {"SUBCARDS",
         fn c -> if(sb = c["sub_board"], do: "#{sb["completed"]}/#{sb["total"]}", else: "") end},
      "rollup" => {"ROLLUP", fn c -> rollup_cell(c["rollup"]) end},
      "health" => {"HEALTH", fn c -> if(r = c["rollup"], do: r["health"], else: "") end},
      "created" => {"CREATED", fn c -> String.slice(c["inserted_at"] || "", 0, 10) end},
      "updated" => {"UPDATED", fn c -> String.slice(c["updated_at"] || "", 0, 10) end}
    }
  end

  @default_table_fields ~w(id title column priority tags due completed)

  def card_table(%{"rows" => rows, "cells" => cells, "config" => c} = g, fields) do
    fields = (fields || @default_table_fields) |> Enum.filter(&Map.has_key?(table_fields(), &1))
    if fields == [], do: raise(ArgumentError, "no valid fields")
    grouped? = c["rows"] != "none"
    headers = Enum.map(fields, &elem(table_fields()[&1], 0))

    IO.puts(
      dim(
        "#{g["shown"]} cards#{if g["hidden"] > 0, do: ", #{g["hidden"]} hidden by filters", else: ""} · sort: #{c["sort"]} #{if c["dir"] == "desc", do: "↓", else: "↑"}"
      )
    )

    rows
    |> Enum.zip(cells)
    |> Enum.each(fn {row, [cards]} ->
      if grouped?, do: IO.puts("\n" <> bold("## #{row["label"]}") <> dim("  #{row["count"]}"))

      table(
        headers,
        Enum.map(cards, fn card -> Enum.map(fields, &elem(table_fields()[&1], 1).(card)) end)
      )
    end)
  end

  # "2/3 leaves · 5 Jan → 15 Jan · +5d late": what a card's subcards roll up to.
  defp rollup_cell(nil), do: ""

  defp rollup_cell(r) do
    dates =
      case {r["start"], r["due"]} do
        {nil, nil} -> nil
        {s, d} -> "#{s || "?"} → #{d || "?"}"
      end

    [
      "#{r["done"]}/#{r["total"]}",
      dates,
      # Name the date each overrun is measured from, *and* the date the
      # subcards actually reach. "+31d late" said neither, so the number had
      # nothing on screen to measure it against.
      if((r["start_slip_days"] || 0) > 0,
        do: "subcards begin #{r["derived_start"]}, #{r["start_slip_days"]}d past start date"
      ),
      if((r["due_slip_days"] || r["slip_days"] || 0) > 0,
        do:
          "subcards run to #{r["derived_due"]}, " <>
            "#{r["due_slip_days"] || r["slip_days"]}d past due date"
      ),
      if(r["blocked"], do: "blocked")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp deps_cell(c) do
    blocked =
      if c["blocked"],
        do:
          "blocked-by:" <>
            Enum.map_join(
              Enum.reject(c["blocked_by"] || [], &(&1["completed"] or &1["released"])),
              ",",
              &"##{&1["id"]}"
            )

    blocks =
      if (c["blocks"] || []) != [],
        do: "blocks:" <> Enum.map_join(c["blocks"], ",", &"##{&1["id"]}")

    [blocked, blocks] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  @label_width 18
  @cell_width 26

  def swimlanes(%{"rows" => rows, "cols" => cols, "cells" => cells, "config" => c} = g) do
    view = if g["view"], do: "view “#{g["view"]["name"]}”  ", else: ""

    unit =
      if Enum.member?(~w(due_date schedule created updated), c["rows"]) or
           Enum.member?(~w(due_date schedule created updated), c["cols"]),
         do: " by #{c["unit"]}",
         else: ""

    IO.puts(
      bold(
        "#{view}rows: #{c["rows"]}  cols: #{c["cols"]}#{unit}  sort: #{c["sort"]} #{if c["dir"] == "desc", do: "↓", else: "↑"}"
      ) <>
        dim(
          "  #{g["shown"]} cards#{if g["hidden"] > 0, do: ", #{g["hidden"]} hidden by filters", else: ""}"
        )
    )

    if rows == [] or cols == [] do
      IO.puts(dim("nothing to show"))
    else
      IO.puts("")
      row_headers? = c["rows"] != "none"
      col_headers? = c["cols"] != "none"
      label_pad = if row_headers?, do: String.duplicate(" ", @label_width + 2), else: ""

      if col_headers? do
        IO.puts(
          label_pad <>
            Enum.map_join(
              cols,
              "  ",
              &fit(bold(&1["label"]) <> dim(" (#{&1["count"]})"), @cell_width)
            )
        )
      end

      rows
      |> Enum.zip(cells)
      |> Enum.each(fn {row, row_cells} ->
        lines = row_cells |> Enum.map(&length/1) |> Enum.max(fn -> 0 end) |> max(1)

        for i <- 0..(lines - 1) do
          label =
            cond do
              not row_headers? -> ""
              i == 0 -> fit(bold(row["label"]) <> dim(" (#{row["count"]})"), @label_width) <> "  "
              true -> label_pad
            end

          body =
            Enum.map_join(row_cells, "  ", fn cards ->
              case Enum.at(cards, i) do
                nil -> fit(if(i == 0, do: dim("·"), else: ""), @cell_width)
                card -> fit(cell_card(card), @cell_width)
              end
            end)

          IO.puts(String.trim_trailing(label <> body))
        end
      end)
    end
  end

  defp cell_card(c) do
    tick = if c["completed"], do: "✓", else: ""
    "##{c["id"]}#{tick} #{c["title"]}"
  end

  # Pad or truncate (with an ellipsis) to a visible width, ignoring ANSI codes.
  defp fit(s, width) do
    plain = strip(s)
    len = String.length(plain)

    cond do
      len == width -> s
      len < width -> s <> String.duplicate(" ", width - len)
      true -> String.slice(plain, 0, width - 1) <> "…"
    end
  end

  @doc """
  A card's edge colours (#1209) on one line: `red` when the four agree,
  `top red · left sky` otherwise; nil when it has none.
  """
  def borders_line(c) do
    edges = for e <- ~w(top right bottom left), do: {e, c["border_" <> e]}

    case Enum.uniq_by(edges, &elem(&1, 1)) do
      [{_, nil}] ->
        nil

      [{_, colour}] ->
        "#{colour} (all edges)"

      _ ->
        edges
        |> Enum.reject(&is_nil(elem(&1, 1)))
        |> Enum.map_join(" · ", fn {e, k} -> "#{e} #{k}" end)
    end
  end

  defp dependency_list(nil, _board_id), do: "-"
  defp dependency_list([], _board_id), do: "-"

  # A card on another board is prefixed with that board's code.
  defp dependency_list(deps, board_id) do
    Enum.map_join(deps, ", ", fn d ->
      state =
        cond do
          d["completed"] -> "done"
          d["archived"] -> "archived"
          d["released"] -> "pending verification, shipped"
          true -> "open"
        end

      board = if d["board"] && d["board_id"] != board_id, do: "#{d["board"]} ", else: ""
      "#{board}##{d["id"]} #{d["title"]} (#{state})"
    end)
  end

  def flags([]), do: nil
  def flags(flags), do: Enum.map_join(flags, "", &Map.get(@flag_glyphs, &1, "?"))

  # Which instance this one was copied from (#2081): one look to see why it
  # came out the way it did.
  defp copied_from_field(%{"id" => id, "title" => title}),
    do: field("Copied from", "##{id} #{title}")

  defp copied_from_field(_), do: :ok

  defp field(name, value), do: IO.puts(String.pad_trailing(name <> ":", 14) <> to_string(value))

  # The card's flags, each with who clears it (#2624) when the server says:
  # one a line, "needs a person" or "clears itself" and why. A server older
  # than `flag_attention` gets them on one line, as before.
  @doc false
  def flags_text(flags, _attention) when flags in [nil, []], do: "-"

  def flags_text(flags, attention) when is_map(attention) and map_size(attention) > 0 do
    Enum.map_join(flags, "\n" <> String.duplicate(" ", 14), fn flag ->
      case attention[flag] do
        %{"attention" => kind, "why" => why} -> "#{flag} · #{attention_words(kind)}#{why}"
        _ -> flag
      end
    end)
  end

  def flags_text(flags, _attention), do: Enum.join(flags, ", ")

  defp attention_words("person"), do: "needs a person: "
  defp attention_words("auto"), do: "clears itself: "
  defp attention_words(_kind), do: ""

  defp indent(text, pad \\ "  "),
    do: text |> String.split("\n") |> Enum.map_join("\n", &(pad <> &1))

  def table(headers, rows) do
    widths =
      [headers | rows]
      |> Enum.zip_with(fn col -> col |> Enum.map(&String.length(strip(&1))) |> Enum.max() end)

    line = fn cells ->
      cells
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, w} -> pad(cell, w) end)
      |> String.trim_trailing()
    end

    IO.puts(dim(line.(headers)))
    Enum.each(rows, &IO.puts(line.(&1)))
  end

  defp pad(s, w), do: s <> String.duplicate(" ", max(w - String.length(strip(s)), 0))
  defp strip(s), do: Regex.replace(~r/\e\[[0-9;]*m/, s, "")

  @doc """
  Everything the server says, made safe to print. Anybody who can write on a
  board can put control characters in a title, and a terminal obeys them:
  OSC 52 writes to your clipboard, OSC 8 disguises a link, `\\e[2K\\r`
  rubs out the line and prints something else in its place. Every C0 and C1
  control goes except newline and tab. `--json` needs none of this — the
  encoder escapes them.
  """
  def scrub(s) when is_binary(s) do
    if String.valid?(s),
      do: String.replace(s, ~r/[\x{0}-\x{8}\x{b}-\x{1f}\x{7f}-\x{9f}]/u, ""),
      else: s |> String.replace_invalid() |> scrub()
  end

  def scrub(m) when is_map(m), do: Map.new(m, fn {k, v} -> {scrub(k), scrub(v)} end)
  def scrub(l) when is_list(l), do: Enum.map(l, &scrub/1)
  def scrub(other), do: other

  defp tty?, do: System.get_env("NO_COLOR") == nil and IO.ANSI.enabled?()
  def bold(s), do: if(tty?(), do: IO.ANSI.bright() <> s <> IO.ANSI.reset(), else: s)
  def dim(s), do: if(tty?(), do: IO.ANSI.faint() <> s <> IO.ANSI.reset(), else: s)
  def green(s), do: if(tty?(), do: IO.ANSI.green() <> s <> IO.ANSI.reset(), else: s)
  def red(s), do: if(tty?(), do: IO.ANSI.red() <> s <> IO.ANSI.reset(), else: s)
  def yellow(s), do: if(tty?(), do: IO.ANSI.yellow() <> s <> IO.ANSI.reset(), else: s)

  # When, and by whom when the server recorded it (#2028): `2026-11-07T10:00:00Z
  # by Dev server loop`. Nobody recorded, or an older server, is the time alone.
  defp by_line(at, %{"name" => name}) when is_binary(name) and name != "",
    do: "#{at} by #{name}"

  defp by_line(at, _who), do: at

  # The runner loop holding a card (#2027), under its assignees and not one
  # of them: `Loop: Mac Studio · verify (job #12)`.
  defp loop_field(%{} = loop),
    do: field("Loop", loop_text(loop, " · ") <> " (job ##{loop["job_id"]})")

  defp loop_field(_), do: :ok

  # Everybody on a card, lead first, each as `fun` draws them; nil for nobody.
  # A server from before cards had several sends only `assignee`.
  defp assignees(c, fun) do
    case c["assignees"] || List.wrap(c["assignee"]) do
      [] -> nil
      people -> Enum.map_join(people, ", ", fun)
    end
  end

  # Where an agent's completion stands (#1633), and who it is waiting on.
  # The last decision's verdict in parts (#1778), one line each:
  # `✓ bar 1`, `✗ UX-4 must broken: hex colour`. None while pending.
  defp put_verify_checks(state, checks),
    do: Enum.each(verify_check_lines(state, checks), &IO.puts(indent(&1)))

  defp verify_check_lines("pending", _checks), do: []

  defp verify_check_lines(_state, %{} = checks) do
    notes = checks["notes"] || %{}
    carried = checks["carried"] || %{}

    (check_part("the ask", checks["ask"], carried_note(notes["ask"], carried["ask"])) ++
       for(
         b <- checks["bar"] || [],
         do:
           {"bar " <> to_string(b["item"]), b["result"],
            carried_note(b["note"], b["carried_from"])}
       ) ++
       suite_part(checks["suite"]) ++
       for(
         r <- checks["rules"] || [],
         do: {rule_part(r), r["result"], r |> rule_note() |> carried_note(r["carried_from"])}
       ) ++
       check_part(
         "Handbook line",
         checks["handbook_line"],
         carried_note(notes["handbook_line"], carried["handbook_line"])
       ) ++
       defect_parts(checks["defect_review"]) ++
       mutant_parts(checks["mutants"]) ++ not_verified_part(checks["not_verified"]))
    |> Enum.map(&check_line/1)
  end

  defp verify_check_lines(_state, _checks), do: []

  # The defect review of a schema or security card (#1953): each finding by
  # severity, where it is. Only an important one fails.
  defp defect_parts(list) when is_list(list) do
    for d <- list do
      place = "#{d["file"]}:#{d["line"]}"
      {"defect", d["severity"], if(d["note"], do: place <> "; " <> d["note"], else: place)}
    end
  end

  defp defect_parts(_), do: []

  # The mutation review (#2354): each line broken on purpose, and whether
  # the card's tests caught it. Only a survivor fails.
  defp mutant_parts(%{"n/a" => why}), do: [{"mutants", "n/a", why}]

  defp mutant_parts(list) when is_list(list) do
    for m <- list do
      note =
        ["#{m["file"]}:#{m["line"]}", m["mutation"], m["note"]]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("; ")

      {"mutant", m["result"], carried_note(note, m["carried_from"])}
    end
  end

  defp mutant_parts(_), do: []

  # A docs card the server accepted with no verify job (#1953).
  defp not_verified_part(p) when is_binary(p),
    do: [{"not verified", "unverified", "profile #{p}: no verify job runs for it"}]

  defp not_verified_part(_), do: []

  # A part carried from an earlier verdict (#1944): passed at that commit,
  # not judged again.
  defp carried_note(note, sha) when is_binary(sha) do
    carried = "carried from " <> String.slice(sha, 0, 7)
    if note, do: carried <> "; " <> note, else: carried
  end

  defp carried_note(note, _sha), do: note

  defp check_part(_label, nil, _note), do: []
  defp check_part(label, result, note), do: [{label, result, note}]

  defp suite_part(%{"passed" => p, "failed" => f}) when is_integer(f) and f > 0,
    do: [{"suite #{p} passed, #{f} failed", "fail", nil}]

  defp suite_part(%{"passed" => p, "failed" => f}),
    do: [{"suite #{p} passed, #{f} failed", "ok", nil}]

  defp suite_part(_), do: []

  defp rule_part(r), do: [r["id"], r["severity"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  # A pre-existing rule hit (#1945) leads with where it is broken.
  defp rule_note(%{"result" => "pre-existing", "file" => file} = r) do
    place = "#{file}:#{r["line"]}"
    if r["note"], do: place <> "; " <> r["note"], else: place
  end

  defp rule_note(r), do: r["note"]

  defp check_line({label, result, note}) do
    mark =
      cond do
        Enum.member?(~w(pre-existing nit unverified n/a), result) -> "○"
        Enum.member?(~w(misses fail broken disputed important survived), result) -> "✗"
        true -> "✓"
      end

    shown = if Enum.member?(~w(ok fail), result), do: "", else: " " <> result
    mark <> " " <> label <> shown <> if(note, do: ": " <> note, else: "")
  end

  # A list line's mark for a card held for a person before merging (#1952).
  defp held_mark("held"), do: "✋held for a person"
  defp held_mark(_state), do: nil

  defp verify_line("pending", c),
    do:
      "pending — submitted by #{actor_name(c["verify_submitter"])}; another agent or a person decides"

  defp verify_line("merging", c),
    do:
      "merging — accepted by #{actor_name(c["verify_by"])}; a runner merges the pull request " <>
        "(or a person: slipdock verify #{c["id"]} merged)"

  defp verify_line("held", c),
    do:
      "held — accepted by #{actor_name(c["verify_by"])}; its human tier is before_merge, so a " <>
        "person merges it or sends it back (answer its wait, or slipdock verify #{c["id"]} " <>
        "accept / reject --reason …)"

  defp verify_line(state, c), do: "#{state} by #{actor_name(c["verify_by"])}"

  defp actor_name(%{"agent" => agent}) when is_binary(agent), do: "agent “#{agent}”"
  defp actor_name(%{"kind" => "agent"}), do: "an agent"
  defp actor_name(%{"kind" => "human"}), do: "a person"
  defp actor_name(_), do: "somebody"

  defp suite_text(s) do
    counts =
      [{s["passed"], "passed"}, {s["failed"], "failed"}]
      |> Enum.reject(fn {n, _} -> is_nil(n) end)
      |> Enum.map_join(", ", fn {n, w} -> "#{n} #{w}" end)

    if counts == "", do: s["result"], else: "#{s["result"]} (#{counts})"
  end

  # A card's open findings (W-2310 §Findings), and how to list them.
  defp findings_field(%{"findings" => n} = c) when is_integer(n) and n > 0,
    do: field("Findings", "#{n} open · slipdock findings #{c["board_id"]} --card #{c["id"]}")

  defp findings_field(_card), do: :ok
end
