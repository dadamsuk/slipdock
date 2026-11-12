defmodule Slipdock.Releases do
  @moduledoc """
  Batched releases (#2833): merging doesn't change, releasing does.

  A board's `release_mode` (`Board.release_modes/0`) is `on_merge`, where
  each merge deploys as it always has, or `batched`, where a merge waits for
  a release. `release_age_cap_hours` is how long the oldest waiting merge
  may wait before it triggers one (nil is off). Both belong to the tree:
  they are set on its root board (`Board.changeset/2` refuses them on a
  sub-board) and read from there by `mode/1` and `age_cap_hours/1`.

  A card's release state (`state/1`, #2834) is worked out on read from the
  existing Deployments record: on a batched board, a merged card is
  `awaiting` until a succeeded deploy names it, then `released`. A card
  still completes, and its dependents unblock, when it merges; the release
  state is shown afterwards and changes neither.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Deployments
  alias Slipdock.Repo

  @doc """
  The release settings of `board`'s tree, read from its root:
  `%{mode: "on_merge" | "batched", age_cap_hours: integer | nil}`.
  `board` is a board or a board id.
  """
  def settings(%Board{root_id: nil} = board),
    do: %{mode: board.release_mode, age_cap_hours: board.release_age_cap_hours}

  def settings(%Board{root_id: root_id}), do: settings(root_id)

  def settings(board_id) when is_integer(board_id) do
    from(b in Board,
      left_join: r in Board,
      on: r.id == b.root_id,
      where: b.id == ^board_id,
      select:
        {r.id, r.release_mode, r.release_age_cap_hours, b.release_mode, b.release_age_cap_hours}
    )
    |> Repo.one()
    |> case do
      nil -> %{mode: "on_merge", age_cap_hours: nil}
      {nil, _, _, mode, cap} -> %{mode: mode, age_cap_hours: cap}
      {_root, mode, cap, _, _} -> %{mode: mode, age_cap_hours: cap}
    end
  end

  @doc "`board`'s release mode, from its tree's root: `on_merge` or `batched`."
  def mode(board), do: settings(board).mode

  @doc "Whether `board`'s tree releases in batches."
  def batched?(board), do: mode(board) == "batched"

  @doc """
  `card`'s release state (#2834), or nil: nil on a board that releases on
  merge and for a card that hasn't merged. Otherwise

    * `%{state: "awaiting", sha, merged_at}`: merged, awaiting release;
    * `%{state: "released", sha, merged_at, environment, deployment_id, at}`:
      a succeeded deploy names it (the latest, where there are several).

  A card has merged when it is completed and accepted with a commit: the
  merge's (`merge_sha`) on a board that ships by pull request, else the one
  it was accepted at (`verify_commit`, else `evidence_commit`).
  """
  def state(%Card{} = card) do
    with true <- card.completed == true,
         sha when is_binary(sha) <- merged_sha(card),
         true <- batched?(card.board_id) do
      base = %{sha: sha, merged_at: card.completed_at}

      case Deployments.shipped(card) do
        [] ->
          Map.put(base, :state, "awaiting")

        [latest | _] ->
          Map.merge(base, %{
            state: "released",
            environment: latest.environment,
            deployment_id: latest.deployment_id,
            at: latest.at
          })
      end
    else
      _ -> nil
    end
  end

  defp merged_sha(%Card{verify_state: "accepted"} = card),
    do: card.merge_sha || card.verify_commit || card.evidence_commit

  defp merged_sha(_card), do: nil

  @doc """
  A release state in words, its time in `zone`: `Merged 1a2b3c4, awaiting
  release · since 12 Nov 10:04`, or `Released to production · 12 Nov 14:32`.
  """
  def text(state, zone \\ "Etc/UTC")

  def text(%{state: "awaiting"} = s, zone) do
    "Merged #{String.slice(s.sha, 0, 7)}, awaiting release" <>
      if(s.merged_at, do: " · since #{Deployments.time_text(s.merged_at, zone)}", else: "")
  end

  def text(%{state: "released"} = s, zone),
    do: "Released to #{s.environment} · #{Deployments.time_text(s.at, zone)}"
end
