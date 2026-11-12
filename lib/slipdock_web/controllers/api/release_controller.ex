defmodule SlipdockWeb.API.ReleaseController do
  @moduledoc """
  Batched releases over REST (#2835): `GET /api/boards/:board/release`,
  where the tree's releases stand, and `POST`, *Release now*. Releasing is
  the board owner's, as pausing is; reading is any reader's.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Releases
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  @doc "Where the tree's releases stand: `{\"release\": {...}}`."
  def show(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, _root} <- root(conn, board) do
      json(conn, %{release: V.release_status(Releases.status(board))})
    end
  end

  @doc false
  # A tree's releases are its root's, and name the root's cards: reading
  # them through a sub-board needs read on the root too (as the overseer's
  # doors do, `Authorize.tree_root/3`). The refusal says so. Whoever owns a
  # sub-board owns its root, so releasing asks nothing more.
  def root(auth, board) do
    case Authorize.tree_root(auth, board, :read) do
      {:ok, root} ->
        {:ok, root}

      {:error, :forbidden, _} ->
        {:error, :forbidden,
         "this board's releases are its tree's root board's, which you can't read"}
    end
  end

  @doc """
  *Release now*: `201` with `how` (`started`, `queued` behind the one
  running, or `joined` the follow-up already queued), the `request` and the
  tree's `release` status. `409` on a board that releases on merge, or when
  no runner could be given the job.
  """
  def create(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :owner) do
      by = Slipdock.Verified.who(Slipdock.Actor.from_conn(conn))

      case Releases.release_now(board, by) do
        {:ok, how, request} ->
          conn
          |> put_status(:created)
          |> json(%{
            how: how,
            line: Releases.said(how),
            request: V.release_request(request),
            release: V.release_status(Releases.status(board))
          })

        {:error, reason} ->
          {:error, :conflict, Releases.refusal(reason)}
      end
    end
  end
end
