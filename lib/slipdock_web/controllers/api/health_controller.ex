defmodule SlipdockWeb.API.HealthController do
  @moduledoc """
  The health monitor over HTTP (W-2310, see `Slipdock.Health`). Everything is
  about the tree the board is in, kept on its root board.

    * `GET /api/boards/:board/health` – the open and flagged incidents, the
      recent finished ones, when the monitor last ran and every detector's
      settings, and the pulse (`/healthz`'s clocks). Read access.
    * `POST /api/boards/:board/health` – a run now; answers as GET. Write access.
    * `PATCH /api/boards/:board/health/settings {detector, enabled?, max_attempts?, …}`
      – one detector's switch and thresholds. Write access.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Boards.Board
  alias Slipdock.Health
  alias Slipdock.Health.Settings
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.HealthJSON, as: H

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read), do: answer(conn, board)
  end

  def create(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write) do
      {:ok, _counts} = Health.run(board)
      answer(conn, board)
    end
  end

  def settings(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, detector} <- detector(params["detector"]),
         {:ok, _} <-
           refused(
             Settings.put(Board.root_id(board), detector, Map.drop(params, ~w(board detector)))
           ) do
      json(conn, %{detectors: H.detectors(Health.detector_settings(board))})
    end
  end

  defp answer(conn, board) do
    json(conn, %{
      board_id: Board.root_id(board),
      last_run: Health.last_run(),
      pulse: Health.pulse(),
      incidents: Enum.map(Health.list_active(board), &H.incident/1),
      recent: Enum.map(Health.list_recent(board), &H.incident/1),
      detectors: H.detectors(Health.detector_settings(board))
    })
  end

  defp detector(key) when key in [nil, ""],
    do: {:error, :bad_request, "detector is required: one of #{keys()}"}

  defp detector(key) do
    case Health.detector(key) do
      nil -> {:error, :bad_request, "unknown detector #{inspect(key)}: one of #{keys()}"}
      d -> {:ok, d}
    end
  end

  defp keys, do: Health.detectors() |> Enum.map(& &1.key()) |> Enum.join(", ")

  defp refused({:ok, _} = ok), do: ok
  defp refused({:error, message}), do: {:error, :unprocessable_entity, message}
end
