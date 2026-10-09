defmodule SlipdockCLI.Render do
  @moduledoc "Human-readable output for API responses."

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
        if(any_shared?, do: ["OWNER"], else: []) ++ ["CARDS", "DONE", "DESCRIPTION"]

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

        [to_string(t["id"]), t["name"], lists, t["description"] || ""]
      end)

    table(["ID", "NAME", "LISTS", "DESCRIPTION"], rows)
  end

  def board(b) do
    IO.puts(
      bold("#{b["name"]}") <>
        "  (board ##{b["id"]}#{if b["code"], do: " · #{b["code"]}"}#{if b["shortcut"], do: " · key #{b["shortcut"]}"}, #{b["color"]}#{if b["simple"], do: " · simple"}#{if b["archived_at"], do: " · archived"})"
    )

    if pc = b["parent_card"] do
      IO.puts(dim("sub-board of card ##{pc["id"]} “#{pc["title"]}” on board ##{pc["board_id"]}"))
    end

    if b["description"], do: IO.puts(dim(b["description"]))

    if b["kind"] == "sprints",
      do: IO.puts(dim("sprint board: each card is a sprint — slipdock sprint / sprint-add"))

    if b["owner"], do: IO.puts(dim("owner: " <> owner_name(b)))

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
              " (column ##{col["id"]})"
          )
      )

      # Cards and placed wiki pages share one order in the list, so the CLI
      # prints them the way the board draws them rather than in two groups.
      (Enum.map(col["cards"], &{&1["position"], 0, {:card, &1}}) ++
         Enum.map(pages, &{&1["board_position"], 1, {:page, &1}}))
      |> Enum.sort()
      |> Enum.each(fn
        {_, _, {:card, card}} -> IO.puts("  " <> card_line(card, false))
        {_, _, {:page, page}} -> IO.puts("  " <> page_line(page))
      end)
    end)
  end

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

  def cards(cards) do
    if cards == [],
      do: IO.puts(dim("no cards")),
      else: Enum.each(cards, &IO.puts(card_line(&1, true)))
  end

  def card_line(c, with_column?) do
    done = if c["completed"], do: "✓ ", else: ""
    title = if c["completed"], do: dim(c["title"]), else: c["title"]

    meta =
      [
        if(with_column? and c["column"], do: "[#{c["column"]}]"),
        if(c["priority"] != "none", do: "prio:#{c["priority"]}"),
        flags(c["flags"]),
        if(c["tags"] != [], do: "tags:" <> Enum.join(c["tags"], ",")),
        if(c["start_date"], do: "start:#{c["start_date"]}"),
        if(c["due_date"], do: "due:#{c["due_date"]}"),
        if(c["percent_complete"], do: "#{c["percent_complete"]}%"),
        if(t = time_text(c), do: "⏱" <> t),
        if(c["blocked"],
          do:
            "🔒blocked-by:" <>
              Enum.map_join(
                Enum.reject(c["blocked_by"] || [], & &1["completed"]),
                ",",
                &"##{&1["id"]}"
              )
        ),
        if(c["sub_board"], do: "⊞#{c["sub_board"]["completed"]}/#{c["sub_board"]["total"]}"),
        stand_in_text(c["stand_in_for"]),
        if((c["blocks"] || []) != [],
          do: "blocks:" <> Enum.map_join(c["blocks"], ",", &"##{&1["id"]}")
        ),
        if(c["checklist"]["total"] > 0,
          do: "☑#{c["checklist"]["done"]}/#{c["checklist"]["total"]}"
        ),
        if(c["comments"] != [], do: "💬#{length(c["comments"])}"),
        if(c["archived_at"], do: "(archived)")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    "#" <> String.pad_trailing(to_string(c["id"]), 4) <> done <> title <> "  " <> dim(meta)
  end

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

  def card(c) do
    IO.puts(
      bold("##{c["id"]} #{c["title"]}") <> if(c["completed"], do: "  ✓ completed", else: "")
    )

    field(
      "Board/column",
      "board ##{c["board_id"]} · #{c["column"]} (column ##{c["column_id"]}, position #{c["position"]})"
    )

    field("Priority", c["priority"])
    field("Flags", if(c["flags"] == [], do: "-", else: Enum.join(c["flags"], ", ")))
    field("Tags", if(c["tags"] == [], do: "-", else: Enum.join(c["tags"], ", ")))
    field("Start", c["start_date"] || "-")
    field("Due", c["due_date"] || "-")
    field("% complete", if(p = c["percent_complete"], do: "#{p}%", else: "-"))
    field("Time", time_text(c, true) || "-")
    field("Assignee", assignees(c, &"#{&1["name"]} <#{&1["email"]}>") || "-")
    field("Cover", c["color"] || "-")
    field("Blocked by", dependency_list(c["blocked_by"], c["board_id"]))
    field("Blocks", dependency_list(c["blocks"], c["board_id"]))

    if c["links"] not in [nil, []] do
      field(
        "Links",
        Enum.map_join(c["links"], "; ", fn l ->
          arrow = if l["direction"] == "out", do: "→", else: "←"

          "#{l["kind"]} #{arrow} ##{l["card"]["id"]} #{l["card"]["title"]}#{if l["card"]["board"], do: " (#{l["card"]["board"]})", else: ""} [link ##{l["id"]}]"
        end)
      )
    end

    if c["urls"] not in [nil, []] do
      field(
        "Web links",
        Enum.map_join(c["urls"], "; ", fn u ->
          "#{u["label"]} #{u["url"]} (added #{String.slice(to_string(u["added_at"]), 0, 10)}) [url ##{u["id"]}]"
        end)
      )
    end

    if c["date_precision"] not in [nil, "day"], do: field("Precision", c["date_precision"])
    if c["stated_health"], do: field("Reported", c["stated_health"])
    if (c["votes"] || 0) > 0, do: field("Votes", c["votes"])

    if c["fields"] not in [nil, %{}] do
      field("Fields", Enum.map_join(c["fields"], " · ", fn {k, v} -> "#{k}=#{v}" end))
    end

    if c["scores"] not in [nil, %{}] do
      field("Scores", Enum.map_join(c["scores"], " · ", fn {k, v} -> "#{k}=#{score(v)}" end))
    end

    if c["docs"] not in [nil, []] do
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

    if sb = c["sub_board"] do
      lists = Enum.map_join(sb["columns"], ", ", &"#{&1["name"]} (#{&1["cards"]})")
      field("Subcards", "board ##{sb["id"]} · #{sb["completed"]}/#{sb["total"]} done · #{lists}")
    end

    if r = c["rollup"] do
      field(
        "Rolled up",
        "#{r["done"]}/#{r["total"]} leaves done · #{r["health"]} · #{rollup_cell(r)}"
      )
    end

    if c["archived_at"], do: field("Archived", c["archived_at"])
    field("Created", c["inserted_at"])
    field("Updated", c["updated_at"])

    if c["description"] not in [nil, ""] do
      IO.puts("")
      IO.puts(bold("Description"))
      IO.puts(indent(c["description"]))
    end

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
        IO.puts("  " <> dim("#{m["inserted_at"]} (comment ##{m["id"]})"))
        IO.puts(indent(m["body"], "    "))
      end)
    end
  end

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
    |> Enum.reject(&(&1 in [nil, false]))
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
    full? = Keyword.get(opts, :full, false)

    Enum.each(results, fn result ->
      IO.puts(bold(result_heading(result)) <> "  " <> dim(strength(result["score"])))
      IO.puts(dim("   " <> result_where(result)))

      result["matches"]
      |> Enum.take(if full?, do: 99, else: 2)
      |> Enum.each(fn m ->
        label = if (m["section"] || "") != "", do: m["section"], else: kind_label(m["kind"])
        IO.puts(dim("   [#{label}] ") <> snippet(m, full?))
      end)

      IO.puts("")
    end)

    pages = Enum.count(results, &(&1["kind"] == "page"))
    cards = length(results) - pages

    IO.puts(
      dim(
        [
          cards > 0 && "#{cards} card#{if cards == 1, do: "", else: "s"}",
          pages > 0 && "#{pages} page#{if pages == 1, do: "", else: "s"}"
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
  defp result_heading(%{"card" => card}), do: "##{card["id"]} #{card["title"]}"

  defp result_where(%{"kind" => "page", "page" => page}) do
    "#{page["board"]["name"]} › wiki" <>
      if(page["summary"], do: " · #{page["summary"]}", else: "")
  end

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
      card["priority"] not in [nil, "none"] && "priority #{card["priority"]}",
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
      p["priority"] not in [nil, "none"] && "prio:#{p["priority"]}",
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
  def folders(folders, pages) do
    if folders == [] and pages == [] do
      IO.puts(dim("nothing written"))
    else
      folder_nodes(folders, 0)
      page_tree_lines(pages, 0)
    end
  end

  defp folder_nodes(nodes, depth) do
    Enum.each(nodes, fn f ->
      IO.puts(
        String.duplicate("  ", depth) <>
          bold(f["name"]) <> "/  " <> dim(f["slug"])
      )

      folder_nodes(f["folders"] || [], depth + 1)
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

  @doc "One folder, after it has been made, renamed or moved."
  def folder(f) do
    IO.puts(bold(f["path"]) <> "  " <> dim("#{f["slug"]} · id #{f["id"]}"))
  end

  @doc "Every board's wiki at once: boards as the top level, folders inside."
  def wiki([]), do: IO.puts(dim("no boards"))

  def wiki(boards) do
    Enum.each(boards, fn b ->
      IO.puts("")
      IO.puts(bold(b["name"]) <> "  " <> dim(b["code"] || ""))
      folder_nodes(b["folders"] || [], 1)
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
        "board #{p["board_id"]} · #{p["status"]}#{if p["archived_at"], do: " · archived"} · updated #{stamp(p["updated_at"])} · hash #{short_hash(p["content_hash"])}"
      )
    )

    if p["summary"], do: IO.puts(dim(p["summary"]))
    IO.puts("")
    IO.puts(p["body"] || "")
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

  defp short_hash(nil), do: "-"
  defp short_hash(hash), do: String.slice(hash, 0, 12)

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
    do: IO.puts(dim("no runners — make one with `slipdock runner new <board> <name> --pool P`"))

  def runners(runners) do
    rows =
      Enum.map(runners, fn r ->
        [
          to_string(r["id"]),
          r["name"],
          r["pool"],
          if(r["last_seen_at"], do: stamp(r["last_seen_at"]), else: dim("never")),
          if(r["current_job_id"], do: "job ##{r["current_job_id"]}", else: dim("idle"))
        ]
      end)

    table(["ID", "NAME", "POOL", "LAST SEEN", "NOW"], rows)
  end

  # One runner in full: what it is, who made it, what it is doing now, how
  # its jobs have ended, its latest jobs and the rules that feed its pool.
  def runner(r) do
    kind = if r["session"], do: "Claude session", else: "runner with its own token"
    IO.puts("runner ##{r["id"]} #{r["name"]}  pool #{r["pool"]}  (#{kind})")
    if r["settings"]["scenario"], do: IO.puts("setup:     #{r["settings"]["scenario"]}")

    if r["created_by"],
      do: IO.puts("made:      #{stamp(r["created_at"])} by #{r["created_by"]}"),
      else: IO.puts("made:      #{stamp(r["created_at"])}")

    IO.puts("seen:      " <> if(r["last_seen_at"], do: stamp(r["last_seen_at"]), else: "never"))

    if t = r["api_token"] do
      IO.puts("api token: #{t["label"] || "##{t["id"]}"} (#{t["scope"]})")
    end

    case r["current_job"] do
      nil ->
        IO.puts("now:       idle")

      j ->
        IO.puts("now:       job ##{j["id"]} #{j["status"]} on card ##{j["card_id"]} #{j["card"]}")
    end

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

  # What new answers change in a runner's steps: the lines out and in.
  def runner_diff(diff) do
    changed = Enum.reject(diff || [], fn [op, _] -> op == "eq" end)

    if changed == [] do
      IO.puts(dim("nothing changes on the machine\n"))
    else
      IO.puts("what changes — run the first step again on the machine:")

      Enum.each(changed, fn [op, line] ->
        IO.puts(if(op == "ins", do: "+ ", else: "- ") <> line)
      end)

      IO.puts("")
    end
  end

  # The wizard's steps, as `Slipdock.Runners.Setup` writes them.
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
          j["pool"] <> "/" <> j["kind"],
          j["runner"] || dim("-"),
          stamp(j["finished_at"] || j["started_at"] || j["claimed_at"] || j["queued_at"])
        ]
      end)

    table(["JOB", "STATUS", "CARD", "POOL/KIND", "RUNNER", "WHEN"], rows)
  end

  def job(j) do
    IO.puts("job ##{j["id"]}  #{job_status(j)}  card ##{j["card_id"]}  #{j["pool"]}/#{j["kind"]}")
    if j["runner"], do: IO.puts("runner:   #{j["runner"]} (attempt #{j["attempts"]})")
    if j["exit_code"], do: IO.puts("exit:     #{j["exit_code"]}")
    if j["error"], do: IO.puts("error:    #{j["error"]}")
    IO.puts("queued:   #{stamp(j["queued_at"])}")
    if j["finished_at"], do: IO.puts("finished: #{stamp(j["finished_at"])}")
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
              Enum.reject(c["blocked_by"] || [], & &1["completed"]),
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
      if c["rows"] in ~w(due_date schedule created updated) or
           c["cols"] in ~w(due_date schedule created updated), do: " by #{c["unit"]}", else: ""

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

  defp dependency_list(nil, _board_id), do: "-"
  defp dependency_list([], _board_id), do: "-"

  # A card on another board is prefixed with that board's code.
  defp dependency_list(deps, board_id) do
    Enum.map_join(deps, ", ", fn d ->
      state =
        cond do
          d["completed"] -> "done"
          d["archived"] -> "archived"
          true -> "open"
        end

      board = if d["board"] && d["board_id"] != board_id, do: "#{d["board"]} ", else: ""
      "#{board}##{d["id"]} #{d["title"]} (#{state})"
    end)
  end

  def flags([]), do: nil
  def flags(flags), do: Enum.map_join(flags, "", &Map.get(@flag_glyphs, &1, "?"))

  defp field(name, value), do: IO.puts(String.pad_trailing(name <> ":", 14) <> to_string(value))

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

  # Everybody on a card, lead first, each as `fun` draws them; nil for nobody.
  # A server from before cards had several sends only `assignee`.
  defp assignees(c, fun) do
    case c["assignees"] || List.wrap(c["assignee"]) do
      [] -> nil
      people -> Enum.map_join(people, ", ", fun)
    end
  end
end
