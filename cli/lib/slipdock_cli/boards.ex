defmodule SlipdockCLI.Boards do
  @moduledoc false

  # Boards, cards and everything hung off them: search and saved queries,
  # columns, tags, views, fields, milestones, templates, favourites, sprints,
  # time, dependencies, links and checklists. Both the reads and the writes.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(guide search ask search-status saved save unsave boards board columns tags activity cards card swimlanes views favourites fav unfav table fields milestones templates add edit set vote status new-field delete-field preset milestone delete-milestone move done undone flag tag check timer log tick comment link unlink weblink unweblink blocked-by blocks archive restore delete subboard new-template delete-template new-board welcome set-board sprint sprint-add sprint-sources sprint-plan burndown velocity archive-board restore-board order-boards new-column new-tag save-view update-view delete-view)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  # The server's own instructions for agents; needs no token, but says more with one.
  def run("guide", [], o), do: HTTP.get("/guide") |> out(o, &IO.puts(&1["guide"]))

  # Semantic search. Everything after the command is the query, so it needs no
  # quoting: `slipdock search what did we decide about refunds`.
  def run("search", words, o) when words != [] do
    HTTP.get("/search",
      q: Enum.join(words, " "),
      board: o[:board],
      kind: o[:kind],
      limit: o[:limit],
      archived: if(o[:archived], do: "true")
    )
    |> out(o, &Render.search_results(&1, full: o[:full]))
  end

  def run("ask", words, o) when words != [] do
    HTTP.post("/ask", %{q: Enum.join(words, " ")}) |> out(o, &Render.answer/1)
  end

  def run("search-status", [], o),
    do: HTTP.get("/search/status") |> out(o, &Render.search_status/1)

  # Saved queries: the person's own, and only the question — never the answer.
  def run("saved", [], o),
    do: HTTP.get("/saved-queries", mode: saved_mode(o, nil)) |> out(o, &Render.saved_queries/1)

  def run("save", words, o) when words != [] do
    HTTP.post("/saved-queries", %{mode: saved_mode(o, "search"), q: Enum.join(words, " ")})
    |> out(o, &Render.saved_queries/1)
  end

  def run("unsave", [], o) do
    case o[:id] do
      nil -> fail("unsave needs the query's words, or --id N (see `slipdock saved`)")
      id -> HTTP.delete("/saved-queries/#{enc(id)}") |> out(o, &Render.saved_queries/1)
    end
  end

  def run("unsave", words, o) do
    HTTP.delete("/saved-queries", mode: saved_mode(o, "search"), q: Enum.join(words, " "))
    |> out(o, &Render.saved_queries/1)
  end

  # `--archived` lists the archived boards alone, `--all` lists them alongside
  # the rest; without either, archived boards are left out.
  def run("boards", [], o) do
    archived =
      cond do
        o[:all] -> "all"
        o[:archived] -> "true"
        true -> nil
      end

    HTTP.get("/boards", archived: archived, sort: o[:sort])
    |> out(o, &Render.boards(&1["boards"]))
  end

  def run("board", [ref], o),
    do: HTTP.get("/boards/#{enc(ref)}") |> out(o, &Render.board(&1["board"]))

  def run("columns", [ref], o),
    do: HTTP.get("/boards/#{enc(ref)}/columns") |> out(o, &Render.columns(&1["columns"]))

  def run("tags", [ref], o),
    do: HTTP.get("/boards/#{enc(ref)}/tags") |> out(o, &Render.tags(&1["tags"]))

  def run("activity", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/activity", limit: o[:limit])
    |> out(o, &Render.activity(&1["activity"]))
  end

  def run("cards", [ref], o) do
    completed =
      cond do
        o[:done] -> "true"
        o[:open] -> "false"
        true -> nil
      end

    HTTP.get("/boards/#{enc(ref)}/cards",
      column: o[:column],
      tag: List.first(Keyword.get_values(o, :tag)),
      priority: o[:priority],
      flag: List.first(Keyword.get_values(o, :flag)),
      q: o[:search],
      due: o[:due],
      deps: o[:deps],
      kind: List.first(kind_values(o)),
      assignee: if(o[:no_assignee], do: "none", else: o[:assignee]),
      completed: completed,
      archived: o[:archived]
    )
    |> out(o, &Render.cards(&1["cards"]))
  end

  def run("card", [id], o), do: HTTP.get("/cards/#{enc(id)}") |> out(o, &Render.card(&1["card"]))

  def run("swimlanes", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/swimlanes", view_query(o))
    |> out(o, &Render.swimlanes/1)
  end

  def run("views", [ref], o),
    do: HTTP.get("/boards/#{enc(ref)}/views") |> out(o, &Render.views(&1["views"]))

  ## Favourites ---------------------------------------------------------------
  #
  # A favourite is the token holder's own: there is no way to read or set
  # anyone else's, and favouriting something changes nothing about it.

  def run("favourites", [], o),
    do: HTTP.get("/favourites") |> out(o, &Render.favourites(&1["favourites"]))

  def run("fav", args, o), do: favourite(args, o, if(o[:off], do: :off, else: :on))
  def run("unfav", args, o), do: favourite(args, o, :off)

  def run("table", [ref], o) do
    query = view_query(o) |> Keyword.put(:cols, "none")

    query =
      if o[:group],
        do: Keyword.put(query, :rows, o[:group]),
        else: Keyword.put_new(query, :rows, "none")

    fields = if o[:fields], do: String.split(o[:fields], ",", trim: true), else: nil

    HTTP.get("/boards/#{enc(ref)}/swimlanes", query)
    |> out(o, &Render.card_table(&1, fields))
  end

  def run("fields", [ref], o),
    do: HTTP.get("/boards/#{enc(ref)}/fields") |> out(o, &Render.fields(&1["fields"]))

  def run("milestones", [ref], o),
    do: HTTP.get("/boards/#{enc(ref)}/milestones") |> out(o, &Render.milestones(&1["milestones"]))

  def run("templates", [], o),
    do: HTTP.get("/templates") |> out(o, &Render.templates(&1["templates"]))

  ## Write --------------------------------------------------------------------

  def run("add", [ref | title_words], o) when title_words != [] do
    body =
      %{
        "title" => Enum.join(title_words, " "),
        "column" => o[:column],
        "description" => o[:desc],
        "priority" => o[:priority],
        "flags" => nonempty(Keyword.get_values(o, :flag)),
        "tags" => nonempty(Keyword.get_values(o, :tag)),
        "start_date" => o[:start],
        "due_date" => o[:due],
        "percent_complete" => o[:percent],
        "time_spent" => o[:spent],
        "time_estimate" => o[:estimate],
        "time_unit" => o[:unit],
        "color" => o[:color]
      }
      |> Map.merge(assignees(o))
      |> compact()

    HTTP.post("/boards/#{enc(ref)}/cards", body) |> out(o, &card_ok("created", &1))
  end

  def run("edit", [id], o) do
    body =
      %{
        "title" => o[:title],
        "description" => o[:desc],
        "priority" => o[:priority],
        "start_date" => if(o[:no_start], do: nil, else: o[:start]),
        "due_date" => if(o[:no_due], do: nil, else: o[:due]),
        "percent_complete" => if(o[:no_percent], do: nil, else: o[:percent]),
        "time_spent" => o[:spent],
        "time_estimate" => o[:estimate],
        "time_unit" => o[:unit],
        "log_time" => o[:log],
        "color" => if(o[:no_color], do: nil, else: o[:color]),
        "column" => o[:column],
        "add_assignees" => nonempty(Keyword.get_values(o, :add_assignee)),
        "remove_assignees" => nonempty(Keyword.get_values(o, :remove_assignee))
      }
      |> Map.merge(if(o[:no_assignee], do: %{}, else: assignees(o)))
      |> compact()
      |> then(fn b -> if o[:no_start], do: Map.put(b, "start_date", nil), else: b end)
      |> then(fn b -> if o[:no_due], do: Map.put(b, "due_date", nil), else: b end)
      |> then(fn b -> if o[:no_percent], do: Map.put(b, "percent_complete", nil), else: b end)
      |> then(fn b -> if o[:no_color], do: Map.put(b, "color", nil), else: b end)
      |> then(fn b -> if o[:no_spent], do: Map.put(b, "time_spent", nil), else: b end)
      |> then(fn b -> if o[:no_estimate], do: Map.put(b, "time_estimate", nil), else: b end)
      |> then(fn b -> if o[:no_assignee], do: Map.put(b, "assignee", ""), else: b end)

    if body == %{}, do: fail("nothing to change — pass at least one option (see --help)")
    HTTP.patch("/cards/#{enc(id)}", body) |> out(o, &card_ok("updated", &1))
  end

  def run("set", [id | pairs], o) when pairs != [] do
    fields =
      Map.new(pairs, fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {String.trim(key), value}
          _ -> fail("expected key=value, got #{pair}")
        end
      end)

    HTTP.patch("/cards/#{enc(id)}", %{"fields" => fields}) |> out(o, &card_ok("updated", &1))
  end

  def run("vote", [id, n], o) do
    HTTP.post(item_path(id, "/vote"), %{"count" => n})
    |> out(o, fn r ->
      subject = r["card"] || r["page"]

      name =
        (r["card"] && Render.card_line(subject, true)) || "#{subject["code"]} #{subject["title"]}"

      IO.puts("you have #{r["my_votes"]} on " <> name)
    end)
  end

  def run("status", [id, health | words], o) do
    HTTP.post(item_path(id, "/status"), %{"health" => health, "body" => Enum.join(words, " ")})
    |> out(o, &card_ok("reported #{health} on", &1))
  end

  def run("new-field", [ref | words], o) when words != [] do
    options =
      (o[:options] || "")
      |> String.split(",", trim: true)
      |> Enum.map(fn item ->
        case String.split(item, "=", parts: 2) do
          [label, weight] -> %{"label" => String.trim(label), "weight" => String.trim(weight)}
          [label] -> %{"label" => String.trim(label)}
        end
      end)

    body =
      %{
        "name" => Enum.join(words, " "),
        "kind" => o[:kind] || "number",
        "sum" => o[:sum] || false,
        "options" => options,
        "config" =>
          if(o[:formula], do: %{"mode" => "expression", "expression" => o[:formula]}, else: %{})
      }

    HTTP.post("/boards/#{enc(ref)}/fields", body)
    |> out(o, fn r -> IO.puts("added field " <> Render.field_line(r["field"])) end)
  end

  def run("delete-field", [ref, field], o) do
    HTTP.delete("/boards/#{enc(ref)}/fields/#{enc(field)}")
    |> out(o, fn _ -> IO.puts("deleted") end)
  end

  def run("preset", [ref, key], o) do
    HTTP.post("/boards/#{enc(ref)}/presets/#{enc(key)}", %{})
    |> out(o, fn r -> Render.fields(r["fields"]) end)
  end

  def run("milestone", [ref | words], o) when words != [] do
    unless o[:date], do: fail("--date YYYY-MM-DD is required")

    HTTP.post("/boards/#{enc(ref)}/milestones", %{
      "name" => Enum.join(words, " "),
      "date" => o[:date],
      "color" => o[:color]
    })
    |> out(o, fn r ->
      IO.puts("added milestone #{r["milestone"]["name"]} on #{r["milestone"]["date"]}")
    end)
  end

  def run("delete-milestone", [ref, id], o) do
    HTTP.delete("/boards/#{enc(ref)}/milestones/#{enc(id)}")
    |> out(o, fn _ -> IO.puts("deleted") end)
  end

  def run("move", [id | column_words], o) when column_words != [] do
    column = Enum.join(column_words, " ")

    if o[:board] do
      # Another board entirely: the card goes with its subcards, its tags
      # travel by name, and custom fields survive only where the other board
      # has the same one. `index` means nothing in a list it has never been in.
      HTTP.post("/cards/#{enc(id)}/move", %{"board" => o[:board], "column" => column})
      |> out(o, fn r ->
        card_ok("moved", r)
        note_losses(r["moved"])
      end)
    else
      index =
        cond do
          o[:top] -> "top"
          o[:index] -> o[:index]
          true -> "bottom"
        end

      HTTP.post("/cards/#{enc(id)}/move", %{"column" => column, "index" => index})
      |> out(o, &card_ok("moved", &1))
    end
  end

  def run("done", ids, o) when ids != [],
    do: each(ids, o, &HTTP.patch("/cards/#{enc(&1)}", %{"completed" => true}), "completed")

  def run("undone", ids, o) when ids != [],
    do: each(ids, o, &HTTP.patch("/cards/#{enc(&1)}", %{"completed" => false}), "reopened")

  def run("flag", [id | flags], o) when flags != [] do
    key = if o[:off], do: "remove_flags", else: "add_flags"
    HTTP.patch("/cards/#{enc(id)}", %{key => flags}) |> out(o, &card_ok("updated", &1))
  end

  def run("tag", [id | tags], o) when tags != [] do
    key = if o[:off], do: "remove_tags", else: "add_tags"
    HTTP.patch("/cards/#{enc(id)}", %{key => tags}) |> out(o, &card_ok("updated", &1))
  end

  def run("check", [id | words], o) when words != [] do
    HTTP.post(item_path(id, "/checklist"), %{"text" => Enum.join(words, " ")})
    |> out(o, fn r ->
      IO.puts("added checklist item ##{r["item"]["id"]}: #{r["item"]["text"]}")
    end)
  end

  def run("timer", [id, action], o) when action in ~w(start stop) do
    HTTP.post("/cards/#{enc(id)}/timer", %{"action" => action})
    |> out(
      o,
      &card_ok(if(action == "start", do: "timer started on", else: "timer stopped on"), &1)
    )
  end

  def run("timer", _, _), do: fail("usage: slipdock timer <id> start|stop")

  def run("log", [id | amount], o) when amount != [] do
    HTTP.patch("/cards/#{enc(id)}", %{"log_time" => Enum.join(amount, " ")})
    |> out(o, &card_ok("logged time on", &1))
  end

  def run("log", _, _),
    do: fail("usage: slipdock log <id> <time>   (e.g. 45m, 1.5h, 2d, \"1h 30m\")")

  def run("tick", [item_id], o) do
    HTTP.post("/checklist/#{enc(item_id)}/toggle")
    |> out(o, fn r ->
      IO.puts(
        "item ##{r["item"]["id"]} is now #{if r["item"]["done"], do: "done", else: "not done"}: #{r["item"]["text"]}"
      )
    end)
  end

  def run("comment", [id | words], o) when words != [] do
    HTTP.post(item_path(id, "/comments"), %{"body" => Enum.join(words, " ")})
    |> out(o, fn r -> IO.puts("added comment ##{r["comment"]["id"]} to #{item_name(id)}") end)
  end

  def run("link", [id, kind | others], o) when others != [] do
    each(
      others,
      o,
      &HTTP.post("/cards/#{enc(id)}/links", %{"to" => &1, "kind" => kind}),
      "linked"
    )
  end

  def run("unlink", [id | link_ids], o) when link_ids != [] do
    each(link_ids, o, &HTTP.delete("/cards/#{enc(id)}/links/#{enc(&1)}"), "unlinked")
  end

  def run("weblink", [id, url], o) do
    HTTP.post(item_path(id, "/urls"), compact(%{"url" => url, "title" => o[:label]}))
    |> out(o, fn r ->
      IO.puts("linked #{item_name(id)} to #{r["url"]["url"]} [url ##{r["url"]["id"]}]")
    end)
  end

  def run("unweblink", [id | url_ids], o) when url_ids != [] do
    each(url_ids, o, &HTTP.delete(item_path(id, "/urls/#{enc(&1)}")), "unlinked")
  end

  def run("blocked-by", [id | others], o) when others != [],
    do: dependencies(id, others, "blocked_by", o)

  def run("blocks", [id | others], o) when others != [],
    do: dependencies(id, others, "blocks", o)

  def run("archive", ids, o) when ids != [],
    do: each(ids, o, &HTTP.post("/cards/#{enc(&1)}/archive"), "archived")

  def run("restore", ids, o) when ids != [],
    do: each(ids, o, &HTTP.post("/cards/#{enc(&1)}/restore"), "restored")

  def run("delete", ids, o) when ids != [] do
    Enum.each(ids, fn id ->
      HTTP.delete("/cards/#{enc(id)}") |> out(o, fn _ -> IO.puts("deleted card ##{id}") end)
    end)
  end

  def run("subboard", [id], o) do
    cond do
      o[:off] ->
        HTTP.delete("/cards/#{enc(id)}/subboard")
        |> out(o, fn _ -> IO.puts("removed subcards of card ##{id}") end)

      o[:template] ->
        HTTP.post("/cards/#{enc(id)}/subboard", %{"template" => o[:template]})
        |> out(o, fn r ->
          b = r["board"]

          IO.puts(
            "card ##{id} now has sub-board ##{b["id"]} (#{Enum.map_join(b["columns"], " · ", & &1["name"])})"
          )

          IO.puts(Render.dim("open it with: slipdock board #{b["id"]}"))
        end)

      true ->
        fail(
          "pass --template <name|id> to add subcards (see `slipdock templates`) or --off to remove them"
        )
    end
  end

  def run("new-template", words, o) when words != [] do
    lists = Keyword.get_values(o, :list)
    if lists == [], do: fail("pass at least one --list \"Name[:wip[:color]]\"")

    columns =
      Enum.map(lists, fn spec ->
        case String.split(spec, ":") do
          [name] -> %{"name" => name}
          [name, wip] -> %{"name" => name, "wip_limit" => wip}
          [name, wip, color | _] -> %{"name" => name, "wip_limit" => wip, "color" => color}
        end
      end)

    body =
      compact(%{"name" => Enum.join(words, " "), "description" => o[:desc], "columns" => columns})

    HTTP.post("/templates", body)
    |> out(o, fn r ->
      IO.puts("created template ##{r["template"]["id"]}: #{r["template"]["name"]}")
    end)
  end

  def run("delete-template", [ref], o) do
    HTTP.delete("/templates/#{enc(ref)}")
    |> out(o, fn _ -> IO.puts("deleted template #{ref}") end)
  end

  def run("new-board", words, o) when words != [] do
    body =
      compact(%{
        "name" => Enum.join(words, " "),
        "code" => o[:code],
        "shortcut" => o[:shortcut],
        "description" => o[:desc],
        "color" => o[:color],
        "template" => o[:template]
      })

    HTTP.post("/boards", body)
    |> out(o, fn r -> IO.puts("created board ##{r["board"]["id"]}: #{r["board"]["name"]}") end)
  end

  # The tour board a first sign-in builds by itself. Here for an account that
  # archived it, or one made before the tour existed.
  def run("welcome", [], o) do
    HTTP.post("/boards/welcome", compact(%{"force" => o[:force]}))
    |> out(o, fn r ->
      board = r["board"]

      IO.puts(
        "built “#{board["name"]}” (#{board["code"]}) — open it and work down the To Do list"
      )
    end)
  end

  def run("set-board", [ref], o) do
    body =
      compact(%{
        "name" => o[:name],
        "code" => o[:code],
        "shortcut" => o[:shortcut],
        "description" => o[:desc],
        "color" => o[:color],
        # What the foot of every list offers: --add-page / --no-add-page.
        "add_card" => o[:add_card],
        "add_page" => o[:add_page],
        "add_document" => o[:add_document],
        "simple" => o[:simple],
        "kind" =>
          case o[:sprints] do
            true -> "sprints"
            false -> ""
            nil -> nil
          end
      })

    if body == %{},
      do:
        fail(
          "nothing to change — pass --name, --code, --shortcut, --desc, --color, " <>
            "--[no-]add-card / --[no-]add-page / --[no-]add-document, --[no-]sprints or --[no-]simple"
        )

    HTTP.patch("/boards/#{enc(ref)}", body)
    |> out(o, fn r -> IO.puts("updated board ##{r["board"]["id"]}: #{r["board"]["name"]}") end)
  end

  def run("sprint", [ref], o) do
    body =
      compact(%{"name" => o[:name], "start" => o[:start], "days" => o[:days], "goal" => o[:goal]})

    HTTP.post("/boards/#{enc(ref)}/sprints", body)
    |> out(o, fn r ->
      c = r["card"]
      card_ok("started", r)
      IO.puts(Render.dim("#{c["start_date"]} → #{c["due_date"]}"))

      if sub = c["sub_board"],
        do:
          IO.puts(
            Render.dim(
              "add work with: slipdock sprint-add #{c["id"]} <card-id>...  (its board is ##{sub["id"]})"
            )
          )
    end)
  end

  def run("sprint", _, _),
    do: fail("usage: slipdock sprint <board> [--name N] [--start DATE] [--days N] [--goal TEXT]")

  def run("sprint-add", [id | cards], o) when cards != [] do
    HTTP.post("/cards/#{enc(id)}/sprint", %{"cards" => cards})
    |> out(o, fn r ->
      title = r["card"]["title"]
      n = length(r["added"])
      IO.puts("added #{n} card#{if n == 1, do: "", else: "s"} to #{title} (##{id})")
      Enum.each(r["added"], &IO.puts("  ##{&1["id"]} #{&1["title"]}"))

      Enum.each(r["skipped"], fn s ->
        IO.puts(Render.dim("  skipped ##{s["id"]}: #{s["reason"]}"))
      end)
    end)
  end

  def run("sprint-add", _, _),
    do: fail("usage: slipdock sprint-add <sprint-card-id> <card-id>...")

  def run("sprint-sources", [ref], o) do
    if o[:clear],
      do: put_sprint_sources(ref, [], o),
      else: HTTP.get("/boards/#{enc(ref)}/sprints/sources") |> out(o, &print_sprint_sources/1)
  end

  def run("sprint-sources", [ref | sources], o) do
    sources =
      Enum.map(sources, fn source ->
        case String.split(source, ":", parts: 2) do
          [board, lists] ->
            %{"board" => board, "lists" => lists |> String.split(",") |> Enum.map(&String.trim/1)}

          [board] ->
            %{"board" => board}
        end
      end)

    put_sprint_sources(ref, sources, o)
  end

  def run("sprint-sources", _, _),
    do:
      fail("usage: slipdock sprint-sources <board> [<source-board>[:list,list...]]... [--clear]")

  def run("sprint-plan", [id], o) do
    query = if o[:sort], do: "?sort=#{enc(o[:sort])}", else: ""

    HTTP.get("/cards/#{enc(id)}/sprint/plan#{query}")
    |> out(o, fn %{"plan" => p} ->
      s = p["sprint"]
      c = p["committed"]
      IO.puts("#{s["title"]} (##{s["id"]})  #{s["start"]} → #{s["due"]}")

      IO.puts(
        Render.dim("in it already: #{c["open"]} open of #{c["cards"]}, #{hours(c["estimate"])}")
      )

      if p["boards"] == [],
        do:
          IO.puts(
            "no sources yet — choose them with: slipdock sprint-sources <sprint-board> <board>"
          )

      Enum.each(p["boards"], fn g ->
        IO.puts("\n## #{g["board"]["name"]} (#{g["board"]["code"]})")

        Enum.each(g["lists"], fn l ->
          IO.puts("### #{l["name"]}  #{length(l["cards"])} cards")

          Enum.each(l["cards"], fn e ->
            scores = Enum.map_join(e["scores"], " ", fn {k, v} -> "#{k}:#{v}" end)
            est = if e["estimate_minutes"], do: hours(e["estimate_minutes"])
            est = if est && e["estimate_from_subcards"], do: "Σ" <> est, else: est
            sub = e["subcards"]

            extras =
              [
                e["priority"] != "none" && "prio:#{e["priority"]}",
                scores != "" && scores,
                e["votes"] > 0 && "votes:#{e["votes"]}",
                est && "est:#{est}",
                sub["total"] > 0 && e["sub_board_id"] && "⊞#{sub["done"]}/#{sub["total"]}",
                e["due_date"] && "due:#{e["due_date"]}"
              ]
              |> Enum.filter(& &1)
              |> Enum.join("  ")

            IO.puts("  ##{e["id"]} #{e["title"]}  " <> Render.dim(extras))
          end)
        end)
      end)
    end)
  end

  def run("sprint-plan", _, _),
    do:
      fail(
        "usage: slipdock sprint-plan <sprint-card-id> [--sort position|score|priority|estimate]"
      )

  def run("burndown", [id], o) do
    HTTP.get("/cards/#{enc(id)}/burndown")
    |> out(o, fn %{"burndown" => b} ->
      s = b["sprint"]
      IO.puts("#{s["title"]} (##{s["id"]})  #{s["start"]} → #{s["due"]}")
      IO.puts(Render.dim("#{b["done"]} of #{b["total"]} cards done"))
      width = max(b["total"], 1)

      Enum.each(b["days"], fn d ->
        ideal = :erlang.float_to_binary(d["ideal"] / 1, decimals: 1)

        case d["remaining"] do
          nil ->
            IO.puts(Render.dim("  #{d["date"]}     -  ideal #{ideal}"))

          n ->
            bar = String.duplicate("█", round(n * 30 / width))
            IO.puts("  #{d["date"]}  #{String.pad_leading("#{n}", 3)}  ideal #{ideal}  #{bar}")
        end
      end)
    end)
  end

  def run("burndown", _, _), do: fail("usage: slipdock burndown <sprint-card-id>")

  def run("velocity", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/sprints/velocity")
    |> out(o, fn %{"velocity" => v} ->
      if v["sprints"] == [], do: IO.puts("no sprints yet")

      Enum.each(v["sprints"], fn s ->
        state = if s["finished"], do: "", else: Render.dim("  (running)")

        IO.puts(
          "  ##{s["id"]} #{s["title"]}  #{s["start"]} → #{s["due"]}  " <>
            "#{s["completed"]} of #{s["committed"]} done#{state}"
        )
      end)

      if avg = v["average"], do: IO.puts("average velocity: #{avg} cards a sprint")
    end)
  end

  def run("velocity", _, _), do: fail("usage: slipdock velocity <board>")

  # Archiving a board puts it away without losing anything on it; restoring
  # brings it back where it was.
  def run("archive-board", [ref], o) do
    HTTP.post("/boards/#{enc(ref)}/archive", %{})
    |> out(o, fn r -> IO.puts("archived board #{r["board"]["name"]}") end)
  end

  def run("restore-board", [ref], o) do
    HTTP.post("/boards/#{enc(ref)}/restore", %{})
    |> out(o, fn r -> IO.puts("restored board #{r["board"]["name"]}") end)
  end

  # The order is the token holder's own: it moves nobody else's board index.
  # Boards left out fall to the end, oldest first.
  def run("order-boards", refs, o) when refs != [] do
    HTTP.post("/boards/order", %{"boards" => refs})
    |> out(o, &Render.boards(&1["boards"]))
  end

  def run("new-column", [ref | words], o) when words != [] do
    body =
      compact(%{"name" => Enum.join(words, " "), "wip_limit" => o[:wip], "color" => o[:color]})

    HTTP.post("/boards/#{enc(ref)}/columns", body)
    |> out(o, fn r -> IO.puts("created column ##{r["column"]["id"]}: #{r["column"]["name"]}") end)
  end

  def run("new-tag", [ref | words], o) when words != [] do
    body = compact(%{"name" => Enum.join(words, " "), "color" => o[:color]})

    HTTP.post("/boards/#{enc(ref)}/tags", body)
    |> out(o, fn r -> IO.puts("created tag ##{r["tag"]["id"]}: #{r["tag"]["name"]}") end)
  end

  def run("save-view", [ref | words], o) when words != [] do
    body =
      view_query(o)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("name", Enum.join(words, " "))

    HTTP.post("/boards/#{enc(ref)}/views", body)
    |> out(o, fn r ->
      IO.puts(
        "saved view ##{r["view"]["id"]}: #{r["view"]["name"]}  " <> Render.dim(r["view"]["url"])
      )
    end)
  end

  def run("update-view", [ref, view], o) do
    body = view_query(o) |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.delete("view")
    body = if o[:name], do: Map.put(body, "name", o[:name]), else: body
    if body == %{}, do: fail("nothing to change — pass view options or --name (see --help)")

    HTTP.patch("/boards/#{enc(ref)}/views/#{enc(view)}", body)
    |> out(o, fn r -> IO.puts("updated view ##{r["view"]["id"]}: #{r["view"]["name"]}") end)
  end

  def run("delete-view", [ref, view], o) do
    HTTP.delete("/boards/#{enc(ref)}/views/#{enc(view)}")
    |> out(o, fn _ -> IO.puts("deleted view #{view}") end)
  end

  def run(cmd, _args, _o), do: bad_usage(cmd)

  ## Helpers ------------------------------------------------------------------

  defp dependencies(id, others, key, o) do
    Enum.each(others, fn other ->
      result =
        if o[:off],
          do: HTTP.delete("/cards/#{enc(id)}/dependencies/#{enc(other)}"),
          else: HTTP.post("/cards/#{enc(id)}/dependencies", %{key => other})

      # Report errors as they happen; the final card print covers success.
      case result do
        {:ok, _} -> :ok
        error -> out(error, o, fn _ -> :ok end)
      end
    end)

    HTTP.get("/cards/#{enc(id)}") |> out(o, &card_ok("updated", &1))
  end

  # Said out loud, because it is not recoverable by trying again.
  defp note_losses(nil), do: :ok

  defp note_losses(moved) do
    [
      {moved["tags_created"], "tag", "created on the new board"},
      {moved["fields_dropped"], "field value", "dropped (no such field there)"},
      {moved["milestones_unpinned"], "milestone", "unpinned"}
    ]
    |> Enum.reject(fn {n, _, _} -> is_nil(n) or n == 0 end)
    |> Enum.each(fn {n, noun, what} ->
      IO.puts("  #{n} #{noun}#{if n == 1, do: "", else: "s"} #{what}")
    end)
  end

  ## Favourites ---------------------------------------------------------------

  # `--ask` picks the question list and `--mode` names either explicitly.
  # `--search` is not a mode flag here: it is already the substring filter on
  # `cards`, and one switch meaning two things is worse than one extra switch.
  # `default` is what an unqualified command means (nil lists both).
  defp saved_mode(o, default) do
    cond do
      o[:mode] -> o[:mode]
      o[:ask] -> "ask"
      true -> default
    end
  end

  defp favourite(["card", id], o, dir), do: set_favourite("card", id, o, dir)

  defp favourite(["board", ref], o, dir) do
    set_favourite("board", fetch!("/boards/#{enc(ref)}")["board"]["id"], o, dir)
  end

  defp favourite(["list", ref | name], o, dir) when name != [] do
    columns = fetch!("/boards/#{enc(ref)}/columns")["columns"]
    set_favourite("column", pick(columns, Enum.join(name, " "), "list", ref), o, dir)
  end

  defp favourite(["view", ref | name], o, dir) when name != [] do
    views = fetch!("/boards/#{enc(ref)}/views")["views"]
    set_favourite("view", pick(views, Enum.join(name, " "), "view", ref), o, dir)
  end

  defp favourite(_, _, _) do
    fail(
      "usage: slipdock fav card <id> | list <board> <column> | view <board> <view> | board <board>"
    )
  end

  defp set_favourite(kind, id, o, :on) do
    HTTP.post("/favourites", %{"kind" => kind, "id" => id})
    |> out(o, fn r ->
      IO.puts("favourited: " <> describe(r["favourites"], kind, id))
    end)
  end

  defp set_favourite(kind, id, o, :off) do
    HTTP.delete("/favourites/#{enc(kind)}/#{enc(id)}")
    |> out(o, fn _ -> IO.puts("no longer a favourite: #{kind} #{id}") end)
  end

  # What the server says it just added, so the confirmation names the thing
  # rather than repeating the id back.
  defp describe(favourites, kind, id) do
    case Enum.find(
           favourites || [],
           &(&1["kind"] == kind and to_string(&1["resource_id"]) == to_string(id))
         ) do
      nil -> "#{kind} #{id}"
      f -> "#{kind} “#{f["name"]}” — #{f["url"]}"
    end
  end

  # A list or a view named on the command line, resolved to its id the way
  # the rest of the CLI resolves things: by id, else by name, case-insensitively.
  defp pick(items, ref, what, board) do
    match =
      Enum.find(items, &(to_string(&1["id"]) == ref)) ||
        Enum.find(items, &(String.downcase(&1["name"]) == String.downcase(ref)))

    case match do
      nil ->
        names = Enum.map_join(items, ", ", &~s("#{&1["name"]}"))
        fail(~s(no #{what} called "#{ref}" on #{board}. There is: #{names}))

      item ->
        item["id"]
    end
  end

  # Swimlane configuration from CLI options, as API query/body params.
  # Absent options are left out so the server falls back to the saved view
  # (or the defaults).
  defp view_query(o) do
    done =
      cond do
        o[:done] -> "only"
        o[:open] -> "hide"
        true -> nil
      end

    [
      view: o[:view],
      rows: o[:rows],
      cols: o[:cols],
      unit: o[:unit],
      sort: o[:sort],
      dir: if(o[:descending], do: "desc"),
      empty: if(o[:show_empty], do: "show"),
      q: o[:search],
      due: o[:due],
      done: done,
      kinds: kind_values(o) |> Enum.join(",") |> presence(),
      tags: joined(o, :tag),
      priorities: joined(o, :priority),
      flags: joined(o, :flag),
      columns: joined(o, :column)
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  # `--kind card` and `--kind cards` both read well on the command line, so
  # both are taken; the API's vocabulary is the singular one.
  defp kind_values(o), do: o |> Keyword.get_values(:kind) |> Enum.map(&singular_kind/1)

  defp singular_kind("cards"), do: "card"
  defp singular_kind("documents"), do: "document"
  defp singular_kind("docs"), do: "document"
  defp singular_kind("doc"), do: "document"
  defp singular_kind("pages"), do: "page"
  defp singular_kind("wiki"), do: "page"
  defp singular_kind(other), do: other

  defp presence(""), do: nil
  defp presence(string), do: string

  defp joined(o, key) do
    case Keyword.get_values(o, key) do
      [] -> nil
      values -> Enum.join(values, ",")
    end
  end

  defp each(ids, o, fun, verb) do
    Enum.each(ids, fn id -> fun.(id) |> out(o, &card_ok(verb, &1)) end)
  end

  # A card is a number; anything else — "W-31", "board-code/slug" — names a
  # wiki page. A page holds comments, a checklist, status updates, web links
  # and votes in the same tables a card does (see `Slipdock.Boards.Owned`), so
  # the commands below take either and only the path changes.
  defp item_path(ref, suffix) do
    ref = to_string(ref)

    case Integer.parse(ref) do
      {_, ""} -> "/cards/#{enc(ref)}#{suffix}"
      _ -> "/pages/#{enc(ref)}#{suffix}"
    end
  end

  defp item_name(ref) do
    case Integer.parse(to_string(ref)) do
      {_, ""} -> "card ##{ref}"
      _ -> "page #{ref}"
    end
  end

  # One --assignee is "assignee", as it always was; several are the whole set.
  defp assignees(o) do
    case Keyword.get_values(o, :assignee) do
      [] -> %{}
      [one] -> %{"assignee" => one}
      many -> %{"assignees" => many}
    end
  end

  defp put_sprint_sources(ref, sources, o) do
    HTTP.put("/boards/#{enc(ref)}/sprints/sources", %{"sources" => sources})
    |> out(o, &print_sprint_sources/1)
  end

  defp print_sprint_sources(%{"sources" => []}),
    do: IO.puts("no sources: Add cards… browses board by board")

  defp print_sprint_sources(%{"sources" => sources}) do
    Enum.each(sources, fn s ->
      lists =
        if s["all_open_lists"],
          do: "every open list",
          else: Enum.map_join(s["lists"], ", ", & &1["name"])

      IO.puts("  #{s["board"]["name"]} (#{s["board"]["code"]}): #{lists}")
    end)
  end

  defp hours(nil), do: "0h"

  defp hours(minutes) do
    h = Float.round(minutes / 60, 1)
    if h == trunc(h), do: "#{trunc(h)}h", else: "#{h}h"
  end
end
