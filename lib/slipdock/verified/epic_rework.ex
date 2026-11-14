defmodule Slipdock.Verified.EpicRework do
  @moduledoc """
  A rejected subcard's rework when nothing is working its epic (#3184).

  A runner's job on an epic builds its subcards inside itself, and may end
  with the epic in progress, waiting for a subcard's verdict. A rejection
  then sends the subcard back to the top of its own sub-board's ready list
  (`Slipdock.Verified.Outcome.send_back/4`), but no feed takes from a
  sub-board's list: the feeds (`list_top` rules) take the root board's. With
  no job open on the epic, the rework sat there with nobody on it.

  Two halves, one reading of "stalled":

    * `send_again/2`, on each rejection: when no build job is open
      (queued, claimed or running, of a kind that isn't `verify`, `merge` or
      the overseer's) on the subcard or any card above it, the epic (its
      top-level ancestor) goes back to the top of its feed's list (the list
      its last job's `list_top` rule takes from, else its board's ready
      list), with a comment saying why, and its board is fed;
    * `stalled/1`, for `Slipdock.Now` and the health monitor's
      `stalled_rework` detector: which of a set of cards are epics with such
      a rework waiting and no job.

  A subcard with an open wait (a person's to answer, such as a rejection
  over the board's limit) isn't stalled: the answer sends it. Nor is an
  epic a person put in its list: the last time it was put into a list, an
  agent did it (`Slipdock.Health.Cards.agent_driven/1`), as the health
  monitor reads it, so a person's card is never moved (SPEC-8).
  """

  import Ecto.Query

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.{Board, Card, Column, Wait}
  alias Slipdock.Runners.Job

  @waiting_states ["pending", "merging", "held"]

  @doc "The job kinds that don't build a card: they check, merge or oversee it."
  def not_builds, do: [Slipdock.Overseer.kind() | Slipdock.Verified.finishing_kinds()]

  @doc """
  After `subcard` was rejected and sent back: sends its epic again when no
  build job is open on the subcard or above it. Returns `{:sent, epic,
  column}` when the epic was moved, else `:none` (no epic), `:held` (a job
  is open, or the subcard waits on a person) or `:in_place` (the epic isn't
  in a doing list: its feed takes it from where it is, or a person keeps
  it).
  """
  def send_again(%Card{} = subcard, actor \\ Slipdock.Actor.automation()) do
    subcard = Repo.preload(Repo.get!(Card, subcard.id), :board, force: true)

    case Boards.ancestry(subcard.board) do
      [] ->
        :none

      [%{card: epic} | _] = above ->
        ids = [subcard.id | Enum.map(above, & &1.card.id)]

        if open_build?(ids) or open_wait?(subcard.id),
          do: :held,
          else: move_epic(Repo.get!(Card, epic.id), subcard, actor)
    end
  end

  defp move_epic(%Card{} = epic, subcard, actor) do
    epic = Repo.preload(epic, :column)

    with true <- movable?(epic),
         {:ok, %Column{} = column} <- home(epic) do
      Boards.Comments.add_comment(
        epic,
        "**Sent again:** ##{subcard.id} “#{subcard.title}” was rejected and no job is " <>
          "open on it or on this epic, so the epic is back at the top of #{column.name} " <>
          "for its rework."
      )

      :ok = Boards.Cards.move_card_to_index(Repo.get!(Card, epic.id), column, :top, actor: actor)

      Boards.ActivityLog.log_activity(
        epic.board_id,
        epic.id,
        "rework",
        "sent ##{epic.id} again for the rework of ##{subcard.id}"
      )

      Slipdock.Automations.feed_board(epic.board_id)
      {:sent, Repo.get!(Card, epic.id), column}
    else
      _ -> :in_place
    end
  end

  # Open, in a doing list an agent put it in, and not waiting on its own
  # verifier, merge or a person's say-so.
  defp movable?(%Card{} = epic) do
    epic.completed == false and is_nil(epic.archived_at) and
      not Enum.member?(@waiting_states, epic.verify_state) and
      match?(%Column{}, epic.column) and Slipdock.Flow.doing_list?(epic.column) and
      MapSet.member?(Slipdock.Health.Cards.agent_driven([epic.id]), epic.id)
  end

  @doc """
  Where `card` goes to be sent again: the list its last job's `list_top`
  rule takes from, when that rule is on its own board, else its board's
  ready list (`Slipdock.Health.Detectors.OrphanInProgress.home/1`, which
  puts an orphaned card back the same way).
  """
  defdelegate home(card), to: Slipdock.Health.Detectors.OrphanInProgress

  @doc """
  Which of `card_ids` have a stalled rework: `epic_id => [%{id, title,
  rejected_at}]`, the open, unarchived subcards on its sub-board that were
  rejected and are waiting to be built again, with no open wait, while no
  build job is open on the subcard, the epic or any card above the epic,
  and an agent last put the epic in its list. Cards with none are left out.
  Whether the epic is in a doing list is the caller's to say.
  """
  def stalled([]), do: %{}

  def stalled(card_ids) do
    rows =
      from(s in Card,
        join: b in Board,
        on: b.id == s.board_id,
        where:
          b.parent_card_id in ^card_ids and is_nil(b.archived_at) and is_nil(s.archived_at) and
            s.completed == false and s.verify_state == "rejected" and
            is_nil(s.stand_in_for_id),
        where: s.id not in subquery(open_wait_cards()),
        order_by: [asc: s.id],
        select: {b.parent_card_id, %{id: s.id, title: s.title, rejected_at: s.verify_at}}
      )
      |> Repo.all()

    epic_ids = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    building = building(Enum.map(rows, &elem(&1, 1).id) ++ epic_ids)
    agents = Slipdock.Health.Cards.agent_driven(epic_ids)

    rows
    |> Enum.filter(fn {epic_id, _s} -> MapSet.member?(agents, epic_id) end)
    |> Enum.reject(fn {epic_id, s} ->
      MapSet.member?(building, s.id) or MapSet.member?(building, epic_id)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reject(fn {epic_id, _} -> above_building?(epic_id) end)
    |> Map.new()
  end

  @doc "Why an epic's rework is stalled, in words, for `stalled/1`'s subcards."
  def why(subcards) do
    names = Enum.map_join(subcards, ", ", &"##{&1.id}")
    verb = if length(subcards) == 1, do: "was", else: "were"
    "#{names} #{verb} rejected, and no job is open on the epic or its rework"
  end

  # A nested epic: a job on any card above it works it too.
  defp above_building?(epic_id) do
    card = Card |> Repo.get!(epic_id) |> Repo.preload(:board)

    case Boards.ancestry(card.board) do
      [] -> false
      above -> open_build?(Enum.map(above, & &1.card.id))
    end
  end

  defp open_build?(card_ids), do: MapSet.size(building(card_ids)) > 0

  # Those of `card_ids` with a build job open on them.
  defp building(card_ids) do
    from(j in Job,
      where: j.card_id in ^card_ids and j.status in ^Job.open_statuses(),
      where: j.kind not in ^not_builds(),
      distinct: true,
      select: j.card_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp open_wait?(card_id),
    do: Repo.exists?(from(w in Wait, where: w.card_id == ^card_id and is_nil(w.closed_at)))

  defp open_wait_cards,
    do: from(w in Wait, where: is_nil(w.closed_at), select: w.card_id)
end
