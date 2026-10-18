defmodule SlipdockCLI.Sync.Engine do
  @moduledoc false

  alias SlipdockCLI.FS

  # One pass of `slipdock sync` (W-103 R2.2–R2.5, R2.9): the folder and the
  # vault brought level, both ways.
  #
  # Three readings meet: what the state file says both sides agreed on last
  # time (path → kind, id and hash), what is on disk now (path → hash), and
  # what the server lists now ({kind, id} → path and hash). A Markdown file
  # is a page; anything else — an image, a PDF, a drawing — is a file kept at
  # the same vault path. Both go by the same rules:
  #
  #   * changed on one side only — the change goes to the other;
  #   * changed on both — if the two now read the same, nothing to do;
  #     otherwise the server's version keeps the path and the local one is
  #     moved beside it as `Name (conflict YYYY-MM-DD host).md`, then sent up
  #     as one of its own. Nothing is ever silently lost (R2.4);
  #   * gone locally — archived on the server, never purged; gone on the
  #     server — removed here, unless it was edited here, in which case it is
  #     sent up again as a new one (R2.5);
  #   * gone from one path and a file with the same hash new at another — a
  #     rename or a move, the same page or file (R2.3). A renamed file that
  #     is not a note is moved on the server without sending its bytes again.
  #
  # Folders come last, once every file is where it belongs: one new on the
  # server is made here, even empty, and one deleted there goes from here —
  # but only when nothing is left in it but empty folders, so a file the
  # server never had is never lost with it.
  #
  # Every write to the server names the hash it was made against, so a change
  # made on the server since this pass listed it is a conflict, not an
  # overwrite. Every write to disk checks the file still holds what this
  # pass thinks it holds, so a change made locally while the pass ran is
  # moved aside rather than overwritten.
  #
  # A pass can be one-way (`direction: :down` for `sync from-server`, `:up`
  # for `sync to-server`). Whatever it may not do is left in the state as
  # both sides last agreed it, so the next pass still finds it waiting and
  # nothing is taken as level that isn't; the report lists it as held.

  alias SlipdockCLI.Sync.{Scan, State}

  @doc """
  Runs one pass over `root` with `state`, against `remote` — `{module, ctx}`
  implementing `SlipdockCLI.Sync.Remote`. Returns `{:ok, state, report}` or
  `{:error, reason}` when the server could not be listed at all.
  """
  def run(root, state, {mod, ctx} = remote, opts \\ []) do
    with {:ok, listing} <- mod.list(ctx) do
      local = Scan.scan(root, opts[:cache] || %{})
      patterns = Scan.ignores(root)

      # Stubs of what is shared with you and filed here (#819) are the
      # server's alone: written, put back, removed, never sent. They are
      # set apart from everything else before it is compared.
      {stubs, listed} =
        listing["entries"]
        |> List.wrap()
        |> Enum.reject(&Scan.ignored?(&1["path"], patterns))
        |> Enum.split_with(&(&1["kind"] == "stub"))

      {old_stubs, kept} =
        (state["entries"] || %{}) |> Enum.split_with(fn {_path, e} -> e["kind"] == "stub" end)

      stub_paths = MapSet.new(Enum.map(stubs, & &1["path"]) ++ Enum.map(old_stubs, &elem(&1, 0)))
      all_local = local
      local = Map.reject(local, fn {path, _f} -> MapSet.member?(stub_paths, path) end)

      # What .slipdockignore names is neither sent nor fetched, and what the
      # state knew there is left as it was.
      server = for e <- listed, into: %{}, do: {{kind(e), e["id"]}, e}

      {set_aside, old} =
        kept
        |> Enum.split_with(fn {path, e} ->
          Scan.ignored?(path, patterns) and not Map.has_key?(server, {kind(e), e["id"]})
        end)

      acc = %{
        root: root,
        remote: remote,
        host: opts[:host] || state["host"] || hostname(),
        today: opts[:today] || Date.utc_today(),
        direction: opts[:direction] || :both,
        old: adopt(Map.new(old), opts[:imported], server, local),
        server: server,
        entries: %{},
        done: MapSet.new(),
        done_paths: MapSet.new(),
        queued: [],
        report: %{
          sent: [],
          received: [],
          moved: [],
          archived: [],
          removed: [],
          conflicts: [],
          stubs: [],
          held: [],
          errors: []
        }
      }

      acc =
        acc
        |> known(local)
        |> fresh(local)
        |> send_queued()
        |> unseen()
        |> stubs(stubs, Map.new(old_stubs), all_local)

      {acc, folders} = folders(acc, listing["folders"], state, patterns)

      report = acc.report |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)

      conflicts =
        ((state["conflicts"] || []) ++ Enum.map(report.conflicts, & &1.copy))
        |> Enum.uniq()
        |> Enum.filter(&FS.exists?(Path.join(root, &1)))

      state =
        state
        |> Map.put("entries", Map.merge(Map.new(set_aside), acc.entries))
        |> Map.put("cursor", listing["cursor"])
        |> Map.put("folders", folders)
        |> Map.put("conflicts", conflicts)
        |> Map.put("errors", Enum.map(report.errors, &%{"path" => &1.path, "error" => &1.error}))
        |> Map.put(
          "last_run",
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        )
        |> Map.put("last_result", Map.new(report, fn {k, v} -> {to_string(k), length(v)} end))

      {:ok, state, report}
    end
  end

  # A state entry or a listing entry: a page unless it says otherwise.
  defp kind(%{"kind" => "file"}), do: "file"
  defp kind(_), do: "page"

  defp kind_of_path(path), do: if(Scan.markdown?(path), do: "page", else: "file")

  ## An imported folder ----------------------------------------------------

  # A folder `slipdock vault import` sent up (R9.4): each path it recorded is
  # known already — the page or file it became, and the hashes on both sides
  # at the time — so it is reconciled as though an earlier pass had seen it,
  # not met as a stranger. That is what keeps a note the server stores a
  # little differently (a title key), or under another name, from becoming a
  # conflict copy and a second page.
  #
  # The base is the file's own hash while the file is as it was imported, so
  # the server's version (the same note, as the server writes it) comes down
  # over it; once edited here it is the server's hash from then, so the edit
  # goes up against it, and an edit on both sides is a conflict as ever.
  # Only what is still on both sides is adopted: a recorded file gone here,
  # or a page gone there, is left to the usual rules for strangers, so
  # adopting never archives or removes anything.
  defp adopt(old, nil, _server, _local), do: old

  defp adopt(old, imported, server, local) do
    known = MapSet.new(old, fn {_path, e} -> {kind(e), e["id"]} end)

    Enum.reduce(imported, old, fn {path, r}, old ->
      key = {kind(r), r["id"]}

      cond do
        Map.has_key?(old, path) or MapSet.member?(known, key) ->
          old

        not Map.has_key?(server, key) or not Map.has_key?(local, path) ->
          old

        true ->
          base = if local[path].sha == r["sha"], do: r["sha"], else: r["hash"]
          Map.put(old, path, %{"id" => r["id"], "kind" => kind(r), "hash" => base})
      end
    end)
  end

  ## What both sides knew ---------------------------------------------------

  defp known(acc, local) do
    moved_to = acc.old |> renames(local) |> Map.new()

    acc.old
    |> Enum.sort_by(fn {path, _e} -> order(Map.get(moved_to, path, path)) end)
    |> Enum.reduce(acc, fn {path, e}, acc ->
      key = {kind(e), e["id"]}
      base = e["hash"]
      s = acc.server[key]
      lpath = Map.get(moved_to, path, path)
      lsha = local[lpath] && local[lpath].sha

      lstate =
        cond do
          is_nil(lsha) -> :deleted
          lsha == base and lpath == path -> :same
          lsha == base -> :renamed
          true -> :changed
        end

      sstate =
        cond do
          is_nil(s) -> :gone
          s["hash"] == base -> :same
          true -> :changed
        end

      acc = done(acc, key)
      acc = if lsha, do: claim_path(acc, lpath), else: acc

      f = %{path: path, lpath: lpath, key: key, base: base, s: s, lsha: lsha}
      reconcile(acc, {lstate, sstate}, f)
    end)
  end

  # A file missing from where it was, and one file new somewhere else with
  # exactly the hash it had: the same file, renamed or moved.
  defp renames(old, local) do
    missing = for {path, e} <- old, not Map.has_key?(local, path), do: {path, e["hash"]}
    fresh = for {path, f} <- local, not Map.has_key?(old, path), do: {path, f.sha}

    {pairs, _} =
      Enum.reduce(missing, {[], fresh}, fn {path, hash}, {pairs, fresh} ->
        candidates =
          Enum.filter(fresh, fn {p, sha} ->
            sha == hash and kind_of_path(p) == kind_of_path(path)
          end)

        pick =
          Enum.find(candidates, fn {p, _} -> Path.basename(p) == Path.basename(path) end) ||
            List.first(candidates)

        case pick do
          nil -> {pairs, fresh}
          {to, _} = taken -> {[{path, to} | pairs], List.delete(fresh, taken)}
        end
      end)

    pairs
  end

  # Shallow first, and a page's own index before what sits beside it, so a
  # moved folder's parent page has arrived before its children ask for it.
  defp order(path) do
    {length(String.split(path, "/")), if(Path.basename(path) == "index.md", do: 0, else: 1), path}
  end

  defp reconcile(acc, {:deleted, :gone}, _f), do: acc

  defp reconcile(%{direction: :up} = acc, {l, :gone}, f) when l in [:same, :renamed] do
    acc
    |> keep(f.path, f.key, f.base)
    |> hold(f.lpath, "archived on the server, not removed here")
  end

  # Archived (or moved out of reach) on the server, untouched here: remove it.
  defp reconcile(acc, {l, :gone}, f) when l in [:same, :renamed] do
    case remove_file(acc, f.lpath, f.lsha) do
      :ok -> report(acc, :removed, %{path: f.lpath})
      # Edited in the moment between: keep it, as a new one.
      :changed -> queue(acc, f.lpath)
    end
  end

  # Gone on the server, but edited here: the edit is not thrown away.
  defp reconcile(acc, {:changed, :gone}, f), do: queue(acc, f.lpath)

  # Deleted here: archive (R2.5), unless the server changed it meanwhile.
  defp reconcile(%{direction: :down} = acc, {:deleted, :same}, f) do
    acc |> keep(f.path, f.key, f.base) |> hold(f.path, "deleted here, not archived")
  end

  defp reconcile(acc, {:deleted, :same}, f) do
    case archive(acc, f.key, f.base) do
      {:ok, _} ->
        report(acc, :archived, %{path: f.path})

      {:conflict, current} ->
        download(acc, f.key, Map.merge(f.s, current), nil, nil)

      {:error, msg} ->
        acc |> keep(f.path, f.key, f.base) |> error(f.path, msg)
    end
  end

  # Deleted here, changed there: the server's change wins, and comes back.
  defp reconcile(acc, {:deleted, :changed}, f), do: download(acc, f.key, f.s, nil, nil)

  defp reconcile(acc, {:same, :same}, f) do
    if f.s["path"] == f.path,
      do: keep(acc, f.path, f.key, f.base),
      else: move_local(acc, f.path, f.s["path"], f.key, f.base)
  end

  defp reconcile(acc, {:renamed, :same}, f),
    do: upload(acc, f.key, f.lpath, f.base, f.path, :renamed)

  defp reconcile(acc, {:changed, :same}, f),
    do: upload(acc, f.key, f.lpath, f.base, f.path, :changed)

  defp reconcile(acc, {l, :changed}, f) when l in [:same, :renamed],
    do: download(acc, f.key, f.s, f.lpath, f.lsha)

  # Both sides changed. The same change made twice is no conflict.
  defp reconcile(acc, {:changed, :changed}, f),
    do: conflict(acc, f.lpath, f.lsha, f.key, f.s, {f.path, f.key, f.base})

  ## New here ---------------------------------------------------------------

  defp fresh(acc, local) do
    unknown =
      for {key, s} <- acc.server, not MapSet.member?(acc.done, key), into: %{} do
        {String.downcase(s["path"]), {key, s}}
      end

    local
    |> Enum.reject(fn {path, _f} -> MapSet.member?(acc.done_paths, path) end)
    |> Enum.sort_by(fn {path, _f} -> order(path) end)
    |> Enum.reduce(acc, fn {path, f}, acc ->
      acc = claim_path(acc, path)

      case unknown[String.downcase(path)] do
        nil ->
          upload(acc, {kind_of_path(path), nil}, path, nil, nil, :new)

        # On both sides already, as after an import or a first sync of a
        # folder that was a copy of the vault (R9.4): adopted when they agree.
        {key, %{"hash" => hash} = s} when hash == f.sha ->
          acc = done(acc, key)

          if s["path"] == path,
            do: keep(acc, path, key, hash),
            else: move_local(acc, path, s["path"], key, hash)

        {key, s} ->
          acc |> done(key) |> conflict(path, f.sha, key, s, nil)
      end
    end)
  end

  # Conflict copies, and files edited here whose page went away: each sent
  # up as a new one once everything else has settled.
  defp send_queued(%{queued: []} = acc), do: acc

  defp send_queued(%{direction: :down} = acc) do
    acc.queued
    |> Enum.reverse()
    |> Enum.reduce(%{acc | queued: []}, &hold(&2, &1, "not sent"))
  end

  defp send_queued(acc) do
    queued = Enum.reverse(acc.queued)
    acc = %{acc | queued: []}

    Enum.reduce(queued, acc, fn path, acc ->
      upload(acc, {kind_of_path(path), nil}, path, nil, nil, :new)
    end)
  end

  ## New there --------------------------------------------------------------

  defp unseen(acc) do
    acc.server
    |> Enum.reject(fn {key, _s} -> MapSet.member?(acc.done, key) end)
    |> Enum.sort_by(fn {_key, s} -> order(s["path"]) end)
    |> Enum.reduce(acc, fn {key, s}, acc -> download(acc, key, s, nil, nil) end)
  end

  ## Stubs ------------------------------------------------------------------

  # Each stub the server lists is written where it says, holding what it
  # says. One edited here goes back as it was — its edits are never sent,
  # since it is only a link to something somebody else keeps — and the
  # report says so. One no longer listed (the share taken back, the
  # placement taken out) is removed, edited or not: there is nothing of
  # yours in it.
  defp stubs(%{direction: :up} = acc, _listed, old, _local),
    do: %{acc | entries: Map.merge(acc.entries, old)}

  defp stubs(acc, listed, old, local) do
    listed_ids = MapSet.new(listed, & &1["id"])

    acc =
      Enum.reduce(old, acc, fn {path, e}, acc ->
        moved = Enum.find(listed, &(&1["id"] == e["id"] and &1["path"] != path))

        if MapSet.member?(listed_ids, e["id"]) and is_nil(moved) do
          acc
        else
          drop_stub(acc, path)
        end
      end)

    Enum.reduce(listed, acc, fn s, acc ->
      path = s["path"]
      there = local[path] && local[path].sha
      known = Enum.find_value(old, fn {p, e} -> if e["id"] == s["id"], do: {p, e["hash"]} end)

      acc =
        cond do
          there == s["hash"] ->
            acc

          # New, gone from here, or changed only on the server: as listed.
          is_nil(there) or (known && elem(known, 1) == there) ->
            acc |> write_stub(path, s["content"]) |> report(:received, %{path: path})

          true ->
            acc
            |> write_stub(path, s["content"])
            |> report(:stubs, %{path: path, why: "a link to something shared with you"})
        end

      %{
        acc
        | entries:
            Map.put(acc.entries, path, %{"id" => s["id"], "kind" => "stub", "hash" => s["hash"]})
      }
    end)
  end

  defp write_stub(acc, path, content) do
    full = Path.join(acc.root, path)
    FS.mkdir_p!(Path.dirname(full))
    FS.write!(full, content)
    acc
  end

  defp drop_stub(acc, path) do
    full = Path.join(acc.root, path)

    if FS.exists?(full) do
      FS.rm!(full)
      prune(acc.root, Path.dirname(path))
      report(acc, :removed, %{path: path})
    else
      acc
    end
  end

  ## Folders ----------------------------------------------------------------

  # The server's folders (`listing["folders"]`, nil from a server too old to
  # send them) against the ones the state remembers from last time. A
  # folder made here is the server's to hear about by the files put in it,
  # and one deleted here stays deleted: only what changed on the server is
  # done here. A mirror made before folders were remembered makes none the
  # first time, since it can't tell a folder new on the server from one
  # deleted here.
  defp folders(%{direction: :up} = acc, _listed, state, _patterns), do: {acc, state["folders"]}
  defp folders(acc, nil, state, _patterns), do: {acc, state["folders"]}

  defp folders(acc, listed, state, patterns) do
    # A folder pattern ends in a slash, so a folder is asked about with one.
    ignored? = &(Scan.ignored?(&1, patterns) or Scan.ignored?(&1 <> "/", patterns))
    listed = Enum.reject(listed, ignored?)
    had = state["folders"]
    now = MapSet.new(listed)

    acc =
      (had || [])
      |> Enum.reject(&(MapSet.member?(now, &1) or ignored?.(&1)))
      |> Enum.sort_by(&(-length(String.split(&1, "/"))))
      |> Enum.reduce(acc, fn dir, acc ->
        if remove_dir(Path.join(acc.root, dir)) == :ok,
          do: report(acc, :removed, %{path: dir <> "/", folder: true}),
          else: acc
      end)

    new =
      cond do
        had -> Enum.reject(listed, &(&1 in had))
        (state["entries"] || %{}) == %{} -> listed
        true -> []
      end

    for dir <- new, do: FS.mkdir_p(Path.join(acc.root, dir))

    {acc, listed}
  end

  # A directory with nothing in it but empty directories, taken away; one
  # holding anything else is left as it is. `:ok` when it is gone, or was.
  defp remove_dir(full) do
    case FS.ls(full) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(full, &1))
        |> Enum.filter(&FS.own_dir?/1)
        |> Enum.each(&remove_dir/1)

        if FS.rmdir(full) == :ok, do: :ok, else: :kept

      {:error, :enoent} ->
        :ok

      _ ->
        :kept
    end
  end

  ## Moving bytes -----------------------------------------------------------

  # Sends a local file up. `from` is where the state had it, for keeping the
  # old entry when the write fails, so the next pass tries again; `why` is
  # :renamed when only its path moved, which for a file other than a note
  # is a move on the server with no bytes sent.
  defp upload(%{direction: :down} = acc, key, lpath, base, from, _why) do
    acc = if from, do: keep(acc, from, key, base), else: acc
    hold(acc, lpath, "not sent")
  end

  defp upload(acc, {kind, id} = key, lpath, base, from, why) do
    full = Path.join(acc.root, lpath)

    case Scan.sha_file(full) do
      nil ->
        acc

      sha ->
        result =
          cond do
            kind == "page" ->
              case FS.read(full) do
                {:ok, content} ->
                  call(acc, :write, [id, %{"path" => lpath, "content" => content, "base" => base}])

                {:error, reason} ->
                  {:error, "can't read it (#{reason})"}
              end

            why == :renamed ->
              call(acc, :move_file, [id, %{"path" => lpath, "base" => base}])

            true ->
              call(acc, :write_file, [id, %{"path" => lpath, "base" => base}, full])
          end

        case result do
          {:ok, written} ->
            new_key = {kind, written["id"]}
            acc = if written["replaced"], do: done(acc, {kind, written["replaced"]}), else: acc

            acc
            |> done(new_key)
            |> settle(lpath, sha, new_key, written)
            |> report(:sent, %{path: written["path"], id: written["id"]})

          {:conflict, current} ->
            current_key = {kind(current), current["id"]}
            held_as = from && {from, key, base}
            acc |> done(current_key) |> conflict(lpath, sha, current_key, current, held_as)

          {:error, msg} ->
            acc = if from, do: keep(acc, from, key, base), else: acc
            error(acc, lpath, msg)
        end
    end
  end

  # After a write: the file goes where the server put it, and holds what the
  # server now writes for it (a title key patched, say) — but only if nobody
  # has touched it since it was read. A pass that only sends leaves the file
  # as it is, its base its own hash, so the next pass brings the server's
  # version down.
  defp settle(%{direction: :up} = acc, lpath, sha, key, written) do
    acc = keep(acc, lpath, key, sha)

    if written["path"] != lpath or written["hash"] != sha,
      do: hold(acc, lpath, "the server's version of it not fetched"),
      else: acc
  end

  defp settle(acc, lpath, sha, key, written) do
    acc =
      if written["path"] != lpath do
        {_, acc} = move_file(acc, lpath, written["path"], sha)
        acc
      else
        acc
      end

    acc =
      if written["hash"] != sha and is_binary(written["content"]) do
        {_, acc} = put_file(acc, written["path"], written["content"], sha)
        acc
      else
        acc
      end

    keep(acc, written["path"], key, written["hash"])
  end

  # Brings the server's version down, from `from` (where it was here,
  # holding `expect`) to wherever the server has it now. `s` is what the
  # listing (or a conflict) said of it.
  defp download(%{direction: :up} = acc, key, s, from, expect) do
    acc = done(acc, key)
    acc = if from, do: keep(acc, from, key, expect), else: acc
    hold(acc, from || s["path"], "changed on the server, not fetched")
  end

  defp download(acc, key, s, from, expect) do
    case fetch(acc, key, s) do
      {:ok, got} ->
        acc = done(acc, key)
        to = got.path

        acc =
          if from && from != to do
            case remove_file(acc, from, expect) do
              :ok -> acc
              :changed -> queue(acc, from)
            end
          else
            acc
          end

        {_, acc} = put_file(acc, to, got.data, if(from == to, do: expect))

        acc
        |> keep(to, key, got.hash)
        |> claim_path(to)
        |> report(:received, %{path: to, id: elem(key, 1)})

      {:error, msg} ->
        acc = if from, do: keep(acc, from, key, expect), else: acc
        error(acc, from || (s && s["path"]) || "#{elem(key, 0)} #{elem(key, 1)}", msg)
    end
  end

  # The server's bytes for something: a page's content comes in the answer,
  # a file's are streamed to a temp file beside the state, never into memory.
  defp fetch(acc, {"page", id}, s) do
    content =
      if s && is_binary(s["content"]) do
        {:ok, s}
      else
        call(acc, :read, [id])
      end

    with {:ok, page} <- content,
         do: {:ok, %{path: page["path"], hash: page["hash"], data: page["content"]}}
  end

  defp fetch(acc, {"file", id}, s) do
    tmp = temp_path(acc)

    case call(acc, :read_file, [id, tmp]) do
      {:ok, sha} ->
        {:ok, %{path: s["path"], hash: sha, data: {:tmp, tmp}}}

      {:error, _} = error ->
        FS.rm(tmp)
        error
    end
  end

  # Both changed: the server's version keeps the path, the local one moves
  # beside it and goes up as one of its own. A pass that only sends does
  # neither: the file keeps what the state had for it, `held_as`
  # ({path, key, base}, nil for one it never knew), for the next pass.
  defp conflict(acc, lpath, lsha, key, current, held_as) do
    cond do
      current["hash"] == lsha ->
        if current["path"] == lpath,
          do: keep(acc, lpath, key, lsha),
          else: move_local(acc, lpath, current["path"], key, lsha)

      acc.direction == :up ->
        acc =
          case held_as do
            {path, key, base} -> keep(acc, path, key, base)
            nil -> acc
          end

        hold(acc, lpath, "changed on both sides, left for a pass both ways")

      true ->
        conflict_both(acc, lpath, lsha, key, current)
    end
  end

  defp conflict_both(acc, lpath, lsha, key, current) do
    case fetch(acc, key, current) do
      {:ok, got} ->
        copy = conflict_name(acc, lpath)

        acc =
          case move_file(acc, lpath, copy, lsha) do
            {:ok, acc} -> queue(acc, copy)
            {:changed, acc} -> acc
          end

        {_, acc} = put_file(acc, got.path, got.data, nil)

        acc
        |> keep(got.path, key, got.hash)
        |> claim_path(got.path)
        |> report(:conflicts, %{path: got.path, copy: copy})

      {:error, msg} ->
        error(acc, lpath, msg)
    end
  end

  defp move_local(%{direction: :up} = acc, from, to, key, hash),
    do: acc |> keep(from, key, hash) |> hold(from, "moved to #{to} on the server, not here")

  defp move_local(acc, from, to, key, hash) do
    case move_file(acc, from, to, hash) do
      {:ok, acc} ->
        acc |> keep(to, key, hash) |> claim_path(to) |> report(:moved, %{from: from, path: to})

      {:changed, acc} ->
        keep(acc, from, key, hash)
    end
  end

  defp archive(acc, {"page", id}, base), do: call(acc, :archive, [id, base])
  defp archive(acc, {"file", id}, base), do: call(acc, :archive_file, [id, base])

  @doc false
  # `Name (conflict 2026-10-12 host).md` beside `path`, numbered if taken.
  def conflict_name(acc, path) do
    dir = Path.dirname(path)
    ext = Path.extname(path)
    stem = Path.basename(path, ext)
    # A page's own `Title/index.md` is `Title`, and so is its copy.
    stem = if stem == "index" and dir != ".", do: Path.basename(dir), else: stem
    host = acc.host |> to_string() |> String.replace(~r/[\/\\:*?"<>|]+/, "-")
    base = "#{stem} (conflict #{Date.to_iso8601(acc.today)} #{host})"

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base <> ext
      n -> "#{base} #{n}#{ext}"
    end)
    |> Stream.map(&if(dir == ".", do: &1, else: Path.join(dir, &1)))
    |> Enum.find(&(not FS.exists?(Path.join(acc.root, &1))))
  end

  ## The disk ---------------------------------------------------------------

  # Writes `data` — bytes, or `{:tmp, path}` already on disk — at `path`,
  # renamed into place. When the file there doesn't hold `expect` (nil:
  # nothing should be there), whatever it does hold is moved aside first,
  # never overwritten.
  defp put_file(acc, path, data, expect) do
    full = Path.join(acc.root, path)
    there = Scan.sha_file(full)

    {tmp, sha} =
      case data do
        {:tmp, tmp} ->
          {tmp, Scan.sha_file(tmp)}

        bytes when is_binary(bytes) ->
          tmp = temp_path(acc)
          FS.write!(tmp, bytes)
          {tmp, Scan.sha(bytes)}
      end

    acc =
      if there && there != expect && there != sha do
        copy = conflict_name(acc, path)
        :ok = FS.rename(full, Path.join(acc.root, copy))
        acc |> queue(copy) |> report(:conflicts, %{path: path, copy: copy})
      else
        acc
      end

    FS.mkdir_p!(Path.dirname(full))
    FS.rename!(tmp, full)
    {:ok, acc}
  end

  defp temp_path(acc) do
    tmp = Path.join([acc.root, State.dir_name(), "tmp-#{System.unique_integer([:positive])}"])
    FS.mkdir_p!(Path.dirname(tmp))
    tmp
  end

  defp remove_file(acc, path, expect) do
    full = Path.join(acc.root, path)

    case Scan.sha_file(full) do
      nil ->
        :ok

      ^expect ->
        FS.rm!(full)
        prune(acc.root, Path.dirname(path))
        :ok

      _ ->
        :changed
    end
  end

  defp move_file(acc, from, to, expect) do
    src = Path.join(acc.root, from)

    if Scan.sha_file(src) == expect do
      dest = Path.join(acc.root, to)

      acc =
        if FS.exists?(dest) and Scan.sha_file(dest) != expect do
          copy = conflict_name(acc, to)
          :ok = FS.rename(dest, Path.join(acc.root, copy))
          acc |> queue(copy) |> report(:conflicts, %{path: to, copy: copy})
        else
          acc
        end

      FS.mkdir_p!(Path.dirname(dest))
      :ok = FS.rename(src, dest)
      prune(acc.root, Path.dirname(from))
      {:ok, acc}
    else
      {:changed, acc}
    end
  end

  # Folders a move or a delete left empty go too, up to the mirror's root.
  defp prune(_root, "."), do: :ok

  defp prune(root, dir) do
    case FS.rmdir(Path.join(root, dir)) do
      :ok -> prune(root, Path.dirname(dir))
      _ -> :ok
    end
  end

  ## Bookkeeping ------------------------------------------------------------

  defp call(%{remote: {mod, ctx}}, fun, args), do: apply(mod, fun, [ctx | args])

  defp keep(acc, path, {kind, id}, hash),
    do: %{
      acc
      | entries: Map.put(acc.entries, path, %{"id" => id, "kind" => kind, "hash" => hash})
    }

  defp done(acc, key), do: %{acc | done: MapSet.put(acc.done, key)}

  defp claim_path(acc, path), do: %{acc | done_paths: MapSet.put(acc.done_paths, path)}

  defp queue(acc, path), do: %{acc | queued: [path | acc.queued]}

  defp hold(acc, path, why), do: report(acc, :held, %{path: path, why: why})

  defp report(acc, kind, item), do: %{acc | report: Map.update!(acc.report, kind, &[item | &1])}

  defp error(acc, path, :unauthorized),
    do: error(acc, path, "not signed in: run `slipdock auth`")

  defp error(acc, path, msg), do: report(acc, :errors, %{path: path, error: msg})

  def hostname do
    case :inet.gethostname() do
      {:ok, name} -> name |> to_string() |> String.split(".") |> hd()
      _ -> "this machine"
    end
  end
end
