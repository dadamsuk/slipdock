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
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      json(conn, %{release: V.release_status(Releases.status(board))})
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
