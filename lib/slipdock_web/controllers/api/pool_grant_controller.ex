defmodule SlipdockWeb.API.PoolGrantController do
  @moduledoc """
  Who besides the board's owner takes a runner pool's jobs (#3492,
  `Slipdock.Runners.PoolGrants`): the root board's owner lists, grants and
  takes back a pool for a person who can write the board.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Runners.PoolGrants
  alias SlipdockWeb.API.Authorize

  action_fallback SlipdockWeb.API.FallbackController

  @doc "GET /api/boards/:board/pool-grants — every pool's grants, or `pool`'s."
  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :owner) do
      grants =
        case params["pool"] do
          pool when is_binary(pool) and pool != "" ->
            pool = PoolGrants.normalize(pool)
            board |> PoolGrants.list() |> Enum.filter(&(&1.pool == pool))

          _ ->
            PoolGrants.list(board)
        end

      json(conn, %{pool_grants: Enum.map(grants, &grant/1)})
    end
  end

  @doc "POST /api/boards/:board/pool-grants — `pool` and `email`: grant the pool."
  def create(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :owner),
         {:ok, pool} <- need(params, "pool"),
         {:ok, email} <- need(params, "email") do
      case PoolGrants.grant(board, pool, email) do
        {:ok, g} -> conn |> put_status(:created) |> json(%{pool_grant: grant(g)})
        {:error, :invalid, message} -> {:error, :unprocessable_entity, message}
        other -> other
      end
    end
  end

  @doc "DELETE /api/boards/:board/pool-grants — `pool` and `email`: take it back."
  def delete(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :owner),
         {:ok, pool} <- need(params, "pool"),
         {:ok, email} <- need(params, "email") do
      case PoolGrants.revoke(board, pool, email) do
        :ok -> json(conn, %{revoked: %{pool: PoolGrants.normalize(pool), email: email}})
        {:error, :not_found} -> {:error, :not_found, "pool grant"}
        other -> other
      end
    end
  end

  defp need(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :unprocessable_entity, "#{key} is required"}
    end
  end

  defp grant(g) do
    %{
      id: g.id,
      pool: g.pool,
      user: %{id: g.user.id, email: g.user.email, name: g.user.name},
      granted_by: g.granted_by && g.granted_by.email,
      inserted_at: g.inserted_at
    }
  end
end
