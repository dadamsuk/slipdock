defmodule Slipdock.Deployments.Incidents do
  @moduledoc """
  What counts as a failed change, and how long putting it right took
  (#1134). Incidents are ordinary cards on the project's board: tagged with
  the board's incident tag (`incident` unless changed), or linked to the
  deploy that caused them (`link/2`).

  A deploy is a **failed change** when any of these hold, counted once
  however many do (`failures/2` lists which):

    * `:failed` — it ended failed;
    * `:rolled_back` — the next deploy to its environment was a rollback;
    * `:incident` — an incident card is linked to it;
    * `:hotfix` — a deploy whose commits name an incident card followed it
      in its environment within the board's hotfix window (24h unless
      changed), the boundary included.

  **Time to restore** (`restores/2`): an incident card's creation to its
  completion; and for a failed deploy no incident is linked to, its finish
  to the next succeeded deploy in that environment.

  **Rework** (`rework?/2`): a deploy whose commits name an incident card —
  an unplanned fix rather than planned work.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card, Tag}
  alias Slipdock.Deployments.Deployment
  alias Slipdock.Repo

  @doc "The tag that marks `board`'s incident cards."
  def tag(%Board{incident_tag: tag}) when is_binary(tag) and tag != "", do: tag
  def tag(_board), do: "incident"

  @doc """
  Links incident `card` to the deploy that caused it, or unlinks it with
  nil. The deploy must be on the card's own board tree.
  """
  def link(%Card{} = card, nil),
    do: card |> Ecto.Changeset.change(caused_by_deployment_id: nil) |> Repo.update()

  def link(%Card{} = card, deployment_id) do
    card_root = card |> Repo.preload(:board) |> Map.fetch!(:board) |> Board.root_id()

    with {id, ""} <- Integer.parse(to_string(deployment_id)),
         %Deployment{} = d <- Repo.get(Deployment, id) |> Repo.preload(:board),
         true <- Board.root_id(d.board) == card_root do
      card |> Ecto.Changeset.change(caused_by_deployment_id: d.id) |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  `board`'s incident cards, whatever list they're in and archived or not:
  on its tree, tagged with its incident tag, or linked to one of its
  deploys. Each is `%{id, inserted_at, completed_at, deployment_id}`.
  """
  def cards(%Board{} = board) do
    root = Board.root_id(board)
    tag = String.downcase(tag(board))

    tagged =
      from c in Card,
        join: b in Board,
        on: b.id == c.board_id,
        join: ct in "card_tags",
        on: ct.card_id == c.id,
        join: t in Tag,
        on: t.id == ct.tag_id,
        where:
          (b.id == ^root or b.root_id == ^root) and is_nil(c.stand_in_for_id) and
            fragment("lower(?)", t.name) == ^tag,
        select: c.id

    linked =
      from c in Card,
        join: d in Deployment,
        on: d.id == c.caused_by_deployment_id,
        where: d.board_id == ^board.id,
        select: c.id

    ids = Repo.all(union(tagged, ^linked))

    Repo.all(
      from c in Card,
        where: c.id in ^ids,
        order_by: c.id,
        select: %{
          id: c.id,
          inserted_at: c.inserted_at,
          completed_at: c.completed_at,
          deployment_id: c.caused_by_deployment_id
        }
    )
  end

  @doc """
  Why each of `deployments` (a board's, any order) is a failed change:
  `%{deployment_id => [reason]}`, deploys that aren't left out. `incidents`
  is `cards/1`.
  """
  def failures(%Board{} = board, deployments, incidents \\ nil) do
    incidents = incidents || cards(board)
    incident_ids = MapSet.new(incidents, & &1.id)
    linked = for i <- incidents, i.deployment_id, into: MapSet.new(), do: i.deployment_id
    window = (board.hotfix_window_hours || 24) * 3600

    deployments
    |> Enum.group_by(& &1.environment)
    |> Enum.flat_map(fn {_env, ds} ->
      ds = Enum.sort_by(ds, &{DateTime.to_unix(&1.started_at, :microsecond), &1.id})
      pairs = Enum.zip(ds, tl(ds) ++ [nil])
      succeeded = Enum.filter(ds, &(&1.status == "succeeded"))

      Enum.map(ds, fn d ->
        {^d, next} = Enum.find(pairs, &(elem(&1, 0) == d))

        reasons =
          [
            d.status == "failed" && :failed,
            next && next.rollback && :rolled_back,
            MapSet.member?(linked, d.id) && :incident,
            hotfixed?(d, succeeded, incident_ids, window) && :hotfix
          ]
          |> Enum.filter(& &1)

        {d.id, reasons}
      end)
    end)
    |> Enum.reject(fn {_id, reasons} -> reasons == [] end)
    |> Map.new()
  end

  # A succeeded deploy is hotfixed when the next succeeded deploy to its
  # environment names an incident card and started within the window.
  defp hotfixed?(%Deployment{status: "succeeded"} = d, succeeded, incident_ids, window) do
    case Enum.drop_while(succeeded, &(&1.id != d.id)) do
      [_d, next | _] ->
        finished = d.finished_at || d.started_at

        rework?(next, incident_ids) and
          DateTime.diff(next.started_at, finished, :second) <= window

      _ ->
        false
    end
  end

  defp hotfixed?(_d, _succeeded, _incident_ids, _window), do: false

  @doc "Whether `deployment`'s commits name any of `incident_ids`: an unplanned fix."
  def rework?(%Deployment{card_ids: ids}, incident_ids),
    do: Enum.any?(ids || [], &MapSet.member?(incident_ids, &1))

  @doc """
  The restores among `deployments` and the board's incidents:
  `[%{kind: :incident | :deploy, id, from, to, seconds}]`, `to` being when it
  was put right. Open incidents and failed deploys not yet followed by a
  good one aren't restored, so aren't here.
  """
  def restores(%Board{} = board, deployments, incidents \\ nil) do
    incidents = incidents || cards(board)
    linked = for i <- incidents, i.deployment_id, into: MapSet.new(), do: i.deployment_id

    from_incidents =
      for %{completed_at: %DateTime{} = done} = i <- incidents do
        from = DateTime.truncate(i.inserted_at, :second)

        %{
          kind: :incident,
          id: i.id,
          from: from,
          to: done,
          seconds: max(DateTime.diff(done, from), 0)
        }
      end

    from_deploys =
      deployments
      |> Enum.group_by(& &1.environment)
      |> Enum.flat_map(fn {_env, ds} ->
        ds = Enum.sort_by(ds, &{DateTime.to_unix(&1.started_at, :microsecond), &1.id})

        for %{status: "failed"} = d <- ds,
            not MapSet.member?(linked, d.id),
            fixed = next_succeeded(ds, d),
            fixed != nil do
          from = d.finished_at || d.started_at
          to = fixed.finished_at || fixed.started_at
          %{kind: :deploy, id: d.id, from: from, to: to, seconds: max(DateTime.diff(to, from), 0)}
        end
      end)

    from_incidents ++ from_deploys
  end

  defp next_succeeded(ds, d) do
    ds
    |> Enum.drop_while(&(&1.id != d.id))
    |> Enum.drop(1)
    |> Enum.find(&(&1.status == "succeeded"))
  end
end
