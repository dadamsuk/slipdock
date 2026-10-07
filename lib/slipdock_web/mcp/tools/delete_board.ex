defmodule SlipdockWeb.MCP.Tools.DeleteBoard do
  @moduledoc """
  Deletes a board for good, with every card, page and file on it. Only its
  owner may, and only by naming its code again in `confirm`: `archive_board`
  is the undoable way to put one away.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "delete_board"

  @impl true
  def title, do: "Delete a board"

  @impl true
  def description,
    do:
      "Deletes a board you own with all its cards, pages and files. Cannot be undone; " <>
        "archive_board is the safe way. confirm must repeat the board's code."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        confirm: %{type: "string", description: "The board's code, again."}
      },
      required: ["board", "confirm"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def destructive?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :owner)),
         :ok <- root(board),
         :ok <- confirmed(board, args["confirm"]),
         {:ok, _} <- Args.refusal(Boards.delete_board(board)) do
      {:ok, %{deleted: true, board: board.id, code: board.code, name: board.name}}
    end
  end

  defp root(board) do
    if Board.sub_board?(board),
      do: {:error, "a subcard board goes with its card: delete or archive the card instead"},
      else: :ok
  end

  defp confirmed(%{code: code}, confirm) when is_binary(confirm) do
    if String.downcase(String.trim(confirm)) == String.downcase(code),
      do: :ok,
      else: unconfirmed(code)
  end

  defp confirmed(%{code: code}, _), do: unconfirmed(code)

  defp unconfirmed(code),
    do:
      {:error,
       "not deleted: confirm must be the board's code, #{inspect(code)}. This cannot be " <>
         "undone; archive_board puts a board away and can be undone."}
end
