defmodule SlipdockCLI.Sync.Status do
  @moduledoc false

  alias SlipdockCLI.FS

  # What `slipdock sync status` reports (W-103 R2.13), and the other sync
  # tools a mirror must not share its folder with (the PRD's first risk).
  #
  # Everything here reads the folder and the state file only; asking the
  # server what is waiting there is the command's business.

  alias SlipdockCLI.Sync.Scan

  @doc """
  What has changed here since the last pass, without asking the server:
  `%{new: [...], changed: [...], deleted: [...], renamed: [{from, to}]}`.
  """
  def pending(state, local) do
    old = state["entries"] || %{}
    missing = for {path, e} <- old, not Map.has_key?(local, path), do: {path, e["hash"]}
    fresh = for {path, f} <- local, not Map.has_key?(old, path), do: {path, f.sha}

    {renamed, missing, fresh} =
      Enum.reduce(missing, {[], [], fresh}, fn {path, hash}, {renamed, gone, fresh} ->
        case Enum.find(fresh, fn {_p, sha} -> sha == hash end) do
          nil -> {renamed, [path | gone], fresh}
          {to, _} = hit -> {[{path, to} | renamed], gone, List.delete(fresh, hit)}
        end
      end)

    changed =
      for {path, e} <- old, f = local[path], f.sha != e["hash"], do: path

    %{
      new: fresh |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
      changed: Enum.sort(changed),
      deleted: Enum.sort(missing),
      renamed: Enum.sort(renamed)
    }
  end

  @doc "How many local changes are waiting."
  def count(pending), do: pending |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

  @doc """
  Other sync tools that seem to be looking after this folder too, each as
  `{name, why}`. Two tools syncing one folder undo each other's work and
  make conflicts out of nothing, so a mirror says so whenever it runs.
  """
  def other_tools(root) do
    root = Path.expand(root)
    ancestors = ancestors(root)

    [
      obsidian_sync(root),
      found(ancestors, ".dropbox", "Dropbox") || found(ancestors, ".dropbox.cache", "Dropbox") ||
        named(root, ~r{/Dropbox(/|$)}, "Dropbox"),
      found(ancestors, ".stfolder", "Syncthing"),
      named(root, ~r{/(Mobile Documents|iCloud Drive|com~apple~CloudDocs)(/|$)}, "iCloud Drive"),
      named(root, ~r{/OneDrive( - [^/]+)?(/|$)}, "OneDrive"),
      named(root, ~r{/(Google Drive|GoogleDrive|My Drive)(/|$)}, "Google Drive")
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Obsidian Sync keeps its settings in .obsidian/sync.json, and is switched
  # on in .obsidian/core-plugins.json — a list of ids in older versions, a
  # map of id → true in newer ones.
  defp obsidian_sync(root) do
    sync_json = Path.join([root, ".obsidian", "sync.json"])
    plugins = Path.join([root, ".obsidian", "core-plugins.json"])

    cond do
      FS.exists?(sync_json) ->
        {"Obsidian Sync", ".obsidian/sync.json is there"}

      match?({:ok, _}, FS.read(plugins)) and
          Regex.match?(~r/"sync"\s*(:\s*true|[,\]])/, FS.read!(plugins)) ->
        {"Obsidian Sync", "it is on in .obsidian/core-plugins.json"}

      true ->
        nil
    end
  end

  defp found(dirs, marker, name) do
    Enum.find_value(dirs, fn dir ->
      if FS.exists?(Path.join(dir, marker)),
        do: {name, "#{Path.join(dir, marker)} is there"}
    end)
  end

  defp named(root, pattern, name),
    do: if(Regex.match?(pattern, root), do: {name, "the folder is inside #{name}'s"})

  defp ancestors(dir) do
    parent = Path.dirname(dir)
    if parent == dir, do: [dir], else: [dir | ancestors(parent)]
  end

  @doc "The warning a mirror prints, or nil."
  def warning([]), do: nil

  def warning(tools) do
    names = tools |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(" and ")
    why = Enum.map_join(tools, "; ", fn {_name, why} -> why end)

    "warning: #{names} seems to be syncing this folder too (#{why}). Two sync tools on one " <>
      "folder undo each other's changes and make conflicts out of nothing — turn the other " <>
      "one off for this folder, or sync a folder of its own."
  end

  @doc "Paths of the conflict copies still on disk, for status to list."
  def conflicts(root, state) do
    (state["conflicts"] || [])
    |> Enum.filter(&FS.exists?(Path.join(root, &1)))
  end

  @doc "A local scan for `pending/2`."
  def local(root), do: Scan.scan(root)
end
