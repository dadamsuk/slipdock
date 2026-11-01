defmodule SlipdockCLI.Vaults do
  @moduledoc false

  alias SlipdockCLI.FS

  # The vault: every board you own as one Obsidian-style tree (W-2201). It is
  # named by its id or its name; a path is vault-relative, "/" the root.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render
  alias SlipdockCLI.Sync.{Import, Remote, State}

  @commands ~w(vault drive)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("vault", ["ls"], o), do: HTTP.get("/vaults") |> out(o, &vaults(&1["vaults"]))
  def run("vault", [], o), do: run("vault", ["ls"], o)

  def run("vault", ["show", ref], o),
    do: HTTP.get("/vaults/#{enc(ref)}") |> out(o, &vault(&1["vault"]))

  def run("vault", ["rename", ref | words], o) when words != [] do
    HTTP.patch("/vaults/#{enc(ref)}", %{"name" => Enum.join(words, " ")})
    |> out(o, &vault(&1["vault"], "renamed"))
  end

  # Where on the owner's Google Drive the vault's meeting recordings are
  # (W-1690); "" clears it. The server checks the folder is there. And how it
  # is reached in the web app (#1204): b then --shortcut, and Ctrl+Shift and
  # its --hotkey digit.
  def run("vault", ["set", ref], o) do
    body =
      compact(%{
        "recordings_folder" => o[:recordings_folder],
        "shortcut" => o[:shortcut],
        "hotkey" => o[:hotkey]
      })

    if body == %{},
      do: fail("say what to set: --shortcut K, --hotkey 0-9|none or --recordings-folder PATH")

    HTTP.patch("/vaults/#{enc(ref)}", body)
    |> out(o, fn r ->
      v = r["vault"]

      if Map.has_key?(body, "recordings_folder") do
        IO.puts(
          if v["recordings_folder"],
            do:
              "#{v["name"]} plays its recordings from #{v["recordings_folder"]} on Google Drive",
            else: "#{v["name"]} has no recordings folder now"
        )
      end

      if Map.has_key?(body, "shortcut"),
        do: IO.puts("b then #{v["shortcut"]} now opens #{v["name"]}")

      if Map.has_key?(body, "hotkey") do
        IO.puts(
          if v["hotkey"],
            do: "Ctrl+Shift+#{v["hotkey"]} now opens #{v["name"]}",
            else: "#{v["name"]} has no hotkey now"
        )
      end
    end)
  end

  # Your Google Drive connection, and each vault's recordings folder (W-1690).
  def run("drive", ["status"], o), do: HTTP.get("/me/drive") |> out(o, &drive/1)
  def run("drive", [], o), do: run("drive", ["status"], o)

  def run("vault", ["locate", ref, path], o) do
    HTTP.get("/vaults/#{enc(ref)}/locate", path: path)
    |> out(o, fn r ->
      IO.puts(board_line(r["board"]))
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

    if vault["boards"] == [],
      do: fail("#{vault["name"]} has no boards yet — make a board first")

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
        "usage: slipdock vault ls | show V | rename V NAME | " <>
          "set V [--shortcut K] [--hotkey 0-9|none] [--recordings-folder PATH] | " <>
          "locate V PATH | resolve V LINK | " <>
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
    |> Enum.group_by(& &1.board)
    |> Enum.sort_by(fn {b, _} -> b["path"] end)
    |> Enum.each(fn {b, items} ->
      IO.puts("  " <> String.pad_trailing(target(b), 36) <> " " <> counts(items))
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

    section("skipped, in no board's folder", plan.outside, o)
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

  defp target(b), do: "#{b["path"]} → #{b["name"]} wiki"

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
      %{"path" => i.path, "kind" => i.kind, "board" => i.board && i.board["path"]}
      |> Map.merge(if Map.has_key?(i, :id), do: %{"id" => i.id}, else: %{})
      |> Map.merge(if Map.has_key?(i, :to), do: %{"to" => i.to}, else: %{})
    end

    base = %{
      "vault" => %{"id" => vault["id"], "name" => vault["name"]},
      "dry_run" => is_nil(report),
      "create" => Enum.map(plan.create, item),
      "already_there" => Enum.map(plan.present ++ plan.imported, item),
      "differs" => Enum.map(plan.differs, item),
      "outside" => plan.outside,
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

  defp vaults(list), do: Enum.each(list, &vault/1)

  defp drive(%{"drive" => d, "vaults" => vaults}) do
    IO.puts(
      case d["status"] do
        "connected" ->
          "Google Drive: connected" <> if(d["email"], do: " as #{d["email"]}", else: "")

        "revoked" ->
          "Google Drive: no longer accepted by Google — connect again (Account → Settings)"

        "not_connected" ->
          "Google Drive: not connected — connect it on Account → Settings"

        _ ->
          "Google Drive: not set up on this server"
      end
    )

    for v <- vaults do
      IO.puts(
        "  #{v["name"]}: " <>
          (v["recordings_folder"] || Render.dim("no recordings folder"))
      )
    end
  end

  defp vault(v, verb \\ nil) do
    head = Render.bold(v["name"]) <> "  " <> Render.dim("id #{v["id"]}")
    IO.puts(if verb, do: "#{verb} " <> head, else: head)

    case v["boards"] do
      [] -> IO.puts("  " <> Render.dim("no boards yet"))
      boards -> Enum.each(boards, &IO.puts("  " <> board_line(&1)))
    end

    if v["pages"], do: IO.puts("  " <> Render.dim(plural(v["pages"], "page")))

    if v["recordings_folder"],
      do: IO.puts("  " <> Render.dim("recordings: #{v["recordings_folder"]} on Google Drive"))

    keys =
      [v["shortcut"] && "b then #{v["shortcut"]}", v["hotkey"] && "Ctrl+Shift+#{v["hotkey"]}"]
      |> Enum.reject(&is_nil/1)

    if keys != [], do: IO.puts("  " <> Render.dim("opens with " <> Enum.join(keys, " or ")))

    # The folders it is synced to, from servers that record them.
    for m <- v["mirrors"] || [] do
      IO.puts(
        "  " <> Render.dim("synced to #{m["label"] || "a token"}, last #{m["last_synced_at"]}")
      )
    end
  end

  @doc false
  def board_line(b) do
    archived = if b["archived"], do: " · archived", else: ""
    String.pad_trailing(b["path"], 16) <> " " <> Render.dim((b["code"] || "") <> archived)
  end
end
