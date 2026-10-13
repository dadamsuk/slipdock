defmodule SlipdockCLI.Sync.Import do
  @moduledoc false

  alias SlipdockCLI.FS

  # `slipdock vault import DIR --vault V` (W-103 R9): an existing Obsidian
  # vault brought into a Slipdock vault once, each path routed through the
  # vault's mappings. One way only: nothing on the server comes down, and the
  # folder's own files are never touched.
  #
  # Notes go up as pages with their bytes as they are (front matter, tags,
  # aliases, links, Excalidraw's `.excalidraw.md` and Meld ciphertext all
  # ride along untouched); everything else goes up as a file at the same
  # vault path. Whatever is already on the server at a path is left alone.
  #
  # What was sent is remembered in `DIR/.slipdock/import.json`: each path's
  # id on the server, the hash of the file as it was read, and the hash the
  # server answered with. That record is what lets `slipdock sync init` on
  # the same folder adopt the files rather than send them all again (R9.4),
  # and what lets an import cut short be run again without doubling up.

  alias SlipdockCLI.Sync.{Engine, Scan, State}

  @record "import.json"

  # The server's limit on an uploaded file.
  @max_size 250 * 1024 * 1024

  # Fenced blocks that only an Obsidian plugin draws (or Obsidian's own
  # embedded search); here they stay as the text they are.
  @plugin_blocks %{
    "dataview" => "Dataview query",
    "dataviewjs" => "DataviewJS script",
    "tasks" => "Tasks query",
    "query" => "embedded search",
    "button" => "Buttons block",
    "tracker" => "Tracker chart",
    "chart" => "Charts block"
  }

  def record_path(root), do: Path.join([root, State.dir_name(), @record])

  @doc "The import record left in `root`, or nil."
  def load_record(root) do
    with {:ok, text} <- FS.read(record_path(root)),
         {record, _, ""} <- :json.decode(text, :ok, %{null: nil}) do
      record
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def save_record(root, record) do
    FS.mkdir_p!(Path.join(root, State.dir_name()))
    target = record_path(root)
    tmp = target <> ".#{System.unique_integer([:positive])}.tmp"
    FS.write!(tmp, SlipdockCLI.HTTP.encode(record))
    FS.rename!(tmp, target)
    record
  end

  def drop_record(root), do: FS.rm(record_path(root))

  @doc """
  After a sync pass that adopted from the record (`imported` not nil): the
  record is spent once a pass has had no errors, so every path in it has
  been reconciled; until then the next pass adopts from it again.
  """
  def spent(_root, nil, _errors), do: :kept

  def spent(root, _imported, []) do
    drop_record(root)
    :dropped
  end

  def spent(_root, _imported, _errors), do: :kept

  @doc """
  The entries of a record that belong to `vault_id`, for the sync engine to
  adopt (`Engine.run/4`'s `:imported`); nil when there are none.
  """
  def entries_for(nil, _vault_id), do: nil

  def entries_for(record, vault_id) do
    if get_in(record, ["vault", "id"]) == vault_id, do: record["entries"], else: nil
  end

  ## The plan -----------------------------------------------------------------

  @doc """
  What an import of `root` into `vault` would do, given the vault's
  `listing` as the sync API answers it and a previous `record` (or nil):

      %{create: [item], present: [item], imported: [item], differs: [item],
        unmapped: [path], too_big: [path], ignored: [path],
        unresolved: [%{path:, link:, embed:}], plugins: [%{path:, what:}]}

  An item is `%{path:, kind:, sha:, size:, mapping:}`, plus `id:` and `hash:`
  for one the server already has. `create` is in the order to send it:
  shallow first, a page's own `index.md` before what sits beside it.
  """
  def plan(root, vault, listing, record \\ nil) do
    local = Scan.scan(root)
    server = listing["entries"] || []
    by_path = Map.new(server, &{String.downcase(&1["path"]), &1})
    by_key = MapSet.new(server, &{kind(&1), &1["id"]})
    recorded = entries_for(record, vault["id"]) || %{}

    items =
      Enum.map(local, fn {path, f} ->
        %{
          path: path,
          kind: kind_of_path(path),
          sha: f.sha,
          size: f.size,
          mapping: route(vault["mappings"] || [], path)
        }
      end)

    sorted =
      Enum.reduce(items, empty(), fn item, acc ->
        r = recorded[item.path]
        s = by_path[String.downcase(item.path)]

        cond do
          is_nil(item.mapping) ->
            add(acc, :unmapped, item.path)

          r && r["sha"] == item.sha && MapSet.member?(by_key, {r["kind"], r["id"]}) ->
            add(acc, :imported, Map.merge(item, %{id: r["id"], hash: r["hash"]}))

          s && kind(s) == item.kind && s["hash"] == item.sha ->
            add(acc, :present, Map.merge(item, %{id: s["id"], hash: s["hash"]}))

          s ->
            add(acc, :differs, Map.merge(item, %{id: s["id"], hash: s["hash"]}))

          item.kind == "file" and item.size > @max_size ->
            add(acc, :too_big, item.path)

          true ->
            add(acc, :create, item)
        end
      end)
      |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)

    notes = for {path, _} <- local, Scan.markdown?(path), do: path
    {unresolved, plugins} = examine(root, notes, Map.keys(local), server)

    sorted
    |> Map.update!(:create, fn list -> Enum.sort_by(list, &order(&1.path)) end)
    |> Map.merge(%{
      ignored: Scan.ignored_paths(root),
      unresolved: unresolved,
      plugins: plugins ++ canvases(Map.keys(local))
    })
  end

  defp empty,
    do: %{create: [], present: [], imported: [], differs: [], unmapped: [], too_big: []}

  defp add(acc, key, item), do: Map.update!(acc, key, &[item | &1])

  defp kind(%{"kind" => "file"}), do: "file"
  defp kind(_), do: "page"

  defp kind_of_path(path), do: if(Scan.markdown?(path), do: "page", else: "file")

  defp order(path) do
    {length(String.split(path, "/")), if(Path.basename(path) == "index.md", do: 0, else: 1), path}
  end

  @doc """
  The mapping a vault path lands in: the longest mapped prefix, compared
  without regard to case (W-103 R1.3). Nil when no mapping covers it.
  """
  def route(mappings, path) do
    lower = String.downcase(path)

    mappings
    |> Enum.filter(fn m ->
      prefix = m["path"] |> String.trim("/") |> String.downcase()
      prefix == "" or String.starts_with?(lower, prefix <> "/")
    end)
    |> Enum.max_by(fn m -> String.length(String.trim(m["path"], "/")) end, fn -> nil end)
  end

  ## Links and plugin syntax --------------------------------------------------

  # Every `[[link]]`, `![[embed]]` and local Markdown link in the notes,
  # checked against what the vault will hold once the import is done — the
  # folder's own files and what the server has already — by Obsidian's
  # rules: a bare name finds a note or file of that name anywhere, a path
  # finds one whose path ends with it, and a front matter alias counts as a
  # name. Code is not looked inside.
  defp examine(root, notes, paths, server) do
    texts = Map.new(notes, fn path -> {path, read(root, path)} end)
    index = index(paths, texts, server)

    Enum.reduce(Enum.sort(notes), {[], []}, fn path, {unresolved, plugins} ->
      text = texts[path]
      prose = strip_code(text)

      missing =
        prose
        |> links()
        |> Enum.reject(&resolves?(index, &1.target, path))
        |> Enum.map(&%{path: path, link: &1.text, embed: &1.embed})
        |> Enum.uniq()

      {unresolved ++ missing, plugins ++ Enum.map(plugin_syntax(text), &%{path: path, what: &1})}
    end)
  end

  defp read(root, path) do
    case FS.read(Path.join(root, path)) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp index(paths, texts, server) do
    server_paths = Enum.map(server, & &1["path"])
    titles = for e <- server, is_binary(e["title"]), do: String.downcase(e["title"])
    aliases = texts |> Map.values() |> Enum.flat_map(&aliases/1) |> Enum.map(&String.downcase/1)
    all = Enum.map(paths ++ server_paths, &String.downcase/1)

    names =
      Enum.flat_map(all, fn p ->
        base = Path.basename(p)
        if String.ends_with?(base, ".md"), do: [base, Path.rootname(base)], else: [base]
      end)

    full = Enum.flat_map(all, fn p -> [p, String.replace_suffix(p, ".md", "")] end)

    %{names: MapSet.new(names ++ titles ++ aliases), full: MapSet.new(full), paths: all}
  end

  defp resolves?(index, target, from) do
    t = target |> String.trim() |> String.trim_leading("/") |> String.downcase()

    cond do
      t == "" ->
        true

      String.starts_with?(t, "../") or String.starts_with?(t, "./") ->
        rel = Path.join(Path.dirname(String.downcase(from)), t) |> normalise()
        MapSet.member?(index.full, rel) or MapSet.member?(index.full, rel <> ".md")

      String.contains?(t, "/") ->
        rel = Path.join(Path.dirname(String.downcase(from)), t) |> normalise()

        MapSet.member?(index.full, t) or MapSet.member?(index.full, rel) or
          Enum.any?(index.paths, fn p ->
            String.ends_with?(p, "/" <> t) or String.ends_with?(p, "/" <> t <> ".md")
          end)

      true ->
        MapSet.member?(index.names, t)
    end
  end

  # `a/b/../c` → `a/c`, without touching the real file system.
  defp normalise(path) do
    path
    |> String.split("/")
    |> Enum.reduce([], fn
      ".", acc -> acc
      "", acc -> acc
      "..", [_ | acc] -> acc
      "..", [] -> []
      seg, acc -> [seg | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("/")
  end

  @wikilink ~r/(!?)\[\[([^\[\]\n]+?)\]\]/u
  @mdlink ~r/(!?)\[[^\[\]\n]*\]\(<?([^()<>\s]+)>?(?:\s+"[^"\n]*")?\)/u

  @doc false
  # The links in a note's prose: `%{target:, text:, embed:}`. A link to a
  # heading or block on the same page (`[[#Heading]]`), and the card
  # reference `[[#412]]`, have no other page to find.
  def links(prose) do
    wiki =
      for [_, bang, inner] <- Regex.scan(@wikilink, prose) do
        target =
          inner |> String.split("|", parts: 2) |> hd() |> String.split("#", parts: 2) |> hd()

        %{target: target, text: "#{bang}[[#{inner}]]", embed: bang == "!"}
      end

    md =
      for [whole, bang, href] <- Regex.scan(@mdlink, prose),
          not Regex.match?(~r/^[a-z][a-z0-9+.-]*:/i, href),
          not String.starts_with?(href, "#") do
        target = href |> String.split("#", parts: 2) |> hd() |> URI.decode()
        %{target: target, text: whole, embed: bang == "!"}
      end

    Enum.reject(wiki ++ md, &(String.trim(&1.target) == ""))
  end

  # Fenced blocks and inline code taken out, so a link written as an example
  # is not counted.
  defp strip_code(text) do
    text
    |> String.replace(~r/^(```|~~~)[^\n]*\n.*?^\1[^\n]*$/ms, "")
    |> String.replace(~r/`[^`\n]*`/, "")
  end

  # Aliases from front matter: `aliases: [A, B]`, `aliases: A`, or a list
  # of `- A` lines under it (`alias:` too, Obsidian's older spelling).
  defp aliases(text) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---\s*(\r?\n|\z)/s, text) do
      [_, yaml | _] ->
        lines = String.split(yaml, ~r/\r?\n/)

        lines
        |> Enum.with_index()
        |> Enum.flat_map(fn {line, i} ->
          case Regex.run(~r/^(aliases|alias):\s*(.*)$/, line) do
            [_, _, ""] ->
              lines
              |> Enum.drop(i + 1)
              |> Enum.take_while(&Regex.match?(~r/^\s*-\s+/, &1))
              |> Enum.map(&(&1 |> String.replace(~r/^\s*-\s+/, "") |> unquote_yaml()))

            [_, _, "[" <> rest] ->
              rest |> String.trim_trailing("]") |> String.split(",") |> Enum.map(&unquote_yaml/1)

            [_, _, value] ->
              [unquote_yaml(value)]

            nil ->
              []
          end
        end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp unquote_yaml(value), do: value |> String.trim() |> String.trim("\"") |> String.trim("'")

  @doc false
  # What in a note only an Obsidian plugin understands. Kept as written;
  # the dry run says where, so nobody is surprised it doesn't render.
  def plugin_syntax(text) do
    blocks =
      for [_, lang] <- Regex.scan(~r/^(?:```|~~~)\s*([\w-]+)/m, text),
          what = @plugin_blocks[String.downcase(lang)],
          do: what

    inline =
      if Regex.match?(~r/`\$?=[^`\n]+`/, text), do: ["inline Dataview expression"], else: []

    templater = if String.contains?(text, "<%"), do: ["Templater command"], else: []

    kanban =
      if Regex.match?(~r/\A---\r?\n(?:.*\r?\n)*?kanban-plugin:/, text),
        do: ["Kanban plugin board"],
        else: []

    Enum.uniq(blocks ++ inline ++ templater ++ kanban)
  end

  defp canvases(paths) do
    for p <- Enum.sort(paths),
        String.downcase(Path.extname(p)) == ".canvas",
        do: %{path: p, what: "Canvas (kept as a file, not drawn)"}
  end

  ## Doing it -----------------------------------------------------------------

  @doc """
  Sends what `plan` would create, through `remote` (`{module, ctx}`
  implementing `SlipdockCLI.Sync.Remote`), and records every path the
  server now holds — created now, or found already there unchanged — in the
  import record. Returns `{record, %{created: [..], differs: [..], errors: [..]}}`.
  The record is saved as it grows (`:save` every 25 writes), so an import
  cut short can be run again.
  """
  def run(root, plan, {mod, ctx}, record, opts \\ []) do
    save = opts[:save] || fn record -> save_record(root, record) end

    record =
      Enum.reduce(plan.present ++ plan.imported, record, &remember(&2, &1, &1.id, &1.hash))

    {record, report, _n} =
      Enum.reduce(plan.create, {record, %{created: [], differs: [], errors: []}, 0}, fn item,
                                                                                        {record,
                                                                                         report,
                                                                                         n} ->
        result =
          case item.kind do
            "page" ->
              case FS.read(Path.join(root, item.path)) do
                {:ok, content} ->
                  mod.write(ctx, nil, %{"path" => item.path, "content" => content})

                {:error, reason} ->
                  {:error, "can't read it (#{reason})"}
              end

            "file" ->
              mod.write_file(ctx, nil, %{"path" => item.path}, Path.join(root, item.path))
          end

        case result do
          {:ok, written} ->
            record = remember(record, item, written["id"], written["hash"])
            n = n + 1
            if rem(n, 25) == 0, do: save.(record)
            {record, add_to(report, :created, Map.put(item, :to, written["path"])), n}

          {:conflict, current} ->
            {record, add_to(report, :differs, Map.put(item, :id, current["id"])), n}

          {:error, :unauthorized} ->
            {record, add_to(report, :errors, %{path: item.path, error: "not signed in"}), n}

          {:error, msg} ->
            {record, add_to(report, :errors, %{path: item.path, error: msg}), n}
        end
      end)

    save.(record)
    {record, Map.new(report, fn {k, v} -> {k, Enum.reverse(v)} end)}
  end

  defp add_to(report, key, item), do: Map.update!(report, key, &[item | &1])

  defp remember(record, item, id, hash) do
    entry = %{"kind" => item.kind, "id" => id, "sha" => item.sha, "hash" => hash}
    put_in(record, ["entries", item.path], entry)
  end

  @doc "A fresh record for `vault` on the server at `url`, or the one already there for it."
  def record_for(nil, url, vault), do: new_record(url, vault)

  def record_for(record, url, vault) do
    if get_in(record, ["vault", "id"]) == vault["id"],
      do: Map.put_new(record, "entries", %{}),
      else: new_record(url, vault)
  end

  defp new_record(url, vault) do
    %{
      "version" => 1,
      "url" => url,
      "vault" => %{"id" => vault["id"], "name" => vault["name"]},
      "host" => Engine.hostname(),
      "entries" => %{}
    }
  end
end
