defmodule Slipdock.Recordings do
  @moduledoc """
  Meeting recordings kept on Google Drive and played in a vault (W-1690).

  A meeting page names its recording in front matter — `recording:
  gdrive:<path from My Drive's root>`, perhaps with `recording_drive_id` —
  and the vault it belongs to names a **recordings folder** on its owner's
  Drive. `resolve/3` turns the one into a Drive file, through the owner's
  connection (`Slipdock.Google`), and refuses anything that is not plainly a
  recording in that folder:

    * the path must fall under the folder, compared segment by segment after
      normalising, with no `.` or `..` segments to climb out by;
    * a `recording_drive_id` must name a file whose parents lead up to the
      folder — an id is only a shortcut, never a way in somewhere else;
    * the file must be audio (`audio/*`, or `video/mp4` for an `.m4a`, which
      is how Drive tags some of them).

  A path found is remembered (`Slipdock.Recordings.File`), so a recording
  played again costs no Drive call to find; the cache is cleared when the
  folder changes, and an entry whose file has gone is dropped (`forget/2`).

  Errors: `:no_folder`, `:not_connected`, `:revoked`, `:invalid` (not a
  `gdrive:` path), `:outside_folder`, `:not_found`, `:not_audio`,
  `:unavailable` (Drive could not be asked).
  """
  import Ecto.Query, warn: false

  alias Slipdock.Google
  alias Slipdock.Google.Drive
  alias Slipdock.Recordings.File, as: Cached
  alias Slipdock.Repo
  alias Slipdock.Vaults.Vault

  # Far deeper than any recordings folder; the climb from a file id up its
  # parents gives up here rather than walking a whole Drive.
  @max_depth 32

  @type file :: %{id: String.t(), mime_type: String.t(), size: integer() | nil}

  ## Paths --------------------------------------------------------------------

  @doc """
  A Drive path as its segments: slashes at either end and doubled ones
  ignored. `{:error, :invalid}` for an empty path or one with a `.` or `..`
  segment.
  """
  def segments(path) when is_binary(path) do
    segments = path |> String.split("/") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      segments == [] -> {:error, :invalid}
      Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, :invalid}
      true -> {:ok, segments}
    end
  end

  def segments(_), do: {:error, :invalid}

  @doc "The segments of a front-matter `recording` value (`gdrive:<path>`)."
  def parse(recording) when is_binary(recording) do
    case String.trim(recording) do
      "gdrive:" <> path -> segments(path)
      _ -> {:error, :invalid}
    end
  end

  def parse(_), do: {:error, :invalid}

  @doc "A recordings folder as it is stored: its segments joined by `/`."
  def normalize_folder(path) do
    with {:ok, segments} <- segments(path), do: {:ok, Enum.join(segments, "/")}
  end

  ## The folder ---------------------------------------------------------------

  @doc """
  Checks `path` is a folder on `user`'s Drive: `{:ok, normalized_path}`, or
  `{:error, reason}` — `:not_connected`, `:revoked`, `:invalid`,
  `:not_found` (no such folder), `:unavailable`.
  """
  def check_folder(user, path) do
    with {:ok, segments} <- segments(path),
         {:ok, _id} <- walk(user, segments, :folder) do
      {:ok, Enum.join(segments, "/")}
    end
  end

  ## Resolving ----------------------------------------------------------------

  @doc """
  The Drive file `vault`'s page recording names: `{:ok, file}` with `:id`,
  `:mime_type` and `:size`, or `{:error, reason}` (see the moduledoc).
  `drive_id` is the page's `recording_drive_id`, or nil.
  """
  @spec resolve(Vault.t(), String.t() | nil, String.t() | nil) :: {:ok, file()} | {:error, atom()}
  def resolve(%Vault{} = vault, recording, drive_id \\ nil) do
    with {:ok, folder} <- folder(vault),
         {:ok, segments} <- parse(recording),
         :ok <- under(segments, folder),
         :ok <- connected(vault.user_id) do
      path = Enum.join(segments, "/")

      case cached(vault, path) do
        %Cached{drive_id: id} = hit when drive_id in [nil, "", id] ->
          {:ok, %{id: hit.drive_id, mime_type: hit.mime_type, size: hit.size}}

        _ ->
          with {:ok, file} <- find(vault, segments, folder, drive_id),
               {:ok, file} <- audio(file) do
            remember(vault, path, file)
            {:ok, file}
          end
      end
    end
  end

  @doc "Drops what is remembered of `recording` in `vault`: its file has gone."
  def forget(%Vault{id: vault_id}, recording) do
    with {:ok, segments} <- parse(recording) do
      path = Enum.join(segments, "/")
      Repo.delete_all(from(f in Cached, where: f.vault_id == ^vault_id and f.path == ^path))
    end

    :ok
  end

  @doc "Forgets every path remembered for `vault` — its folder changed."
  def forget_all(%Vault{id: vault_id}) do
    Repo.delete_all(from(f in Cached, where: f.vault_id == ^vault_id))
    :ok
  end

  defp folder(%Vault{recordings_folder: folder}) when is_binary(folder) and folder != "" do
    segments(folder)
  end

  defp folder(_), do: {:error, :no_folder}

  # Segment by segment, so `Recordings2/x` is not under `Recordings`, and the
  # file has to be *inside* the folder, not the folder itself.
  defp under(segments, folder) do
    if length(segments) > length(folder) and List.starts_with?(segments, folder),
      do: :ok,
      else: {:error, :outside_folder}
  end

  defp connected(user_id) do
    case Google.connection(user_id) do
      nil -> {:error, :not_connected}
      %{revoked_at: %DateTime{}} -> {:error, :revoked}
      _ -> :ok
    end
  end

  defp cached(%Vault{id: vault_id}, path), do: Repo.get_by(Cached, vault_id: vault_id, path: path)

  # With an id, the file is Drive's to describe and its parents have to lead
  # to the folder. Without one, the path is walked from My Drive's root.
  defp find(vault, _segments, folder, drive_id) when is_binary(drive_id) and drive_id != "" do
    with {:ok, folder_id} <- walk(vault.user_id, folder, :folder),
         {:ok, meta} <- Drive.file(vault.user_id, drive_id),
         :ok <- if(meta["trashed"] == true, do: {:error, :not_found}, else: :ok),
         :ok <- inside(vault.user_id, meta["parents"] || [], folder_id, @max_depth) do
      {:ok, file(meta)}
    end
  end

  defp find(vault, segments, _folder, _drive_id) do
    with {:ok, meta} <- walk(vault.user_id, segments, :file), do: {:ok, file(meta)}
  end

  defp inside(_user, _parents, _folder_id, 0), do: {:error, :outside_folder}
  defp inside(_user, [], _folder_id, _depth), do: {:error, :outside_folder}

  defp inside(user, parents, folder_id, depth) do
    if folder_id in parents do
      :ok
    else
      # A file in My Drive has one parent; look up each anyway, rather than
      # guess which one leads to the folder.
      Enum.reduce_while(parents, {:error, :outside_folder}, fn parent, acc ->
        case Drive.file(user, parent) do
          {:ok, meta} ->
            case inside(user, meta["parents"] || [], folder_id, depth - 1) do
              :ok -> {:halt, :ok}
              _ -> {:cont, acc}
            end

          {:error, :not_found} ->
            {:cont, acc}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  # Down from My Drive's root one name at a time. Every segment but the last
  # has to be a folder; the last has to be what was asked for. The folder
  # walk answers with an id, the file walk with the file's metadata.
  defp walk(user, segments, kind) do
    {dirs, [last]} = Enum.split(segments, -1)

    with {:ok, parent} <- walk_dirs(user, dirs, "root"),
         {:ok, meta} <- Drive.child(user, parent, last) do
      folder? = meta["mimeType"] == Drive.folder_mime()

      case {kind, folder?} do
        {:folder, true} -> {:ok, meta["id"]}
        {:file, false} -> {:ok, meta}
        _ -> {:error, :not_found}
      end
    end
  end

  defp walk_dirs(_user, [], parent), do: {:ok, parent}

  defp walk_dirs(user, [name | rest], parent) do
    case Drive.child(user, parent, name) do
      {:ok, %{"id" => id, "mimeType" => mime}} ->
        if mime == Drive.folder_mime(), do: walk_dirs(user, rest, id), else: {:error, :not_found}

      error ->
        error
    end
  end

  defp file(meta) do
    %{
      id: meta["id"],
      name: meta["name"],
      mime_type: meta["mimeType"],
      size: size(meta["size"])
    }
  end

  defp size(n) when is_integer(n), do: n

  defp size(n) when is_binary(n) do
    case Integer.parse(n) do
      {size, ""} -> size
      _ -> nil
    end
  end

  defp size(_), do: nil

  defp audio(%{mime_type: "audio/" <> _} = file), do: {:ok, file}

  defp audio(%{mime_type: "video/mp4", name: name} = file) when is_binary(name) do
    if String.downcase(Path.extname(name)) == ".m4a", do: {:ok, file}, else: {:error, :not_audio}
  end

  defp audio(_), do: {:error, :not_audio}

  defp remember(%Vault{id: vault_id}, path, file) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(
      %Cached{
        vault_id: vault_id,
        path: path,
        drive_id: file.id,
        mime_type: file.mime_type,
        size: file.size,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: {:replace, [:drive_id, :mime_type, :size, :updated_at]},
      conflict_target: [:vault_id, :path]
    )
  end
end
