defmodule SlipdockCLI.Sync.Engine do
  @moduledoc false

  # One pass of `slipdock sync` (W-103 R2.2–R2.5): the folder and the vault
  # brought level, both ways.
  #
  # Three readings meet: what the state file says both sides agreed on last
  # time (path → id and hash), what is on disk now (path → hash), and what
  # the server lists now (id → path and hash). For each file:
  #
  #   * changed on one side only — the change goes to the other;
  #   * changed on both — if the two now read the same, nothing to do;
  #     otherwise the server's version keeps the path and the local one is
  #     moved beside it as `Name (conflict YYYY-MM-DD host).md`, then sent up
  #     as a page of its own. Nothing is ever silently lost (R2.4);
  #   * gone locally — the page is archived, never purged; gone on the
  #     server — the file is removed, unless it was edited here, in which
  #     case it is sent up again as a new page (R2.5);
  #   * gone from one path and a file with the same hash new at another — a
  #     rename or a move, the same page (R2.3).
  #
  # Every write to the server names the hash it was made against, so an edit
  # made on the server since this pass listed it is a conflict, not an
  # overwrite. Every write to disk checks the file still holds what this
  # pass thinks it holds, so an edit made locally while the pass ran is
  # moved aside rather than overwritten.

  alias SlipdockCLI.Sync.{Scan, State}

  @doc """
  Runs one pass over `root` with `state`, against `remote` — `{module, ctx}`
  implementing `SlipdockCLI.Sync.Remote`. Returns `{:ok, state, report}` or
  `{:error, reason}` when the server could not be listed at all.
  """
  def run(root, state, {mod, ctx} = remote, opts \\ []) do
    with {:ok, listing} <- mod.list(ctx) do
      local = Scan.scan(root, opts[:cache] || %{})

      server =
        for e <- listing["entries"] || [], e["kind"] in [nil, "page"], into: %{}, do: {e["id"], e}

      acc = %{
        root: root,
        remote: remote,
        host: opts[:host] || state["host"] || hostname(),
        today: opts[:today] || Date.utc_today(),
        old: state["entries"] || %{},
        entries: %{},
        done_ids: MapSet.new(),
        done_paths: MapSet.new(),
        queued: [],
        report: %{
          sent: [],
          received: [],
          moved: [],
          archived: [],
          removed: [],
          conflicts: [],
          errors: []
        }
      }

      acc =
        acc
        |> known(local, server)
        |> fresh(local, server)
        |> send_queued()
        |> unseen(server)

      report = acc.report |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)

      conflicts =
        ((state["conflicts"] || []) ++ Enum.map(report.conflicts, & &1.copy))
        |> Enum.uniq()
        |> Enum.filter(&File.exists?(Path.join(root, &1)))

      state =
        state
        |> Map.put("entries", acc.entries)
        |> Map.put("cursor", listing["cursor"])
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

  ## Files both sides knew --------------------------------------------------

  defp known(acc, local, server) do
    renames = renames(acc.old, local)
    moved_to = Map.new(renames, fn {from, to} -> {from, to} end)

    acc.old
    |> Enum.sort_by(fn {path, _e} -> order(Map.get(moved_to, path, path)) end)
    |> Enum.reduce(acc, fn {path, e}, acc ->
      id = e["id"]
      base = e["hash"]
      s = server[id]
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

      acc = %{acc | done_ids: MapSet.put(acc.done_ids, id)}
      acc = if lsha, do: claim_path(acc, lpath), else: acc

      reconcile(acc, {lstate, sstate}, %{
        path: path,
        lpath: lpath,
        id: id,
        base: base,
        s: s,
        lsha: lsha
      })
    end)
  end

  # A file missing from where it was, and one file new somewhere else with
  # exactly the hash it had: the same file, renamed or moved.
  defp renames(old, local) do
    missing = for {path, e} <- old, not Map.has_key?(local, path), do: {path, e["hash"]}
    fresh = for {path, f} <- local, not Map.has_key?(old, path), do: {path, f.sha}

    {pairs, _} =
      Enum.reduce(missing, {[], fresh}, fn {path, hash}, {pairs, fresh} ->
        candidates = Enum.filter(fresh, fn {_p, sha} -> sha == hash end)

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

  # Archived (or moved out of reach) on the server, untouched here: remove it.
  defp reconcile(acc, {l, :gone}, f) when l in [:same, :renamed] do
    case remove_file(acc, f.lpath, f.lsha) do
      :ok -> report(acc, :removed, %{path: f.lpath})
      # Edited in the moment between: keep it, as a new page.
      :changed -> queue(acc, f.lpath)
    end
  end

  # Gone on the server, but edited here: the edit is not thrown away.
  defp reconcile(acc, {:changed, :gone}, f), do: queue(acc, f.lpath)

  # Deleted here: archive (R2.5), unless the server changed it meanwhile.
  defp reconcile(acc, {:deleted, :same}, f) do
    case call(acc, :archive, [f.id, f.base]) do
      {:ok, _} -> report(acc, :archived, %{path: f.path, id: f.id})
      {:conflict, current} -> receive_current(acc, current, nil)
      {:error, msg} -> acc |> keep(f.path, f.id, f.base) |> error(f.path, msg)
    end
  end

  # Deleted here, changed there: the server's edit wins, and comes back.
  defp reconcile(acc, {:deleted, :changed}, f), do: download(acc, f.id, nil, nil)

  defp reconcile(acc, {:same, :same}, f) do
    if f.s["path"] == f.path,
      do: keep(acc, f.path, f.id, f.base),
      else: move_local(acc, f.path, f.s["path"], f.id, f.base)
  end

  defp reconcile(acc, {:renamed, :same}, f), do: upload(acc, f.id, f.lpath, f.base, f.path)
  defp reconcile(acc, {:changed, :same}, f), do: upload(acc, f.id, f.lpath, f.base, f.path)

  defp reconcile(acc, {:same, :changed}, f), do: download(acc, f.id, f.lpath, f.lsha)

  defp reconcile(acc, {:renamed, :changed}, f), do: download(acc, f.id, f.lpath, f.lsha)

  # Both sides changed. The same change made twice is no conflict.
  defp reconcile(acc, {:changed, :changed}, f) do
    if f.lsha == f.s["hash"] do
      if f.s["path"] == f.lpath,
        do: keep(acc, f.lpath, f.id, f.lsha),
        else: move_local(acc, f.lpath, f.s["path"], f.id, f.lsha)
    else
      case call(acc, :read, [f.id]) do
        {:ok, current} -> conflict(acc, f.lpath, f.lsha, current)
        {:error, msg} -> acc |> keep(f.path, f.id, f.base) |> error(f.lpath, msg)
      end
    end
  end

  ## Files new here ---------------------------------------------------------

  defp fresh(acc, local, server) do
    unknown =
      for {id, s} <- server, not MapSet.member?(acc.done_ids, id), into: %{} do
        {String.downcase(s["path"]), s}
      end

    local
    |> Enum.reject(fn {path, _f} -> MapSet.member?(acc.done_paths, path) end)
    |> Enum.filter(fn {path, _f} -> Scan.markdown?(path) end)
    |> Enum.sort_by(fn {path, _f} -> order(path) end)
    |> Enum.reduce(acc, fn {path, f}, acc ->
      acc = claim_path(acc, path)

      case unknown[String.downcase(path)] do
        nil ->
          upload(acc, nil, path, nil, nil)

        # On both sides already, as after an import or a first sync of a
        # folder that was a copy of the vault (R9.4): adopted when they agree.
        %{"hash" => hash} = s when hash == f.sha ->
          %{acc | done_ids: MapSet.put(acc.done_ids, s["id"])}
          |> then(
            &if(s["path"] == path,
              do: keep(&1, path, s["id"], hash),
              else: move_local(&1, path, s["path"], s["id"], hash)
            )
          )

        s ->
          acc = %{acc | done_ids: MapSet.put(acc.done_ids, s["id"])}

          case call(acc, :read, [s["id"]]) do
            {:ok, current} -> conflict(acc, path, f.sha, current)
            {:error, msg} -> error(acc, path, msg)
          end
      end
    end)
  end

  # Conflict copies, and files edited here whose page went away: each sent
  # up as a new page once everything else has settled.
  defp send_queued(%{queued: []} = acc), do: acc

  defp send_queued(acc) do
    queued = Enum.reverse(acc.queued)
    acc = %{acc | queued: []}
    Enum.reduce(queued, acc, fn path, acc -> upload(acc, nil, path, nil, nil) end)
  end

  ## Files new there --------------------------------------------------------

  defp unseen(acc, server) do
    server
    |> Enum.reject(fn {id, _s} -> MapSet.member?(acc.done_ids, id) end)
    |> Enum.sort_by(fn {_id, s} -> order(s["path"]) end)
    |> Enum.reduce(acc, fn {id, _s}, acc -> download(acc, id, nil, nil) end)
  end

  ## Moving bytes -----------------------------------------------------------

  # Sends a local file up. `from` is where the state had it, for keeping the
  # old entry when the write fails, so the next pass tries again.
  defp upload(acc, id, lpath, base, from) do
    full = Path.join(acc.root, lpath)

    case File.read(full) do
      {:ok, content} ->
        sha = Scan.sha(content)

        case call(acc, :write, [id, %{"path" => lpath, "content" => content, "base" => base}]) do
          {:ok, page} ->
            acc =
              if page["replaced"],
                do: %{acc | done_ids: MapSet.put(acc.done_ids, page["replaced"])},
                else: acc

            acc = %{acc | done_ids: MapSet.put(acc.done_ids, page["id"])}

            acc
            |> settle(lpath, sha, page)
            |> report(:sent, %{path: page["path"], id: page["id"]})

          {:conflict, current} ->
            acc = %{acc | done_ids: MapSet.put(acc.done_ids, current["id"])}

            with_content =
              if Map.has_key?(current, "content"),
                do: {:ok, current},
                else: call(acc, :read, [current["id"]])

            case with_content do
              {:ok, current} -> conflict(acc, lpath, sha, current)
              {:error, msg} -> error(acc, lpath, msg)
            end

          {:error, msg} ->
            acc = if from, do: keep(acc, from, id, base), else: acc
            error(acc, lpath, msg)
        end

      {:error, _} ->
        acc
    end
  end

  # After a write: the file goes where the server put it, and holds what the
  # server now writes for it (a title key patched, say) — but only if nobody
  # has touched it since it was read.
  defp settle(acc, lpath, sha, page) do
    acc =
      if page["path"] != lpath do
        case move_file(acc, lpath, page["path"], sha) do
          {:ok, acc} -> acc
          {:changed, acc} -> acc
        end
      else
        acc
      end

    acc =
      if page["hash"] != sha and is_binary(page["content"]) do
        {_, acc} = put_file(acc, page["path"], page["content"], sha)
        acc
      else
        acc
      end

    keep(acc, page["path"], page["id"], page["hash"])
  end

  # Brings the server's version of a page down, from `from` (where it was
  # here, holding `expect`) to wherever the server has it now.
  defp download(acc, id, from, expect) do
    case call(acc, :read, [id]) do
      {:ok, page} ->
        acc = %{acc | done_ids: MapSet.put(acc.done_ids, id)}
        receive_current(acc, page, {from, expect})

      {:error, msg} ->
        acc = if from, do: keep(acc, from, id, expect), else: acc
        error(acc, from || "page #{id}", msg)
    end
  end

  defp receive_current(acc, page, origin) do
    {from, expect} = origin || {nil, nil}
    to = page["path"]

    acc =
      if from && from != to do
        case remove_file(acc, from, expect) do
          :ok -> acc
          :changed -> queue(acc, from)
        end
      else
        acc
      end

    {_, acc} = put_file(acc, to, page["content"], if(from == to, do: expect))

    acc
    |> keep(to, page["id"], page["hash"])
    |> claim_path(to)
    |> report(:received, %{path: to, id: page["id"]})
  end

  # Both changed: the server's version keeps the path, the local one moves
  # beside it and goes up as a page of its own.
  defp conflict(acc, lpath, lsha, current) do
    if current["hash"] == lsha do
      if current["path"] == lpath,
        do: keep(acc, lpath, current["id"], lsha),
        else: move_local(acc, lpath, current["path"], current["id"], lsha)
    else
      copy = conflict_name(acc, lpath)

      acc =
        case move_file(acc, lpath, copy, lsha) do
          {:ok, acc} -> queue(acc, copy)
          {:changed, acc} -> acc
        end

      {_, acc} = put_file(acc, current["path"], current["content"], nil)

      acc
      |> keep(current["path"], current["id"], current["hash"])
      |> claim_path(current["path"])
      |> report(:conflicts, %{path: current["path"], copy: copy, id: current["id"]})
    end
  end

  defp move_local(acc, from, to, id, hash) do
    case move_file(acc, from, to, hash) do
      {:ok, acc} ->
        acc |> keep(to, id, hash) |> claim_path(to) |> report(:moved, %{from: from, path: to})

      {:changed, acc} ->
        keep(acc, from, id, hash)
    end
  end

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
    |> Enum.find(&(not File.exists?(Path.join(acc.root, &1))))
  end

  ## The disk ---------------------------------------------------------------

  # Writes `bytes` at `path`, through a temp file renamed into place. When
  # the file there doesn't hold `expect` (nil: nothing should be there),
  # whatever it does hold is moved aside first, never overwritten.
  defp put_file(acc, path, bytes, expect) do
    full = Path.join(acc.root, path)
    there = Scan.sha_file(full)

    acc =
      if there && there != expect && there != Scan.sha(bytes) do
        copy = conflict_name(acc, path)
        :ok = File.rename(full, Path.join(acc.root, copy))
        acc |> queue(copy) |> report(:conflicts, %{path: path, copy: copy, id: nil})
      else
        acc
      end

    tmp = Path.join([acc.root, State.dir_name(), "tmp-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(Path.dirname(tmp))
    File.mkdir_p!(Path.dirname(full))
    File.write!(tmp, bytes)
    File.rename!(tmp, full)
    {:ok, acc}
  end

  defp remove_file(acc, path, expect) do
    full = Path.join(acc.root, path)

    case Scan.sha_file(full) do
      nil ->
        :ok

      ^expect ->
        File.rm!(full)
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
        if File.exists?(dest) and Scan.sha_file(dest) != expect do
          copy = conflict_name(acc, to)
          :ok = File.rename(dest, Path.join(acc.root, copy))
          acc |> queue(copy) |> report(:conflicts, %{path: to, copy: copy, id: nil})
        else
          acc
        end

      File.mkdir_p!(Path.dirname(dest))
      :ok = File.rename(src, dest)
      prune(acc.root, Path.dirname(from))
      {:ok, acc}
    else
      {:changed, acc}
    end
  end

  # Folders a move or a delete left empty go too, up to the mirror's root.
  defp prune(_root, "."), do: :ok

  defp prune(root, dir) do
    case File.rmdir(Path.join(root, dir)) do
      :ok -> prune(root, Path.dirname(dir))
      _ -> :ok
    end
  end

  ## Bookkeeping ------------------------------------------------------------

  defp call(%{remote: {mod, ctx}}, fun, args), do: apply(mod, fun, [ctx | args])

  defp keep(acc, path, id, hash),
    do: %{
      acc
      | entries: Map.put(acc.entries, path, %{"id" => id, "kind" => "page", "hash" => hash})
    }

  defp claim_path(acc, path), do: %{acc | done_paths: MapSet.put(acc.done_paths, path)}

  defp queue(acc, path), do: %{acc | queued: [path | acc.queued]}

  defp report(acc, kind, item), do: %{acc | report: Map.update!(acc.report, kind, &[item | &1])}

  defp error(acc, path, :unauthorized), do: error(acc, path, "not signed in: run `slipdock auth`")
  defp error(acc, path, msg), do: report(acc, :errors, %{path: path, error: msg})

  def hostname do
    case :inet.gethostname() do
      {:ok, name} -> name |> to_string() |> String.split(".") |> hd()
      _ -> "this machine"
    end
  end
end
