defmodule SlipdockWeb.MCP.Tools.ArchiveBoard do
  @moduledoc "Puts a board away, or brings an archived one back. Only its owner may."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.{Args, Tools}

  @impl true
  def name, do: "archive_board"

  @impl true
  def title, do: "Archive a board"

  @impl true
  def description,
    do:
      "Archives a board you own: off the board list, nothing deleted, restorable. " <>
        "restore = true brings it back."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        restore: %{type: "boolean", description: "Unarchive instead (default false)."}
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, %{user: user} = context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, restore} <- Args.boolean(args, "restore", false),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :owner)),
         {:ok, board} <- change(board, restore) do
      {:ok, Tools.ListBoards.summary(board, user)}
    end
  end

  defp change(board, true), do: Args.refusal(Boards.unarchive_board(board))

  defp change(board, false) do
    case Boards.archive_board(board) do
      {:error, :sub_board} ->
        {:error, "a subcard board cannot be archived on its own: archive its card instead"}

      result ->
        Args.refusal(result)
    end
  end
end
