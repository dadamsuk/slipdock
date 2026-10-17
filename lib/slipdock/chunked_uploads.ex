defmodule Slipdock.ChunkedUploads do
  @moduledoc """
  A file sent in pieces (#1016), for a client whose bytes pass through a
  model's output: base64 written out that way goes wrong more often the
  longer it is, so no single size is safe, but a few kilobytes checked on
  arrival and resent on their own when they fail always get there.

  An upload is staged on disk under the uploads directory, in `staging/`:
  `<id>.part` holds the bytes so far and `<id>.json` what the first piece
  said (who, where it goes, the name). Nothing is an attachment until the
  caller finishes it and the whole file's hash matches, so a card never
  shows half a file. An upload nobody finishes is swept after a day.
  """

  alias Slipdock.Boards

  # Most uploads one person may have open at once: a client that forgets to
  # finish can't fill the disk.
  @max_open 10

  @max_age_seconds 24 * 60 * 60

  @doc "How long an unfinished upload is kept, in seconds."
  def max_age_seconds, do: @max_age_seconds

  @doc "The most uploads one user may have open at once."
  def max_open, do: @max_open

  @doc """
  Starts an upload for `user_id` with its first piece. `meta` is what the
  finished attachment needs (a JSON-able map: where it goes, its name);
  `max_bytes` caps the assembled file. Returns `{:ok, id, received}`.
  """
  def start(user_id, meta, bytes, max_bytes) when is_map(meta) and is_binary(bytes) do
    sweep()

    cond do
      byte_size(bytes) > max_bytes ->
        {:error, too_big(max_bytes)}

      open_count(user_id) >= @max_open ->
        {:error,
         "too_many_uploads: you have #{@max_open} unfinished chunked uploads. Finish one " <>
           "(finish: true) or wait a day for them to expire."}

      true ->
        id = Ecto.UUID.generate()
        File.mkdir_p!(dir())
        File.write!(part(id), bytes)
        File.write!(sidecar(id), Jason.encode!(Map.put(meta, "user_id", user_id)))
        {:ok, id, byte_size(bytes)}
    end
  end

  @doc """
  Adds a piece to upload `id`. `offset`, when given, is where the piece
  starts in the file: a piece that is already there (a resend after a lost
  answer) is `{:ok, received}` without adding it twice, and one that would
  leave a gap or overlap differently is refused, naming how much has
  arrived. Returns `{:ok, received}`.
  """
  def append(user_id, id, bytes, offset, max_bytes) when is_binary(bytes) do
    with {:ok, _meta} <- fetch_meta(user_id, id) do
      received = File.stat!(part(id)).size

      cond do
        is_nil(offset) or offset == received ->
          if received + byte_size(bytes) > max_bytes do
            {:error, too_big(max_bytes)}
          else
            File.write!(part(id), bytes, [:append])
            touch(id)
            {:ok, received + byte_size(bytes)}
          end

        offset < received and already_there?(id, offset, bytes) ->
          {:ok, received}

        true ->
          {:error,
           "offset_mismatch: upload #{id} has #{received} bytes, so the next chunk starts at " <>
             "offset #{received}, not #{offset}. Nothing was added."}
      end
    end
  end

  @doc """
  Upload `id` as `{:ok, meta, path, size}` for the caller to verify and
  attach, then `discard/1`. `meta` is what `start/4` was given.
  """
  def fetch(user_id, id) do
    with {:ok, meta} <- fetch_meta(user_id, id) do
      path = part(id)
      {:ok, meta, path, File.stat!(path).size}
    end
  end

  @doc "Removes upload `id` and its bytes."
  def discard(id) do
    if valid_id?(id) do
      File.rm(part(id))
      File.rm(sidecar(id))
    end

    :ok
  end

  @doc """
  Removes every upload last touched more than `max_age` seconds ago.
  Returns how many went.
  """
  def sweep(max_age \\ @max_age_seconds) do
    cutoff = System.os_time(:second) - max_age

    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} -> mtime < cutoff
        _ -> false
      end
    end)
    |> Enum.map(fn path -> discard(Path.basename(path, ".json")) end)
    |> length()
  end

  defp fetch_meta(user_id, id) do
    with true <- valid_id?(id),
         {:ok, json} <- File.read(sidecar(id)),
         {:ok, %{"user_id" => ^user_id} = meta} <- Jason.decode(json) do
      {:ok, meta}
    else
      _ ->
        {:error,
         "unknown_upload: no unfinished upload #{inspect(id)} of yours. It may have expired " <>
           "(after a day), been finished already, or never started: start again with " <>
           "append: true and no upload_id."}
    end
  end

  defp open_count(user_id) do
    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.count(fn path ->
      with {:ok, json} <- File.read(path),
           {:ok, %{"user_id" => ^user_id}} <- Jason.decode(json) do
        true
      else
        _ -> false
      end
    end)
  end

  defp already_there?(id, offset, bytes) do
    {:ok, file} = :file.open(part(id), [:read, :binary])

    try do
      :file.pread(file, offset, byte_size(bytes)) == {:ok, bytes}
    after
      :file.close(file)
    end
  end

  # The sidecar's mtime is what the sweep reads: an upload still being added
  # to stays.
  defp touch(id), do: File.touch!(sidecar(id))

  defp too_big(max_bytes),
    do:
      "too_big: the assembled file would be over #{max_bytes} bytes, the most an upload takes. " <>
        "Send a bigger one with the CLI (slipdock attach) or the HTTP API."

  defp valid_id?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp valid_id?(_), do: false

  defp dir, do: Path.join(Boards.uploads_dir(), "staging")
  defp part(id), do: Path.join(dir(), id <> ".part")
  defp sidecar(id), do: Path.join(dir(), id <> ".json")
end
