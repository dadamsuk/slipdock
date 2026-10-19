defmodule SlipdockWeb.API.WikiFileController do
  @moduledoc """
  The files in a board's wiki that are not pages (`Slipdock.Wiki.WikiFile`),
  over the API (#1156): listed, and read by their path in the wiki. Until
  this, only the browser could fetch one, so a Tool's board files (which
  land in the `Tool` folder) were out of an agent's reach.

  Reading needs read on the board, narrowed by the token as everywhere else.
  The bytes always come back as a download, so a synced SVG or HTML file
  never runs as a page.
  """
  use SlipdockWeb, :controller

  import Ecto.Query

  alias Slipdock.Repo
  alias Slipdock.Wiki.{Folder, Folders, WikiFile}
  alias SlipdockWeb.API.Authorize

  action_fallback SlipdockWeb.API.FallbackController

  @doc """
  The board's live files, by path. `folder` keeps to one folder and
  everything under it (`Tool`, `Config/Archive`).
  """
  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, under} <- folder_filter(params["folder"]) do
      paths = folder_paths(board)

      files =
        board
        |> live_files()
        |> Enum.map(&{&1, file_path(&1, paths)})
        |> Enum.filter(fn {f, _} -> within?(f, paths, under) end)
        |> Enum.sort_by(fn {_, path} -> String.downcase(path) end)
        |> Enum.map(fn {f, path} -> file_json(board, f, path, paths) end)

      json(conn, %{board: board.code, files: files})
    end
  end

  @doc "One file's bytes, by its path in the wiki: `Tool/build.py`, `notes.pdf`."
  def show(conn, %{"board" => ref, "path" => parts}) do
    path = Enum.join(parts, "/")

    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         %WikiFile{} = file <- find(board, path) || not_found(path),
         true <- File.regular?(Slipdock.Wiki.Files.disk_path(file)) || not_found(path) do
      conn
      |> put_resp_header("etag", ~s("#{file.sha256}"))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download({:file, Slipdock.Wiki.Files.disk_path(file)},
        filename: file.name,
        content_type: "application/octet-stream",
        disposition: :attachment
      )
    end
  end

  defp not_found(path), do: {:error, :not_found, "file #{inspect(path)}"}

  defp folder_filter(nil), do: {:ok, nil}
  defp folder_filter(""), do: {:ok, nil}

  defp folder_filter(path) when is_binary(path),
    do: {:ok, path |> String.split("/", trim: true) |> Enum.map_join("/", &String.trim/1)}

  defp folder_filter(_),
    do: {:error, :bad_request, "folder is a path like Tool or Config/Archive"}

  defp live_files(board) do
    from(f in WikiFile, where: f.board_id == ^board.id and is_nil(f.archived_at))
    |> Repo.all()
  end

  # A file names the folders above it and then itself; folder names are not
  # unique across levels, so the path is matched whole, without regard to case.
  defp find(board, path) do
    paths = folder_paths(board)
    want = path |> String.split("/", trim: true) |> Enum.join("/") |> String.downcase()

    board
    |> live_files()
    |> Enum.find(&(String.downcase(file_path(&1, paths)) == want))
  end

  defp within?(_file, _paths, nil), do: true

  defp within?(%WikiFile{folder_id: nil}, _paths, _under), do: false

  defp within?(%WikiFile{folder_id: id}, paths, under) do
    folder = String.downcase(paths[id] || "")
    under = String.downcase(under)
    folder == under or String.starts_with?(folder, under <> "/")
  end

  defp file_path(%WikiFile{folder_id: nil, name: name}, _paths), do: name
  defp file_path(%WikiFile{folder_id: id, name: name}, paths), do: "#{paths[id]}/#{name}"

  # id => "A/B/C", from one read of the board's folders.
  defp folder_paths(board) do
    folders = Folders.list(board)
    by_id = Map.new(folders, &{&1.id, &1})
    Map.new(folders, &{&1.id, path_of(&1, by_id)})
  end

  defp path_of(%Folder{parent_id: nil, name: name}, _by_id), do: name

  defp path_of(%Folder{parent_id: parent, name: name}, by_id) do
    case by_id[parent] do
      nil -> name
      up -> path_of(up, by_id) <> "/" <> name
    end
  end

  defp file_json(board, file, path, paths) do
    %{
      id: file.id,
      name: file.name,
      path: path,
      folder: file.folder_id && paths[file.folder_id],
      size: file.size,
      content_type: file.content_type,
      sha256: file.sha256,
      updated_at: file.updated_at,
      url: "/api/boards/#{board.code || board.id}/files/" <> encode_path(path)
    }
  end

  defp encode_path(path),
    do:
      path
      |> String.split("/")
      |> Enum.map_join("/", fn s -> URI.encode(s, &URI.char_unreserved?/1) end)
end
