defmodule SlipdockWeb.API.GardenController do
  @moduledoc """
  The board gardener over HTTP (W-1807).

    * `GET /api/boards/:board/garden` – the open suggestions (`check=K`
      narrows), the last run and every check's settings. Read access.
    * `POST /api/boards/:board/garden {check?}` – a run now; answers it and
      the open suggestions. Write access.
    * `PATCH /api/boards/:board/garden/settings {check, enabled?, …}` – one
      check's switch and thresholds. Write access.
    * `POST /api/boards/:board/garden/proposals {explanation, steps,
      findings?, cards?}` – file a proposal (#1788, `Gardener.propose/4`):
      201 with it, or 200 with the one already filed. Write access.
    * `POST /api/garden/suggestions/:id/apply {keep?, choice?}`,
      `…/dismiss` and `…/undo` – decide one (`SlipdockWeb.Ops.GardenDecide`,
      #3188). Write access; a proposal, or a suggestion that edits a
      section, only a person's (not an agent's).
  """
  use SlipdockWeb, :controller

  alias Slipdock.Boards
  alias Slipdock.Gardener
  alias Slipdock.Gardener.Settings
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
         {:ok, check} <- check_param(params["check"]),
         {:ok, _run} <-
           Gardener.run(board,
             trigger: "manual",
             user: conn.assigns.current_user,
             only: check && [check]
           ) do
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

  def propose(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         :ok <- known(params, ~w(board explanation steps findings cards)) do
      case Gardener.propose(board, conn.assigns.current_user, Map.delete(params, "board")) do
        {:ok, s, :new} ->
          conn |> put_status(:created) |> json(%{suggestion: G.suggestion(s), created: true})

        {:ok, s, :exists} ->
          json(conn, %{suggestion: G.suggestion(s), created: false})

        error ->
          refused(error)
      end
    end
  end

  @doc "Decides one suggestion: made from `SlipdockWeb.Ops.GardenDecide` (#3188)."
  def decide(conn, params),
    do: SlipdockWeb.Ops.REST.run(conn, SlipdockWeb.Ops.GardenDecide, params)

  defp answer(conn, board, check) do
    json(conn, %{
      board_id: board.id,
      suggestions: G.suggestions(Gardener.list_open(board, check: check)),
      last_run: G.run(Gardener.last_run(board)),
      checks: G.checks(Boards.get_board_record!(board.id))
    })
  end

  defp check_param(nil), do: {:ok, nil}
  defp check_param(""), do: {:ok, nil}

  defp check_param(key) do
    if Enum.member?(Gardener.suggestion_keys(), key),
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
