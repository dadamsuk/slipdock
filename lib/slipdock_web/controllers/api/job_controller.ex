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

  ## A session taking jobs ---------------------------------------------------
  #
  # A Claude session (`/loop`, a scheduled task) takes jobs with the API token
  # it already has, as a runner of its own (see `Runners.session_runner/4`).
  # The same queue, leases and cancels as the runner protocol, in JSON.

  @doc """
  Takes the oldest queued job of `pool` on the board's tree, or answers
  `{"job": null}`. `wait` (seconds, at most 20) waits for one to arrive.
  """
  def claim(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, pool} <- need(params["pool"], "pool"),
         {:ok, runner} <- session(board, pool, conn) do
      case Runners.claim(runner, min(limit(params["wait"], 0), 20) * 1000) do
        nil -> json(conn, %{job: nil})
        job -> json(conn, %{job: V.job(job), lease_seconds: Runners.lease_for(runner)})
      end
    end
  end

  @doc """
  A session saying it is still at work: renews the lease, keeps `log` as the
  log tail and posts `note`, if given, as a comment on the card. Answers
  `{"status": "ok"}` or `{"status": "cancel"}` — stop, somebody cancelled it.
  """
  def progress(conn, %{"id" => id} = params) do
    with {:ok, job, card} <- fetch_job(conn, id, :write),
         {:ok, runner} <- session_job(job, conn),
         {:ok, answer} <- Runners.heartbeat(runner, job.id, params["log"] || params["note"]) do
      if note = blank(params["note"]),
        do: Boards.add_comment(card, note, by: conn.assigns.current_user)

      json(conn, %{status: to_string(answer)})
    end
  end

  @doc "A session saying the job has ended: `outcome` (done, failed, cancelled, timeout) and a `summary`."
  def finish(conn, %{"id" => id} = params) do
    outcome = params["outcome"] || "done"

    with {:ok, job, _card} <- fetch_job(conn, id, :write),
         {:ok, runner} <- session_job(job, conn),
         :ok <- outcome(outcome),
         {:ok, job} <-
           Runners.finish(runner, job.id, %{
             status: outcome,
             exit: if(outcome == "done", do: 0, else: 1),
             output: params["summary"]
           }) do
      json(conn, %{job: V.job(job)})
    end
  end

  defp session(board, pool, conn) do
    case Runners.session_runner(board, pool, conn.assigns.api_token, conn.assigns.current_user) do
      {:ok, runner} -> {:ok, runner}
      {:error, message} when is_binary(message) -> {:error, :unprocessable_entity, message}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp session_job(job, conn) do
    case Runners.session_job_runner(job.id, conn.assigns.api_token) do
      {:ok, runner} -> {:ok, runner}
      {:error, :not_found} -> {:error, :forbidden, "this job wasn't claimed with this token"}
    end
  end

  defp outcome(outcome) when outcome in ["done", "failed", "cancelled", "timeout"], do: :ok

  defp outcome(other),
    do:
      {:error, :unprocessable_entity,
       "outcome “#{other}” must be done, failed, cancelled or timeout"}

  defp need(value, key) do
    case blank(value) do
      nil -> {:error, :unprocessable_entity, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp blank(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank(_), do: nil

  defp fetch_job(conn, id, need) do
    with %{} = job <- Runners.get_job(id) || {:error, :not_found, "job"},
         %{} = card <- Boards.get_card(job.card_id) || {:error, :not_found, "job"},
         :ok <- Authorize.card(conn, card, need) do
      {:ok, job, card}
    end
  end

  defp limit(value, default \\ 50)
  defp limit(nil, default), do: default

  defp limit(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end
end
