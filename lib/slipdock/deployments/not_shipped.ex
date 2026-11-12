defmodule Slipdock.Deployments.NotShipped do
  @moduledoc """
  Merged cards that never went live (#2819): the server notices by itself,
  whatever CI did or didn't report. A pipeline that fails before its deploy
  job records no deploy at all, so a merged card looks the same as one
  still deploying for as long as it stays that way.

  A card counts as **merged** when it is done and accepted with a merge
  commit (`merge_sha`, a board that ships by pull request) or, on a board
  that ships by push, with the commit it was accepted at. It is **not
  shipped** when no succeeded deploy names it (`card_ids`, as
  `Slipdock.Deployments.shipped/1` reads them) once the board's
  `not_shipped_minutes` have gone by since it finished (20 unless set; 0
  turns the watch off).

  Which board's settings: the tree's delivery board, its root when the
  root has delivery metrics on, else the first board in the tree that has.
  A tree with none is never watched. Only cards merged after that board's
  `delivery_metrics_since` count, which is when its metrics were turned on,
  or when this watch arrived for a board that had them on already: nothing
  merged earlier fires. An archived card, a stand-in and an epic (a card
  with subcards ships through them) never count.

  **On a tree that releases in batches** (#2839, `Slipdock.Releases`) a
  merge isn't a deploy, so the minutes count from the card's release, not
  its merge: from the start of the latest release request that covers the
  card (`Slipdock.Releases.Request`, its `started_at`, whatever became of
  it). A card that is only awaiting release is never late, however long it
  waits; one whose release started and came to nothing is. The line then
  carries `release_requested_at`, and `seconds` run from it.

  `Slipdock.Overseer.Checks.NotShipped` raises the board's alert from
  `in_tree/3`; a card's own line comes from `for_card/2`, so it shows and
  goes on the same facts.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Deployments.Deployment
  alias Slipdock.Releases.Request
  alias Slipdock.Repo

  @doc """
  The tree's delivery board: `root` when it has delivery metrics on, else
  the first of `board_ids` that has, else nil.
  """
  def delivery_board(%Board{delivery_metrics: true} = root, _board_ids), do: root

  def delivery_board(%Board{}, board_ids) do
    Repo.one(
      from b in Board,
        where: b.id in ^board_ids and b.delivery_metrics and is_nil(b.archived_at),
        order_by: [asc: b.id],
        limit: 1
    )
  end

  @doc """
  The merged cards on `board_ids` (one tree, its root `root`) that have
  not shipped as of `now`, oldest merge first: each `%{card_id, title, sha,
  merged_at, seconds, minutes}`, `minutes` being the board's setting, and
  `release_requested_at` on a tree that releases in batches.
  """
  def in_tree(%Board{} = root, board_ids, %DateTime{} = now) do
    case delivery_board(root, board_ids) do
      %Board{} = board -> find(board, root, where(Card, [c], c.board_id in ^board_ids), now)
      nil -> []
    end
  end

  @doc """
  `card`'s not-shipped line as of `now`, or nil: `%{sha, merged_at,
  seconds, minutes, text}`, the text `Merged 1a634c6 · not shipped after
  45m`. On a tree that releases in batches it has `release_requested_at`
  too, and reads `Merged 1a634c6 · not shipped 45m after its release
  started`.
  """
  def for_card(card, now \\ DateTime.utc_now())

  def for_card(%Card{completed: true, verify_state: "accepted"} = card, %DateTime{} = now) do
    root_id =
      Repo.one(from b in Board, where: b.id == ^card.board_id, select: coalesce(b.root_id, b.id))

    with id when is_integer(id) <- root_id,
         %Board{} = root <- Repo.get(Board, id),
         ids = Repo.all(from b in Board, where: b.id == ^id or b.root_id == ^id, select: b.id),
         %Board{} = board <- delivery_board(root, ids),
         [line] <- find(board, root, where(Card, [c], c.id == ^card.id), now) do
      line |> Map.drop([:card_id, :title]) |> Map.put(:text, text(line))
    else
      _ -> nil
    end
  end

  def for_card(_card, _now), do: nil

  @doc """
  The line in words: `Merged 1a634c6 · not shipped after 45m`, or, counted
  from a batched tree's release, `Merged 1a634c6 · not shipped 45m after
  its release started`.
  """
  def text(%{sha: sha, seconds: seconds, release_requested_at: %DateTime{}}) do
    "Merged #{short(sha)} · not shipped #{Slipdock.Overseer.Check.duration(seconds)} " <>
      "after its release started"
  end

  def text(%{sha: sha, seconds: seconds}),
    do: "Merged #{short(sha)} · not shipped after #{Slipdock.Overseer.Check.duration(seconds)}"

  @doc "A sha as people read it: its first seven characters."
  def short(sha), do: String.slice(sha, 0, 7)

  # Off, or metrics on with no time to count from: nothing.
  defp find(%Board{not_shipped_minutes: minutes, delivery_metrics_since: since}, _root, _c, _now)
       when minutes in [nil, 0] or is_nil(since),
       do: []

  defp find(%Board{not_shipped_minutes: minutes} = board, root, cards, now) do
    late = DateTime.add(now, -minutes * 60, :second)

    cards
    |> unshipped(board.delivery_metrics_since)
    |> late(root, late)
    |> Repo.all()
    |> Enum.map(fn line ->
      line
      |> Map.put(:seconds, DateTime.diff(now, line[:release_requested_at] || line.merged_at))
      |> Map.put(:minutes, minutes)
    end)
  end

  # Whose clock has run out. A tree that releases in batches counts from
  # the start of the latest release request covering the card (#2839): no
  # request, no clock. Any other tree counts from the merge.
  defp late(query, %Board{release_mode: "batched", id: root_id}, late) do
    asked =
      from r in Request,
        where: r.board_id == ^root_id,
        where: fragment("? = ANY(?)", parent_as(:card).id, r.card_ids),
        select: %{at: max(r.started_at)}

    query
    |> join(:inner_lateral, [card: c], r in subquery(asked), as: :asked, on: true)
    |> where([asked: r], r.at <= ^late)
    |> select_merge([asked: r], %{release_requested_at: r.at})
  end

  defp late(query, %Board{}, late), do: where(query, [card: c], c.completed_at <= ^late)

  # The merged cards no succeeded deploy names, merged since `since`.
  defp unshipped(cards, since) do
    cards
    |> from(as: :card)
    |> join(:inner, [card: c], b in Board, as: :board, on: b.id == c.board_id)
    |> where([card: c], c.completed and c.verify_state == "accepted")
    |> where([card: c], is_nil(c.archived_at) and is_nil(c.stand_in_for_id))
    |> where([card: c], c.completed_at > ^since)
    # A board that ships by pull request merges: only a merge commit counts.
    |> where(
      [card: c, board: b],
      not is_nil(c.merge_sha) or
        (not (b.ship_via == "pull_request" and b.verify_work) and
           not is_nil(coalesce(c.verify_commit, c.evidence_commit)))
    )
    |> where(
      [card: c],
      not exists(from s in Board, where: s.parent_card_id == parent_as(:card).id, select: 1)
    )
    |> where(
      [card: c],
      not exists(
        from d in Deployment,
          join: db in Board,
          on: db.id == d.board_id,
          where:
            db.delivery_metrics and d.status == "succeeded" and
              fragment("? @> ARRAY[?]", d.card_ids, parent_as(:card).id),
          select: 1
      )
    )
    |> order_by([card: c], asc: c.completed_at, asc: c.id)
    |> select([card: c], %{
      card_id: c.id,
      title: c.title,
      sha: coalesce(c.merge_sha, coalesce(c.verify_commit, c.evidence_commit)),
      merged_at: c.completed_at
    })
  end
end
