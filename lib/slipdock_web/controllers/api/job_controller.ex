defmodule SlipdockWeb.API.JobController do
  @moduledoc """
  Runners and their jobs, for the board's people (see `Slipdock.Runners`).

  Making and revoking runners is the board owner's, like automation rules:
  a runner runs whatever its rules send it. Reading a card's jobs needs read
  access to the card, and cancelling one needs write.

  This is the side people and agents use with an ordinary API token. The
  runners themselves use `SlipdockWeb.API.RunnerController`.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Boards, Runners}
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  def runners(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :owner) do
      json(conn, %{runners: Enum.map(Runners.list_runners(board), &V.runner/1)})
    end
  end

  @doc "Makes a runner. The token is in this reply and nowhere else, ever."
  def create_runner(conn, %{"board" => ref} = params) do
    attrs = Map.take(params, ["name", "pool", "settings"])

    with {:ok, board} <- Authorize.fetch_board(conn, ref, :owner),
         {:ok, runner, token} <- Runners.create_runner(board, attrs, conn.assigns.current_user) do
      conn
      |> put_status(:created)
      |> json(%{runner: V.runner(runner), token: token})
    end
  end

  def delete_runner(conn, %{"board" => ref, "id" => id}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :owner),
         {:ok, runner} <- Runners.find_runner(board, id),
         {:ok, _} <- Runners.delete_runner(runner) do
      json(conn, %{ok: true})
    end
  end

  @doc "The jobs on the board's tree, newest first. `status` narrows them (`open` for all unfinished)."
  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      jobs = Runners.list_jobs(board, status: params["status"], limit: limit(params["limit"]))
      json(conn, %{jobs: Enum.map(jobs, &V.job/1)})
    end
  end

  def card_jobs(conn, %{"id" => id}) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(conn, card, :read) do
      json(conn, %{jobs: Enum.map(Runners.list_card_jobs(card.id), &V.job/1)})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, job, _card} <- fetch_job(conn, id, :read) do
      json(conn, %{job: V.job(job)})
    end
  end

  def cancel(conn, %{"id" => id}) do
    with {:ok, job, _card} <- fetch_job(conn, id, :write) do
      case Runners.cancel_job(job) do
        {:ok, job} -> json(conn, %{job: V.job(job)})
        {:error, message} -> {:error, :unprocessable_entity, message}
      end
    end
  end

  defp fetch_job(conn, id, need) do
    with %{} = job <- Runners.get_job(id) || {:error, :not_found, "job"},
         %{} = card <- Boards.get_card(job.card_id) || {:error, :not_found, "job"},
         :ok <- Authorize.card(conn, card, need) do
      {:ok, job, card}
    end
  end

  defp limit(nil), do: 50

  defp limit(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> n
      _ -> 50
    end
  end
end
