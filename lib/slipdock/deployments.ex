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
  `commits` (see `prepare_commits/2`: the cards are found here), `rollback`, `source`, `started_at` and — for a deploy
  recorded after the fact, such as a backfill — `status` and `finished_at`.
  `previous_sha` defaults to the environment's last succeeded deploy.
  """
  def start(%Board{} = board, attrs) do
    if enabled?(board) do
      attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      now = DateTime.utc_now()

      {commits, card_ids} = prepare_commits(board, attrs["commits"] || [])

      attrs =
        attrs
        |> Map.put("commits", commits)
        |> Map.put("card_ids", card_ids)
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

  @doc "The environment's latest deploy on `board`, however it went, or nil."
  def latest(%Board{id: board_id}, environment) do
    Repo.one(
      from d in Deployment,
        where: d.board_id == ^board_id and d.environment == ^environment,
        order_by: [desc: d.started_at, desc: d.id],
        limit: 1
    )
  end

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

  # -- The deploy token ------------------------------------------------------

  @doc """
  Issues `board` a new deploy token, replacing any it had: `{:ok, token,
  board}`. The token is returned this once; only its hash is kept. It
  records deploys for this board and does nothing else.
  """
  def issue_token(%Board{} = board) do
    token = "sdd_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, board} <-
           board |> Ecto.Changeset.change(deploy_token_hash: hash(token)) |> Repo.update() do
      {:ok, token, board}
    end
  end

  @doc "Revokes `board`'s deploy token: nothing can record deploys for it until a new one."
  def revoke_token(%Board{} = board),
    do: board |> Ecto.Changeset.change(deploy_token_hash: nil) |> Repo.update()

  @doc "Whether `board` has a deploy token."
  def token?(%Board{deploy_token_hash: hash}), do: not is_nil(hash)

  @doc "The board a deploy token belongs to, or nil."
  def authenticate("sdd_" <> _ = token) do
    Repo.one(
      from b in Board,
        where: b.deploy_token_hash == ^hash(String.trim(token)) and is_nil(b.archived_at)
    )
  end

  def authenticate(_token), do: nil

  defp hash(token), do: :crypto.hash(:sha256, token)

  # -- Commits and the cards they name ------------------------------------------

  @default_card_ref ~r/#(\d+)\b/

  @doc "The pattern `board` finds card ids with: its own, or `#NNN`."
  def card_ref_regex(%Board{card_ref_pattern: pattern})
      when is_binary(pattern) and pattern != "" do
    case Regex.compile(pattern) do
      {:ok, regex} -> regex
      {:error, _} -> @default_card_ref
    end
  end

  def card_ref_regex(_board), do: @default_card_ref

  @doc "The card ids a commit message names, in order, each once."
  def card_refs(%Board{} = board, message) when is_binary(message) do
    board
    |> card_ref_regex()
    |> Regex.scan(message, capture: :all_but_first)
    |> Enum.flat_map(fn
      [id | _] ->
        case Integer.parse(id) do
          {n, ""} when n > 0 -> [n]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  def card_refs(_board, _message), do: []

  @doc """
  Commits as CI sends them, cleaned up and with the cards each names: only
  cards on `board`'s own tree count, so a commit can't put a shipped line on
  somebody else's card. Each is `%{"sha", "committed_at", "subject",
  "cards"}`; anything not a map with a sha is dropped. At most 1,000.
  """
  def prepare_commits(%Board{} = board, commits) when is_list(commits) do
    commits =
      commits
      |> Enum.take(1000)
      |> Enum.flat_map(fn
        %{} = c ->
          c = Map.new(c, fn {k, v} -> {to_string(k), v} end)
          sha = c["sha"]

          if is_binary(sha) and Regex.match?(~r/^[0-9a-fA-F]{7,64}$/, sha) do
            message = to_string(c["subject"] || c["message"] || "")

            [
              %{
                "sha" => String.downcase(sha),
                "committed_at" => committed_at(c["committed_at"]),
                "subject" =>
                  message |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 300),
                "cards" => card_refs(board, message)
              }
            ]
          else
            []
          end

        _ ->
          []
      end)

    known = tree_cards(board, commits |> Enum.flat_map(& &1["cards"]) |> Enum.uniq())

    commits =
      Enum.map(commits, fn c -> %{c | "cards" => Enum.filter(c["cards"], &(&1 in known))} end)

    {commits, commits |> Enum.flat_map(& &1["cards"]) |> Enum.uniq()}
  end

  def prepare_commits(_board, _commits), do: {[], []}

  defp committed_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _ -> nil
    end
  end

  defp committed_at(_), do: nil

  # The ids among `ids` of cards on the same tree as `board`.
  defp tree_cards(_board, []), do: []

  defp tree_cards(%Board{} = board, ids) do
    root = Board.root_id(board)

    Repo.all(
      from c in Slipdock.Boards.Card,
        join: b in Board,
        on: b.id == c.board_id,
        where: c.id in ^ids and (b.id == ^root or b.root_id == ^root),
        select: c.id
    )
  end

  @doc "Where a board's deploys are announced (the setup wizard waits on it)."
  def topic(%Board{id: id}), do: "deployments:board:#{id}"

  defp broadcast(board, {:ok, deployment}),
    do: Phoenix.PubSub.broadcast(Slipdock.PubSub, topic(board), {:deployment, deployment})

  defp broadcast(_board, _result), do: :ok
end
