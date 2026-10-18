defmodule SlipdockWeb.API.GardenController do
  @moduledoc """
  The board gardener over HTTP (W-1807).

    * `GET /api/boards/:board/garden` – the open suggestions (`check=K`
      narrows), the last run and every check's settings. Read access.
    * `POST /api/boards/:board/garden {check?}` – a run now; answers it and
      the open suggestions. Write access.
    * `PATCH /api/boards/:board/garden/settings {check, enabled?, …}` – one
      check's switch and thresholds. Write access.
    * `POST /api/garden/suggestions/:id/apply {keep?, choice?}`,
      `…/dismiss` and `…/undo` – decide one. Write access.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Boards.Board
  alias Slipdock.Gardener
  alias Slipdock.Gardener.Settings
  alias Slipdock.Repo
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.GardenJSON, as: G

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, check} <- check_param(params["check"]) do
      answer(conn, board, check)
    end
  end

  def create(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         :ok <- known(params, ~w(board check)),
         {:ok, check} <- check_param(params["check"]) do
      {:ok, _run} =
        Gardener.run(board,
          trigger: "manual",
          user: conn.assigns.current_user,
          only: check && [check]
        )

      answer(conn, board, check)
    end
  end

  def settings(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, key} <- check_param(params["check"]),
         {:ok, check} <- required_check(key),
         {:ok, board} <- refused(Settings.put(board, check, Map.drop(params, ["board", "check"]))) do
      json(conn, %{checks: G.checks(board)})
    end
  end

  def apply(conn, %{"id" => id} = params) do
    with :ok <- known(params, ~w(id keep choice)) do
      decide(conn, id, :write, fn s, user ->
        Gardener.apply(s, user, keep: params["keep"], choice: params["choice"])
      end)
    end
  end

  def dismiss(conn, %{"id" => id}), do: decide(conn, id, :write, &Gardener.dismiss/2)

  def undo(conn, %{"id" => id}), do: decide(conn, id, :write, &Gardener.undo/2)

  defp decide(conn, id, need, fun) do
    with {:ok, suggestion} <- fetch(id),
         board = Repo.get!(Board, suggestion.board_id),
         :ok <- readable(conn, board),
         :ok <- Authorize.board(conn, board, need),
         {:ok, suggestion} <- refused(fun.(suggestion, conn.assigns.current_user)) do
      json(conn, %{suggestion: G.suggestion(suggestion)})
    end
  end

  defp answer(conn, board, check) do
    json(conn, %{
      board_id: board.id,
      suggestions: G.suggestions(Gardener.list_open(board, check: check)),
      last_run: G.run(Gardener.last_run(board)),
      checks: G.checks(Repo.get!(Board, board.id))
    })
  end

  # A suggestion on a board the caller can't read is one they don't know of.
  defp readable(conn, board) do
    case Authorize.board(conn, board, :read) do
      :ok -> :ok
      _ -> {:error, :not_found, "suggestion"}
    end
  end

  defp fetch(id) do
    case Gardener.get_suggestion(id) do
      nil -> {:error, :not_found, "suggestion"}
      s -> {:ok, s}
    end
  end

  defp check_param(nil), do: {:ok, nil}
  defp check_param(""), do: {:ok, nil}

  defp check_param(key) do
    if Gardener.check(key),
      do: {:ok, key},
      else:
        {:error, :bad_request,
         "unknown check #{inspect(key)}: one of #{Enum.join(Gardener.check_keys(), ", ")}"}
  end

  defp required_check(nil),
    do:
      {:error, :bad_request,
       "check is required: one of #{Enum.join(Gardener.check_keys(), ", ")}"}

  defp required_check(key), do: {:ok, Gardener.check(key)}

  defp known(params, allowed) do
    case Map.keys(params) -- allowed do
      [] -> :ok
      extra -> {:error, :bad_request, "unknown field(s): #{Enum.join(Enum.sort(extra), ", ")}"}
    end
  end

  defp refused({:ok, _} = ok), do: ok

  defp refused({:error, :forbidden}),
    do: {:error, :forbidden, "you can't change everything this suggestion touches"}

  defp refused({:error, %Ecto.Changeset{}} = error), do: error

  defp refused({:error, message}) when is_binary(message),
    do: {:error, :unprocessable_entity, message}
end
