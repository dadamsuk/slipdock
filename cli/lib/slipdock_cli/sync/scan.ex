defmodule SlipdockCLI.Sync.Scan do
  @moduledoc false

  # What is in a mirror folder, as sync sees it: every file it syncs, with
  # its size, modification time and sha256. The time and size are only for
  # noticing that something changed; whether it *did* is always the hash
  # (W-103: rely on hashes, never on modification times).
  #
  # Left out (R2.6): dot files and folders — .obsidian, .trash, .slipdock,
  # .git among them — and the files editors write while saving: swap files,
  # backups, partial downloads.

  @temp ~r/(~$|\.(swp|swx|swo|tmp|temp|part|crdownload|bak)$|^~\$|^4913$|^#.*#$)/i

  @doc "Whether a vault path is never synced."
  def ignored?(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.any?(fn segment ->
      String.starts_with?(segment, ".") or Regex.match?(@temp, segment)
    end)
  end

  @doc "Whether a file is a note (the rest are attachments, W-103 R2.9)."
  def markdown?(path), do: String.downcase(Path.extname(path)) == ".md"

  @doc """
  Every synced file under `root`: path → `%{sha:, size:, mtime:}`. `cache`
  is a previous scan; a file whose size and time have not moved keeps the
  hash it had rather than being read again.
  """
  def scan(root, cache \\ %{}) do
    root
    |> walk("")
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

  defp walk(root, rel) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          path = if rel == "", do: name, else: rel <> "/" <> name
          full = Path.join(root, path)

          cond do
            ignored?(path) ->
              []

            File.dir?(full) ->
              walk(root, path)

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
