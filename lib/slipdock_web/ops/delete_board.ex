defmodule SlipdockWeb.Ops.DeleteBoard do
  @moduledoc """
  Deleting a board for good, with every card, page and file on it, defined
  once (#3187). Only its owner may, and not a subcard's board, which goes
  with its card. `archive_board` is the undoable way, so MCP asks for the
  board's code again in `confirm` first (`confirm/2`); REST, whose callers
  name the board and the verb themselves, never did and still doesn't.

  Before it, REST answered `{ok}` and MCP `{deleted, board, code, name}`:
  now both answer `{ok, board, code, name}`. REST deleted a subcard's board
  that MCP refused: now both refuse it. The CLI has no command for it.
  """
  @behaviour SlipdockWeb.Ops.Op

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias SlipdockWeb.API.Authorize

  @impl true
  def definition do
    %{
      name: "delete_board",
      title: "Delete a board",
      summary:
        "Deletes a board you own with all its cards, pages and files. Cannot be undone; " <>
          "archive_board is the safe way. confirm must repeat the board's code.",
      verb: :delete,
      path: "/api/boards/:board",
      permission: {:board, :owner},
      writes?: true,
      destructive?: true,
      params: [
        %{
          name: "board",
          type: :string,
          required: true,
          in_path: "board",
          doc: "Board id, code or name."
        }
      ],
      # Any value casts: confirm/2 refuses a wrong one, naming the code.
      confirm: %{type: :any, schema: %{type: "string"}, doc: "The board's code, again."}
    }
  end

  @impl true
  def confirm(%{"board" => ref} = params, auth) do
    with {:ok, board} <- fetch(ref, auth) do
      if is_binary(params["confirm"]) and
           String.downcase(String.trim(params["confirm"])) == String.downcase(board.code),
         do: :ok,
         else: unconfirmed(board.code)
    end
  end

  @impl true
  def run(%{"board" => ref}, auth) do
    with {:ok, board} <- fetch(ref, auth),
         {:ok, _} <- Boards.delete_board(board) do
      {:ok, %{ok: true, board: board.id, code: board.code, name: board.name}}
    end
  end

  # The board, if the caller owns it and it is a tree's root.
  defp fetch(ref, auth) do
    with {:ok, board} <- Authorize.fetch_board(auth, ref, :owner) do
      if Board.sub_board?(board),
        do:
          {:error, :unprocessable_entity,
           "a subcard board goes with its card: delete or archive the card instead"},
        else: {:ok, board}
    end
  end

  defp unconfirmed(code),
    do:
      {:error,
       "not deleted: confirm must be the board's code, #{inspect(code)}. This cannot be " <>
         "undone; archive_board puts a board away and can be undone."}
end
