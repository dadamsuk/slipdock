defmodule SlipdockCLI.Vaults do
  @moduledoc false

  alias SlipdockCLI.FS

  # Vaults: board wikis laid out as one Obsidian-style vault (W-103). A vault
  # is named by its id or its name; a path is vault-relative, "/" the root.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render
  alias SlipdockCLI.Sync.{Import, Remote, State}

  @commands ~w(vault)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("vault", ["ls"], o), do: HTTP.get("/vaults") |> out(o, &vaults(&1["vaults"]))
  def run("vault", [], o), do: run("vault", ["ls"], o)

  def run("vault", ["show", ref], o),
    do: HTTP.get("/vaults/#{enc(ref)}") |> out(o, &vault(&1["vault"]))

  def run("vault", ["new" | words], o) when words != [] do
    HTTP.post("/vaults", %{"name" => Enum.join(words, " ")})
    |> out(o, &vault(&1["vault"], "made"))
  end

  def run("vault", ["rename", ref | words], o) when words != [] do
    HTTP.patch("/vaults/#{enc(ref)}", %{"name" => Enum.join(words, " ")})
    |> out(o, &vault(&1["vault"], "renamed"))
  end

  def run("vault", ["rm", ref], o) do
    HTTP.delete("/vaults/#{enc(ref)}")
    |> out(o, fn r ->
      IO.puts("deleted the vault #{r["deleted"]["name"]} — every page stays on its board")
    end)
  end

  def run("vault", ["map", ref, path], o) do
    if is_nil(o[:board]), do: fail("say which board: --board B (and --folder F for one folder)")

    body = compact(%{"path" => path, "board" => o[:board], "folder" => o[:folder]})

    if o[:dry_run] do
      HTTP.post("/vaults/#{enc(ref)}/mappings", Map.put(body, "dry_run", true))
      |> out(o, &print_preview(&1["preview"], :map))
    else
      HTTP.post("/vaults/#{enc(ref)}/mappings", body) |> out(o, &vault(&1["vault"], "mapped"))
    end
  end

  def run("vault", ["unmap", ref, path], o) do
    if o[:dry_run] do
      HTTP.delete("/vaults/#{enc(ref)}/mappings", path: path, dry_run: "true")
      |> out(o, &print_preview(&1["preview"], :unmap))
    else
      HTTP.delete("/vaults/#{enc(ref)}/mappings", path: path)
      |> out(o, &vault(&1["vault"], "unmapped"))
    end
  end

  def run("vault", ["locate", ref, path], o) do
    HTTP.get("/vaults/#{enc(ref)}/locate", path: path)
    |> out(o, fn r ->
      IO.puts(mapping_line(r["mapping"]))
      if r["rest"] != "", do: IO.puts("  then " <> r["rest"])
    end)
  end

  def run("vault", ["resolve", ref | words], o) when words != [] do
    HTTP.get("/vaults/#{enc(ref)}/resolve", link: Enum.join(words, " "))
    |> out(o, fn r ->
      IO.puts("#{r["page"]["code"]} #{r["page"]["title"]}  " <> Render.dim(r["path"]))
    end)
  end

  def run("vault", ["wanted", ref], o) do
    HTTP.get("/vaults/#{enc(ref)}/wanted")
    |> out(o, fn
      %{"wanted" => []} ->
        IO.puts(Render.dim("nothing wanted: every link in the vault finds a page"))

      %{"wanted" => wanted} ->
        Enum.each(wanted, fn w ->
          from = Enum.map_join(w["from"], ", ", & &1["code"])
          IO.puts("[[#{w["title"]}]]  ×#{w["count"]}  " <> Render.dim("from " <> from))
        end)
    end)
  end

  # What changed since a cursor: what a sync polls. Without --since, the
  # cursor to start from.
  def run("vault", ["changes", ref], o) do
    HTTP.get("/vaults/#{enc(ref)}/changes", since: o[:since], limit: o[:limit])
    |> out(o, fn
      %{"resync" => true} = r ->
        IO.puts(
          "resync: changes from before that cursor are no longer kept — list the vault " <>
            "again, then follow from cursor #{r["cursor"]}"
        )

      r ->
        Enum.each(r["changes"], fn c ->
          what = c["path"] || c["code"] || c["filename"] || c["name"] || "##{c["id"]}"

          IO.puts(
            String.pad_trailing("#{c["cursor"]}", 8) <> "#{c["subject"]} #{c["action"]}  #{what}"
          )
        end)

        IO.puts(
          Render.dim("cursor #{r["cursor"]}" <> if(r["more"], do: " — more to come", else: ""))
        )
    end)
  end

  # A one-time import of an Obsidian vault (W-103 R9): see `Sync.Import`.
  def run("vault", ["import", dir], o) do
    if is_nil(o[:vault]),
      do: fail("say which vault: slipdock vault import #{dir} --vault V")

    root = Path.expand(dir)
    if not FS.dir?(root), do: fail("#{dir} is not a folder")

    if FS.exists?(State.path(root)),
      do:
        fail(
          "#{dir} is already a mirror of a vault, kept level by `slipdock sync` — " <>
            "there is nothing to import"
        )

    vault =
      case HTTP.get("/vaults/#{enc(o[:vault])}") do
        {:ok, %{"vault" => vault}} -> vault
        error -> out(error, o, fn _ -> :ok end)
      end

    if vault["mappings"] == [],
      do:
        fail(
          "#{vault["name"]} has nothing mapped yet — `slipdock vault map` a board into it first"
        )

    listing =
      case Remote.list(vault["id"]) do
        {:ok, listing} -> listing
        {:error, :unauthorized} -> fail("not signed in. Run `slipdock auth`.")
        {:error, msg} -> fail("couldn't list #{vault["name"]}: #{msg}")
      end

    record = Import.record_for(Import.load_record(root), HTTP.base_url(), vault)
    plan = Import.plan(root, vault, listing, record)

    if o[:dry_run] do
      if o[:json],
        do: Render.json(import_json(vault, plan, nil)),
        else: print_import(dir, vault, plan, nil, o)
    else
      {_record, report} = Import.run(root, plan, {Remote, vault["id"]}, record)

      if o[:json],
        do: Render.json(import_json(vault, plan, report)),
        else: print_import(dir, vault, plan, report, o)

      if report.errors != [], do: System.halt(1)
    end
  end

  def run("vault", ["import" | _], _o),
    do: fail("usage: slipdock vault import DIR --vault V [--dry-run]")

  def run("vault", _args, _o),
    do:
      fail(
        "usage: slipdock vault ls | show V | new NAME | rename V NAME | rm V | " <>
          "map V PATH --board B [--folder F] [--dry-run] | unmap V PATH [--dry-run] | locate V PATH | resolve V LINK | " <>
          "wanted V | changes V [--since N] | import DIR --vault V [--dry-run]"
      )

  ## Import -------------------------------------------------------------------

  # Long lists are cut at this many lines unless --all is given.
  @shown 20

  @doc false
  def print_import(dir, vault, plan, report, o \\ []) do
    dry? = is_nil(report)

    IO.puts(
      "import #{dir} into #{Render.bold(vault["name"])}" <>
        if(dry?, do: Render.dim("  (dry run: nothing is written)"), else: "")
    )

    created = if dry?, do: plan.create, else: report.created
    verb = if dry?, do: "would create", else: "created"
    IO.puts("#{verb}: #{counts(created)}")

    created
    |> Enum.group_by(& &1.mapping)
    |> Enum.sort_by(fn {m, _} -> m["path"] end)
    |> Enum.each(fn {m, items} ->
      IO.puts("  " <> String.pad_trailing(target(m), 36) <> " " <> counts(items))
    end)

    there = plan.present ++ plan.imported

    if there != [],
      do: IO.puts("skipped, already there: #{length(there)} " <> Render.dim("(the same bytes)"))

    differs = plan.differs ++ if(dry?, do: [], else: report.differs)

    section(
      "skipped, on the server already and different — left as they are",
      Enum.map(differs, & &1.path),
      o
    )

    section("skipped, no mapping covers them", plan.unmapped, o)
    section("skipped, over the 250 MB limit", plan.too_big, o)

    if plan.ignored != [] do
      IO.puts(
        "skipped, never synced: " <>
          Enum.join(Enum.take(plan.ignored, @shown), ", ") <>
          if(length(plan.ignored) > @shown, do: ", …", else: "")
      )
    end

    {embeds, links} = Enum.split_with(plan.unresolved, & &1.embed)
    section("unresolved links", Enum.map(links, &"#{&1.path} → #{&1.link}"), o)
    section("unresolved embeds", Enum.map(embeds, &"#{&1.path} → #{&1.link}"), o)

    section(
      "plugin syntax, kept as text but not drawn",
      Enum.map(plan.plugins, &"#{&1.path}: #{&1.what}"),
      o
    )

    if report, do: for(e <- report.errors, do: IO.puts(:stderr, "error: #{e.path}: #{e.error}"))

    unless dry?,
      do:
        IO.puts(
          Render.dim(
            "next: `slipdock sync init #{dir} --vault #{vault["name"]}` adopts these files " <>
              "rather than sending them again — but stop Obsidian Sync on this folder first"
          )
        )
  end

  defp counts(items) do
    {pages, files} = Enum.split_with(items, &(&1.kind == "page"))
    "#{plural(length(pages), "note")}, #{plural(length(files), "file")}"
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  defp target(%{"folder" => %{"path" => folder}} = m),
    do: "#{m["path"]} → #{m["board"]["name"]} wiki, #{folder}"

  defp target(m), do: "#{m["path"]} → #{m["board"]["name"]} wiki"

  defp section(_title, [], _o), do: :ok

  defp section(title, lines, o) do
    IO.puts("#{title}: #{length(lines)}")
    shown = if o[:all], do: lines, else: Enum.take(lines, @shown)
    Enum.each(shown, &IO.puts("  " <> &1))

    if length(lines) > length(shown),
      do: IO.puts(Render.dim("  … #{length(lines) - length(shown)} more (--all to see them)"))
  end

  defp import_json(vault, plan, report) do
    item = fn i ->
      %{"path" => i.path, "kind" => i.kind, "mapping" => i.mapping && i.mapping["path"]}
      |> Map.merge(if Map.has_key?(i, :id), do: %{"id" => i.id}, else: %{})
      |> Map.merge(if Map.has_key?(i, :to), do: %{"to" => i.to}, else: %{})
    end

    base = %{
      "vault" => %{"id" => vault["id"], "name" => vault["name"]},
      "dry_run" => is_nil(report),
      "create" => Enum.map(plan.create, item),
      "already_there" => Enum.map(plan.present ++ plan.imported, item),
      "differs" => Enum.map(plan.differs, item),
      "unmapped" => plan.unmapped,
      "too_big" => plan.too_big,
      "ignored" => plan.ignored,
      "unresolved" =>
        Enum.map(plan.unresolved, &%{"path" => &1.path, "link" => &1.link, "embed" => &1.embed}),
      "plugins" => Enum.map(plan.plugins, &%{"path" => &1.path, "what" => &1.what})
    }

    case report do
      nil ->
        base

      r ->
        Map.merge(base, %{
          "created" => Enum.map(r.created, item),
          "differs" => Enum.map(plan.differs ++ r.differs, item),
          "errors" => Enum.map(r.errors, &%{"path" => &1.path, "error" => &1.error})
        })
    end
  end

  @doc false
  # What a mapping would do before it is made (or taken out): `--dry-run`.
  def print_preview(p, kind) do
    verb = if kind == :map, do: "mapping", else: "unmapping"
    IO.puts("#{verb} #{p["path"]} would — nothing is changed yet:")

    if kind == :map do
      preview_group("bring into the vault", p["arriving"], & &1)
      preview_group("take over from another mapping", p["moving"], &move_line/1)
      preview_group("clash with pages already at those paths", p["clashes"], &clash_line/1)
    else
      preview_group("take out of the vault (they stay on their board)", p["leaving"], & &1)
      preview_group("move to another path", p["moving"], &move_line/1)
    end

    case p["mirrors"] || [] do
      [] -> :ok
      names -> IO.puts(Render.dim("synced folders that follow: " <> Enum.join(names, ", ")))
    end
  end

  defp preview_group(_title, nil, _fun), do: :ok
  defp preview_group(_title, %{"count" => 0}, _fun), do: :ok

  defp preview_group(title, %{"count" => n, "sample" => sample}, fun) do
    IO.puts("  #{title}: #{n}")
    Enum.each(sample, &IO.puts("    " <> fun.(&1)))
    if n > length(sample), do: IO.puts(Render.dim("    … #{n - length(sample)} more"))
  end

  defp move_line(%{"from" => same, "to" => same}), do: same
  defp move_line(%{"from" => from, "to" => to}), do: "#{from} → #{to}"

  defp clash_line(%{"path" => path, "board" => board}), do: "#{path} (on #{board})"
  defp clash_line(other), do: inspect(other)

  defp vaults([]), do: IO.puts(Render.dim("no vaults — `slipdock vault new NAME` makes one"))
  defp vaults(list), do: Enum.each(list, &vault/1)

  defp vault(v, verb \\ nil) do
    head = Render.bold(v["name"]) <> "  " <> Render.dim("id #{v["id"]}")
    IO.puts(if verb, do: "#{verb} " <> head, else: head)

    case v["mappings"] do
      [] -> IO.puts("  " <> Render.dim("nothing mapped yet"))
      mappings -> Enum.each(mappings, &IO.puts("  " <> mapping_line(&1)))
    end

    case v["overlaps"] || [] do
      [] ->
        :ok

      [first | _] = overlaps ->
        IO.puts(
          "  warning: #{length(overlaps)} page(s) of #{first["board"]} sit under " <>
            "#{first["under"]}, which #{first["owner"]}'s mapping owns (#{first["path"]}…): " <>
            "move them to #{first["owner"]} or take that mapping out"
        )
    end

    # The folders it is synced to, from servers that record them.
    for m <- v["mirrors"] || [] do
      IO.puts(
        "  " <> Render.dim("synced to #{m["label"] || "a token"}, last #{m["last_synced_at"]}")
      )
    end
  end

  @doc false
  def mapping_line(m) do
    target =
      case m["folder"] do
        nil -> "#{m["board"]["name"]} wiki"
        folder -> "#{m["board"]["name"]} wiki, folder #{folder["path"]}"
      end

    pages =
      case m["pages"] do
        nil -> ""
        1 -> " · 1 page"
        n -> " · #{n} pages"
      end

    String.pad_trailing(m["path"], 16) <>
      " → " <> target <> "  " <> Render.dim((m["board"]["code"] || "") <> pages)
  end
end
