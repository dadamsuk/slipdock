defmodule Slipdock.Deployments do
  @moduledoc """
  The deployments ledger (#1134): what was deployed where and when, written
  by CI and read by `Slipdock.Dora` and a card's shipped lines. Deploys hang
  off the project's board, never as cards.

  Nothing gets in unless the board's "Delivery metrics" switch is on
  (`delivery_metrics`): while it is off every write answers `{:error, :off}`,
  so no data accumulates where nobody can see it.

  Rows are written only here — started, then finished once — and never
  edited after that.
  """

  import Ecto.Query

  alias Slipdock.Boards.Board
  alias Slipdock.Deployments.Deployment
  alias Slipdock.Repo

  @doc "Whether `board` takes deploys and shows delivery metrics."
  def enabled?(%Board{delivery_metrics: on}), do: on == true

  @doc "What to tell someone whose board has delivery metrics off."
  def off_message(%Board{} = board) do
    "delivery metrics are off for board #{board.code}: turn them on in the board's settings " <>
      "(Delivery metrics), or `slipdock set-board #{board.code} --delivery-metrics`"
  end

  @doc """
  Records a deploy starting on `board`: `{:ok, deployment}`, `{:error, :off}`
  while the switch is off, or `{:error, changeset}`.

  `attrs` are `environment`, `sha` and optionally `tag`, `previous_sha`,
  `commits`, `card_ids`, `rollback`, `source`, `started_at` and — for a deploy
  recorded after the fact, such as a backfill — `status` and `finished_at`.
  `previous_sha` defaults to the environment's last succeeded deploy.
  """
  def start(%Board{} = board, attrs) do
    if enabled?(board) do
      attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.put_new("started_at", now)
        |> Map.put_new_lazy("previous_sha", fn -> last_sha(board, attrs["environment"]) end)
        |> Map.put_new("status", "started")

      %Deployment{board_id: board.id}
      |> Deployment.start_changeset(attrs)
      |> Repo.insert()
      |> tap(&broadcast(board, &1))
    else
      {:error, :off}
    end
  end

  @doc """
  Finishes deploy `id` on `board` as `succeeded` or `failed`. A deploy that
  isn't this board's is `{:error, :not_found}`; one already finished is a
  changeset error.
  """
  def finish(%Board{} = board, id, status, opts \\ []) do
    at = Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)

    cond do
      not enabled?(board) ->
        {:error, :off}

      deployment = get(board, id) ->
        deployment
        |> Deployment.finish_changeset(to_string(status), at)
        |> Repo.update()
        |> tap(&broadcast(board, &1))

      true ->
        {:error, :not_found}
    end
  end

  @doc "Deploy `id` if it is `board`'s, else nil."
  def get(%Board{id: board_id}, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get_by(Deployment, id: id, board_id: board_id)
      _ -> nil
    end
  end

  @doc "The environment's last succeeded deploy on `board`, or nil."
  def last_succeeded(%Board{id: board_id}, environment) when is_binary(environment) do
    Repo.one(
      from d in Deployment,
        where:
          d.board_id == ^board_id and d.environment == ^environment and
            d.status == "succeeded",
        order_by: [desc: d.finished_at, desc: d.id],
        limit: 1
    )
  end

  def last_succeeded(_board, _environment), do: nil

  @doc "The sha the environment last succeeded with on `board`: what the next deploy diffs from."
  def last_sha(board, environment) do
    case last_succeeded(board, environment) do
      %Deployment{sha: sha} -> sha
      nil -> nil
    end
  end

  @doc """
  `board`'s deploys started in a window, oldest first. Options: `:since`
  and `:until` (DateTimes), `:environment`, `:status`.
  """
  def list(%Board{id: board_id}, opts \\ []) do
    Deployment
    |> where([d], d.board_id == ^board_id)
    |> filter(opts)
    |> order_by([d], asc: d.started_at, asc: d.id)
    |> Repo.all()
  end

  defp filter(query, opts) do
    Enum.reduce(opts, query, fn
      {:since, %DateTime{} = t}, q -> where(q, [d], d.started_at >= ^t)
      {:until, %DateTime{} = t}, q -> where(q, [d], d.started_at < ^t)
      {:environment, env}, q when is_binary(env) -> where(q, [d], d.environment == ^env)
      {:status, s}, q when is_binary(s) -> where(q, [d], d.status == ^s)
      _, q -> q
    end)
  end

  @doc "The environments `board` has deployed to, most deploys first."
  def environments(%Board{id: board_id}) do
    Repo.all(
      from d in Deployment,
        where: d.board_id == ^board_id,
        group_by: d.environment,
        order_by: [desc: count(d.id), asc: d.environment],
        select: d.environment
    )
  end

  @doc "Where a board's deploys are announced (the setup wizard waits on it)."
  def topic(%Board{id: id}), do: "deployments:board:#{id}"

  defp broadcast(board, {:ok, deployment}),
    do: Phoenix.PubSub.broadcast(Slipdock.PubSub, topic(board), {:deployment, deployment})

  defp broadcast(_board, _result), do: :ok
end
