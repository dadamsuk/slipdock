defmodule SlipdockWeb.API.OverseerController do
  @moduledoc """
  The overseer over HTTP (#2068, `Slipdock.Overseer`). A sub-board answers
  for its tree's root, where the overseer's settings live.

    * `GET /api/boards/:board/overseer` – its settings, the open conditions
      and those cleared in the last day, the last digest, the next pass and
      the open one. Read access on the board and on its tree's root: those
      name cards anywhere in the tree.
    * `PATCH /api/boards/:board/overseer {enabled?, pool?, min_minutes?,
      max_minutes?, idle_minutes?, email?}` – turn it on or off and set its
      bounds. The board's owner.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Overseer
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.OverseerJSON

  action_fallback SlipdockWeb.API.FallbackController

  @fields ~w(enabled pool min_minutes max_minutes idle_minutes email)

  def show(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, root} <- Authorize.tree_root(conn, board, :read) do
      json(conn, %{overseer: OverseerJSON.state(Overseer.state(root))})
    end
  end

  def update(conn, %{"board" => ref} = params) do
    changes = Map.take(params, @fields)

    with {:ok, board} <- Authorize.fetch_board(conn, ref, :owner),
         :ok <- known(params),
         :ok <- something(changes) do
      with {:ok, _} <- Overseer.put_settings(board, changes) do
        json(conn, %{overseer: OverseerJSON.state(Overseer.state(board))})
      end
    end
  end

  defp known(params) do
    case Map.keys(params) -- ["board" | @fields] do
      [] -> :ok
      extra -> {:error, :unprocessable_entity, "unknown: #{Enum.join(extra, ", ")}"}
    end
  end

  defp something(changes) when changes == %{},
    do:
      {:error, :unprocessable_entity,
       "nothing to change: send one of #{Enum.join(@fields, ", ")}"}

  defp something(_changes), do: :ok
end
