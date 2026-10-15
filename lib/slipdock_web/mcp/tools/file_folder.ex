defmodule SlipdockWeb.MCP.Tools.FileFolder do
  @moduledoc """
  Filing a wiki folder in other folders as well as its home (#808), as the
  CLI's `folder file --also/--not-in` does: one folder, with everything in
  it, shown in several places. Its home (its parent) is unchanged.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Wiki
  alias Slipdock.Wiki.{FolderPlacements, Placements}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "file_folder"

  @impl true
  def title, do: "File a wiki folder in another folder too"

  @impl true
  def description,
    do:
      "Files a folder in one more folder as well as its home (also), or takes it out of one (not_in): " <>
        "one folder and all in it, shown in several places. Same board or same vault; never inside itself."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "The folder's board: code, name or id."},
        folder: %{
          type: "string",
          description: "The folder: name, path like \"Design/Decisions\", or id."
        },
        also: %{
          type: "string",
          description:
            "File it here as well: a folder on its board (or on in_board), or a vault path like /Projects/Notes."
        },
        not_in: %{type: "string", description: "Take it out of a folder it is also filed in."},
        in_board: %{
          type: "string",
          description: "The board also/not_in names a folder on, if not the folder's."
        }
      },
      required: ["board", "folder"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def destructive?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, board_ref} <- Args.required(args, "board"),
         {:ok, ref} <- Args.required(args, "folder"),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, board_ref, :write)),
         {:ok, folder} <- Args.refusal(Wiki.find_folder(board, ref)),
         :ok <- need_one(args),
         :ok <- placement(auth, folder, args, "also", context.user),
         :ok <- placement(auth, folder, args, "not_in", context.user) do
      folder = Wiki.get_folder(folder.id)

      {:ok,
       %{
         id: folder.id,
         board: board.code,
         path: Wiki.folder_path(folder),
         also_in:
           Enum.map(FolderPlacements.folders(folder), fn f ->
             %{board: f.board && f.board.code, path: Wiki.folder_path(f)}
           end)
       }}
    end
  end

  defp need_one(args) do
    if is_map_key(args, "also") or is_map_key(args, "not_in"),
      do: :ok,
      else:
        {:error, "say where: also to file it in one more folder, not_in to take it out of one"}
  end

  defp placement(_auth, _folder, args, key, _user) when not is_map_key(args, key), do: :ok

  defp placement(auth, folder, args, key, user) do
    with {:ok, ref} <- Args.required(args, key),
         {:ok, target} <- target(auth, folder, ref, args["in_board"]),
         {:ok, _} <- Args.refusal(act(key, folder, target, user)),
         do: :ok
  end

  defp act("also", folder, target, user), do: FolderPlacements.add(folder, target, user)
  defp act("not_in", folder, target, user), do: FolderPlacements.remove(folder, target, user)

  defp target(_auth, folder, "/" <> _ = path, _board),
    do: Args.refusal(Placements.folder_at(folder, path))

  defp target(auth, folder, ref, board_ref) when board_ref in [nil, ""],
    do: target(auth, folder, ref, folder.board_id)

  defp target(auth, _folder, ref, board_ref) do
    with {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, board_ref, :read)),
         do: Args.refusal(Wiki.find_folder(board, ref))
  end
end
