defmodule SlipdockWeb.API.NowController do
  @moduledoc """
  What is happening right now on a board's tree over HTTP (#2103, see
  `Slipdock.Now`).

    * `GET /api/boards/:board/now` – the tree's runners and the jobs each
      holds, the cards in progress and where they sit, the jobs queued and
      the counts. Read access to the board and to its tree's root, since it
      names the cards on the root and on every sub-board beneath it.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Boards.Board
  alias Slipdock.Now
  alias SlipdockWeb.API.Authorize

  action_fallback SlipdockWeb.API.FallbackController

  def show(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, root} <- root(conn, board) do
      json(conn, Map.put(Now.snapshot(root), :board_id, Board.root_id(board)))
    end
  end

  @doc false
  # The tree's root, when the request may read it too; the refusal says why.
  def root(auth, board) do
    case Authorize.tree_root(auth, board, :read) do
      {:ok, root} -> {:ok, root}
      {:error, :forbidden, _} -> {:error, :forbidden, Now.refusal()}
    end
  end
end
