defmodule SlipdockWeb.API.DeploymentController do
  @moduledoc """
  How deploys get in (#1134): what CI calls, with the board's deploy token
  (`Authorization: Bearer sdd_…`), never an API token. The board comes from
  the token, and the token can do nothing but this.

      GET   /api/deployments/last?environment=E   the sha to diff from
      POST  /api/deployments                      record a deploy starting (or finished)
      PATCH /api/deployments/:id                  finish it: status succeeded|failed

  Refused (403, saying how to turn them on) while the board's delivery
  metrics are off, so nothing accumulates unseen. Rate-limited per board.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Deployments, RateLimit}
  alias SlipdockWeb.API.JSON, as: V

  plug :fetch_deploy_board
  plug :require_on
  plug :rate_limit

  action_fallback SlipdockWeb.API.FallbackController

  # A busy monorepo deploys a few services a minute; nothing honest needs more.
  @per_minute 120

  def last(conn, params) do
    board = conn.assigns.board
    environment = params["environment"] || "production"
    last = Deployments.last_succeeded(board, environment)

    json(conn, %{
      board: %{id: board.id, code: board.code},
      environment: environment,
      # So `slipdock deploy --dry-run` names the cards the way the board will.
      card_ref_pattern: board.card_ref_pattern,
      sha: last && last.sha,
      deployment: last && V.deployment(last)
    })
  end

  def create(conn, params) do
    attrs =
      params
      |> Map.take(
        ~w(environment sha tag previous_sha commits rollback status started_at finished_at source)
      )
      |> Map.update("source", "api", &(&1 || "api"))

    with {:ok, deployment} <- Deployments.start(conn.assigns.board, attrs) do
      conn |> put_status(:created) |> json(%{deployment: V.deployment(deployment)})
    end
  end

  def finish(conn, %{"id" => id} = params) do
    with {:ok, deployment} <- Deployments.finish(conn.assigns.board, id, params["status"]) do
      json(conn, %{deployment: V.deployment(deployment)})
    end
  end

  defp fetch_deploy_board(conn, _opts) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> String.trim(token)
        _ -> nil
      end

    case Deployments.authenticate(token) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          error:
            "unauthorized: pass the board's deploy token as `Authorization: Bearer sdd_…` " <>
              "(SLIPDOCK_DEPLOY_TOKEN for the CLI)"
        })
        |> halt()

      board ->
        assign(conn, :board, board)
    end
  end

  defp require_on(conn, _opts) do
    board = conn.assigns.board

    if Deployments.enabled?(board) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "delivery_metrics_off", message: Deployments.off_message(board)})
      |> halt()
    end
  end

  defp rate_limit(conn, _opts) do
    case RateLimit.hit("deployments:#{conn.assigns.board.id}", @per_minute, 60_000) do
      :ok ->
        conn

      {:error, seconds} ->
        conn
        |> put_resp_header("retry-after", to_string(seconds))
        |> put_status(:too_many_requests)
        |> json(%{error: "too many deploys for this board: try again in #{seconds}s"})
        |> halt()
    end
  end
end
