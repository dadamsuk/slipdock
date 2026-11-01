defmodule SlipdockCLI.WholeWiki do
  @moduledoc false

  alias SlipdockCLI.FS

  # Your wiki as a whole (W-2201): your Knowledge Base and every board you
  # own, as one tree. A person has one, so nothing names it; a path is
  # relative to its top, "/" the top itself. `slipdock wiki` routes its
  # whole-wiki subcommands here (`subcommands/0`); the per-board ones, and
  # the plain listing, stay in `SlipdockCLI.Wiki`.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render
  alias SlipdockCLI.Sync.{Import, Remote, State}

  @commands ~w(vault drive)
  @subcommands ~w(show set locate resolve wanted changes tree import)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  @doc "The `slipdock wiki` subcommands this module answers."
  def subcommands, do: @subcommands

  # There are no vaults any more: say where things went, and stop.
  def run("vault", _args, _o), do: fail(vault_gone())

  # Your Google Drive connection, and your wiki's recordings folder (W-1690).
  def run("drive", ["status"], o), do: HTTP.get("/me/drive") |> out(o, &drive/1)
  def run("drive", [], o), do: run("drive", ["status"], o)

  @doc false
  def vault_gone,
    do:
      "there are no vaults any more: you have one wiki. Use `slipdock wiki` " <>
        "(show, set, locate, resolve, wanted, changes, tree, import)"

  @doc "`slipdock wiki <sub> ...`, for a subcommand in `subcommands/0`."
  def wiki(["show"], o), do: HTTP.get("/wiki") |> out(o, &show(&1["wiki"]))

  # Where on your Google Drive its meeting recordings are (W-1690); "" clears
  # it. The server checks the folder is there. And how it is reached in the
  # web app (#1204): b then --shortcut, and Ctrl+Shift and its --hotkey digit.
  def wiki(["set"], o) do
    body =
      compact(%{
        "recordings_folder" => o[:recordings_folder],
        "shortcut" => o[:shortcut],
        "hotkey" => o[:hotkey]
      })

    if body == %{},
      do: fail("say what to set: --shortcut K, --hotkey 0-9|none or --recordings-folder PATH")

    HTTP.patch("/wiki", body)
    |> out(o, fn r ->
      w = r["wiki"]

      if Map.has_key?(body, "recordings_folder") do
        IO.puts(
          if w["recordings_folder"],
            do: "your wiki plays its recordings from #{w["recordings_folder"]} on Google Drive",
            else: "your wiki has no recordings folder now"
        )
      end

      if Map.has_key?(body, "shortcut"),
        do: IO.puts("b then #{w["shortcut"]} now opens your wiki")

      if Map.has_key?(body, "hotkey") do
        IO.puts(
          if w["hotkey"],
            do: "Ctrl+Shift+#{w["hotkey"]} now opens your wiki",
            else: "your wiki has no hotkey now"
        )
      end
    end)
  end

  def wiki(["locate", path], o) do
    HTTP.get("/wiki/locate", path: path)
    |> out(o, fn r ->
      IO.puts(board_line(r["board"]))
      if r["rest"] != "", do: IO.puts("  then " <> r["rest"])
    end)
  end

  def wiki(["resolve" | words], o) when words != [] do
    HTTP.get("/wiki/resolve", link: Enum.join(words, " "))
    |> out(o, fn r ->
      IO.puts("#{r["page"]["code"]} #{r["page"]["title"]}  " <> Render.dim(r["path"]))
    end)
  end

  def wiki(["wanted"], o) do
    HTTP.get("/wiki/wanted")
    |> out(o, fn
      %{"wanted" => []} ->
        IO.puts(Render.dim("nothing wanted: every link in your wiki finds a page"))

      %{"wanted" => wanted} ->
        Enum.each(wanted, fn w ->
          from = Enum.map_join(w["from"], ", ", & &1["code"])
          IO.puts("[[#{w["title"]}]]  ×#{w["count"]}  " <> Render.dim("from " <> from))
        end)
    end)
  end

  # What changed since a cursor: what a sync polls. Without --since, the
  # cursor to start from.
  def wiki(["changes"], o) do
    HTTP.get("/wiki/changes", since: o[:since], limit: o[:limit])
    |> out(o, fn
      %{"resync" => true} = r ->
        IO.puts(
          "resync: changes from before that cursor are no longer kept — list your wiki " <>
            "again, then follow from cursor #{r["cursor"]}"
        )

      r ->
        Enum.each(r["changes"], fn c ->
          IO.puts(
            String.pad_trailing("#{c["cursor"]}", 8) <>
              "#{c["subject"]} #{c["action"]}  #{change_what(c, o)}"
          )
        end)

        IO.puts(
          Render.dim("cursor #{r["cursor"]}" <> if(r["more"], do: " — more to come", else: ""))
        )
    end)
  end

  # Everything in your wiki by where it is, each directory by its name:
  # full titles, or short names with --short-names.
  def wiki(["tree"], o), do: HTTP.get("/wiki/sync") |> out(o, &tree(&1, o))

  # A one-time import of an Obsidian vault (W-103 R9): see `Sync.Import`.
  def wiki(["import", dir], o) do
    if o[:vault],
      do: IO.puts(:stderr, "note: --vault is no longer needed: you have one wiki, and it is that")

    root = Path.expand(dir)
    if not FS.dir?(root), do: fail("#{dir} is not a folder")

    if FS.exists?(State.path(root)),
      do:
        fail(
          "#{dir} is already a mirror of your wiki, kept level by `slipdock sync` — " <>
            "there is nothing to import"
        )

    wiki =
      case HTTP.get("/wiki") do
        {:ok, %{"wiki" => wiki}} -> wiki
        error -> out(error, o, fn _ -> :ok end)
      end

    if wiki["boards"] == [],
      do: fail("your wiki has nothing in it yet — make a board first")

    listing =
      case Remote.list(:wiki) do
        {:ok, listing} -> listing
        {:error, :unauthorized} -> fail("not signed in. Run `slipdock auth`.")
        {:error, msg} -> fail("couldn't list your wiki: #{msg}")
      end

    record = Import.record_for(Import.load_record(root), HTTP.base_url())
    plan = Import.plan(root, wiki, listing, record)

    if o[:dry_run] do
      if o[:json],
        do: Render.json(import_json(plan, nil)),
        else: print_import(dir, plan, nil, o)
    else
      {_record, report} = Import.run(root, plan, {Remote, :wiki}, record)

      if o[:json],
        do: Render.json(import_json(plan, report)),
        else: print_import(dir, plan, report, o)

      if report.errors != [], do: System.halt(1)
    end
  end

  def wiki(["import" | _], _o), do: fail("usage: slipdock wiki import DIR [--dry-run] [--all]")

  def wiki(_args, _o),
    do:
      fail(
        "usage: slipdock wiki show | " <>
          "wiki set [--shortcut K] [--hotkey 0-9|none] [--recordings-folder PATH] | " <>
          "wiki locate PATH | wiki resolve LINK | wiki wanted | " <>
          "wiki changes [--since N] | wiki tree [--short-names] | wiki import DIR [--dry-run]"
      )

  ## Import -------------------------------------------------------------------

  # Long lists are cut at this many lines unless --all is given.
  @shown 20

  @doc false
  def print_import(dir, plan, report, o \\ []) do
    dry? = is_nil(report)

    IO.puts(
      "import #{dir} into your wiki" <>
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
            "next: `slipdock sync init #{dir}` adopts these files rather than sending " <>
              "them again — but stop Obsidian Sync on this folder first"
          )
        )
  end

  defp change_what(%{"from_path" => from} = c, o) when is_binary(from),
    do: "#{from} → #{change_name(c, o)}"

  defp change_what(c, o), do: change_name(c, o)

  defp change_name(c, o) do
    (o[:short_names] && c["short_name"]) || c["path"] || c["code"] || c["filename"] || c["name"] ||
      "##{c["id"]}"
  end

  # The listing as a tree: every directory with what it is called, and what
  # is in each. Disk names are for disks, so a path is only the last resort.
  defp tree(listing, o) do
    short? = o[:short_names] == true

    dirs =
      (listing["boards"] || []) ++
        (listing["virtual_folders"] || []) ++
        Enum.map(listing["folder_details"] || %{}, fn {path, d} -> Map.put(d, "path", path) end)

    named = Map.new(dirs, &{&1["path"], Render.folder_name(&1, short?)})
    archived = Map.new(dirs, &{&1["path"], &1["archived"]})

    folders = for path <- listing["folders"] || [], do: {path, tree_dir(path, named, archived)}

    files =
      for e <- listing["entries"] || [] do
        {e["path"], tree_line(e["path"], e["title"] || e["name"], e["archived"])}
      end

    (folders ++ files)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {_path, line} -> IO.puts(line) end)
  end

  defp tree_dir(path, named, archived),
    do: tree_line(path, (named[path] || Path.basename(path)) <> "/", archived[path])

  defp tree_line(path, name, archived) do
    depth = length(String.split(path, "/")) - 1

    String.duplicate("  ", depth) <>
      to_string(name || Path.basename(path)) <>
      if(archived, do: Render.dim("  archived"), else: "")
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

  defp import_json(plan, report) do
    item = fn i ->
      %{"path" => i.path, "kind" => i.kind, "board" => i.board && i.board["path"]}
      |> Map.merge(if Map.has_key?(i, :id), do: %{"id" => i.id}, else: %{})
      |> Map.merge(if Map.has_key?(i, :to), do: %{"to" => i.to}, else: %{})
    end

    base = %{
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

  defp drive(%{"drive" => d} = r) do
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

    # The server answers with a list, of one now that a person has one wiki.
    folder =
      Enum.find_value(r["vaults"] || [], & &1["recordings_folder"]) ||
        get_in(r, ["wiki", "recordings_folder"])

    IO.puts("  your wiki: " <> (folder || Render.dim("no recordings folder")))
  end

  defp show(w) do
    IO.puts(Render.bold("Your wiki"))

    if kb = w["knowledge_base"],
      do: IO.puts("  " <> Render.dim("Knowledge Base: #{kb["name"]} (#{kb["code"]})"))

    case w["boards"] do
      [] -> IO.puts("  " <> Render.dim("no boards yet"))
      boards -> Enum.each(boards || [], &IO.puts("  " <> board_line(&1)))
    end

    if w["pages"], do: IO.puts("  " <> Render.dim(plural(w["pages"], "page")))

    if w["recordings_folder"],
      do: IO.puts("  " <> Render.dim("recordings: #{w["recordings_folder"]} on Google Drive"))

    keys =
      [w["shortcut"] && "b then #{w["shortcut"]}", w["hotkey"] && "Ctrl+Shift+#{w["hotkey"]}"]
      |> Enum.reject(&is_nil/1)

    if keys != [], do: IO.puts("  " <> Render.dim("opens with " <> Enum.join(keys, " or ")))

    # The folders it is synced to, from servers that record them.
    for m <- w["mirrors"] || [] do
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
