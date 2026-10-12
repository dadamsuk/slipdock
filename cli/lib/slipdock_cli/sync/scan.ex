defmodule SlipdockCLI.Sync.Scan do
  @moduledoc false

  # What is in a mirror folder, as sync sees it: every file it syncs, with
  # its size, modification time and sha256. The time and size are only for
  # noticing that something changed; whether it *did* is always the hash
  # (W-103: rely on hashes, never on modification times).
  #
  # Left out (R2.6): dot files and folders — .obsidian, .trash, .slipdock,
  # .git among them — the files editors write while saving (swap files,
  # backups, partial downloads), and whatever `.slipdockignore` at the
  # mirror's root names.

  @temp ~r/(~$|\.(swp|swx|swo|tmp|temp|part|crdownload|bak)$|^~\$|^4913$|^#.*#$)/i

  @ignore_file ".slipdockignore"

  def ignore_file, do: @ignore_file

  @doc """
  The patterns in a mirror's `.slipdockignore`, compiled: gitignore-style
  globs, one a line, `#` for comments. `*` and `?` stay within a name, `**`
  crosses folders, a trailing `/` matches a folder and all in it, and a
  pattern with no `/` in it matches a name at any depth. `!` (un-ignoring)
  is not supported, and such a line is skipped.
  """
  def ignores(root) do
    case File.read(Path.join(root, @ignore_file)) do
      {:ok, text} -> parse_ignores(text)
      _ -> []
    end
  end

  @doc false
  def parse_ignores(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["#", "!"])))
    |> Enum.map(&compile/1)
  end

  defp compile(pattern) do
    dir? = String.ends_with?(pattern, "/")
    pattern = String.trim(pattern, "/")
    anchored? = String.contains?(pattern, "/")

    body =
      Regex.split(~r/(\*\*\/|\*\*|\*|\?)/, pattern, include_captures: true, trim: true)
      |> Enum.map_join(fn
        "**/" -> "(?:.*/)?"
        "**" -> ".*"
        "*" -> "[^/]*"
        "?" -> "[^/]"
        text -> Regex.escape(text)
      end)

    # A folder pattern matches the folder and everything under it; any
    # pattern matches a folder's contents when it matches the folder.
    prefix = if anchored?, do: "^", else: "(?:^|/)"
    Regex.compile!(prefix <> body <> if(dir?, do: "/", else: "(?:/|$)"))
  end

  @doc "Whether a vault path is never synced."
  def ignored?(path, patterns \\ []) do
    hidden? =
      path
      |> String.split("/", trim: true)
      |> Enum.any?(fn segment ->
        String.starts_with?(segment, ".") or Regex.match?(@temp, segment)
      end)

    hidden? or Enum.any?(patterns, &Regex.match?(&1, path))
  end

  @doc "Whether a file is a note (the rest are attachments, W-103 R2.9)."
  def markdown?(path), do: String.downcase(Path.extname(path)) == ".md"

  @doc """
  Every synced file under `root`: path → `%{sha:, size:, mtime:}`. `cache`
  is a previous scan; a file whose size and time have not moved keeps the
  hash it had rather than being read again.
  """
  def scan(root, cache \\ %{}) do
    patterns = ignores(root)

    root
    |> walk("", patterns)
    |> Map.new(fn {path, stat} ->
      sig = {stat.size, stat.mtime}

      sha =
        case cache[path] do
          %{size: size, mtime: mtime, sha: sha} when {size, mtime} == sig -> sha
          _ -> sha_file(Path.join(root, path))
        end

      {path, %{sha: sha, size: stat.size, mtime: stat.mtime}}
    end)
    |> Enum.reject(fn {_path, f} -> is_nil(f.sha) end)
    |> Map.new()
  end

  @doc """
  What under `root` is never synced, at the highest level it is left out:
  a folder as `name/` (nothing under it listed), a file by its path. What an
  import says it skipped.
  """
  def ignored_paths(root), do: skipped(root, "", ignores(root))

  defp skipped(root, rel, patterns) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          path = if rel == "", do: name, else: rel <> "/" <> name
          dir? = File.dir?(Path.join(root, path))

          cond do
            dir? and (ignored?(path, patterns) or ignored?(path <> "/", patterns)) ->
              [path <> "/"]

            dir? ->
              skipped(root, path, patterns)

            ignored?(path, patterns) ->
              [path]

            true ->
              []
          end
        end)

      _ ->
        []
    end
  end

  @doc "Every synced file's stat, without reading any of them: what a watcher compares."
  def scan_stats(root), do: walk(root, "", ignores(root))

  defp walk(root, rel, patterns) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          path = if rel == "", do: name, else: rel <> "/" <> name
          full = Path.join(root, path)

          cond do
            ignored?(path, patterns) ->
              []

            # A folder pattern ends in a slash, so a folder is asked about
            # with one too.
            File.dir?(full) ->
              if ignored?(path <> "/", patterns), do: [], else: walk(root, path, patterns)

            true ->
              case File.stat(full, time: :posix) do
                {:ok, %File.Stat{type: :regular} = stat} -> [{path, stat}]
                _ -> []
              end
          end
        end)

      _ ->
        []
    end
  end

  @doc "The sha256 of a file, or nil when it can't be read (gone already)."
  def sha_file(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          device
          |> IO.binstream(1_048_576)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)
        after
          File.close(device)
        end

      _ ->
        nil
    end
  end

  def sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
