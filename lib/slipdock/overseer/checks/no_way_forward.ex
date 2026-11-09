defmodule Slipdock.Overseer.Checks.NoWayForward do
  @moduledoc """
  No way forward (#2068): an epic in a doing list whose open subcards are
  every one blocked (flagged `blocked`, or waiting on an unfinished
  dependency), so no pass can take any of them. Clears when one is free,
  the epic leaves the doing list, or it is done.
  """
  @behaviour Slipdock.Overseer.Check

  import Ecto.Query

  require Slipdock.Flow.DoingList, as: DoingList

  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Overseer.Check
  alias Slipdock.Repo

  @impl true
  def key, do: "no_way_forward"

  @impl true
  def label, do: "No way forward"

  @impl true
  def find(ctx) do
    ctx
    |> Check.live_cards()
    |> join(:inner, [c], col in Column,
      on: col.id == c.column_id and DoingList.doing?(col.category, col.name)
    )
    |> join(:inner, [c], sb in Board, on: sb.parent_card_id == c.id)
    |> select([c, _col, sb], {%{id: c.id, title: c.title}, sb.id})
    |> Repo.all()
    |> Enum.flat_map(fn {epic, sub_board_id} ->
      subcards =
        from(c in Card,
          where: c.board_id == ^sub_board_id,
          where: is_nil(c.archived_at) and not c.completed and is_nil(c.stand_in_for_id)
        )
        |> Repo.all()
        |> Repo.preload(blocked_by: Boards.dependency_query())

      if subcards != [] and Enum.all?(subcards, &blocked?/1) do
        [
          %{
            subject: "card:#{epic.id}:blocked",
            card_id: epic.id,
            title:
              "##{epic.id} has no way forward: all #{length(subcards)} open subcards blocked",
            why:
              "#{Check.ref(epic)} is in progress, and every open subcard is blocked: " <>
                Check.refs(subcards) <> ".",
            todo:
              "Unblock one (answer what it waits for, or finish what it depends on), or " <>
                "take the epic out of progress until one can move."
          }
        ]
      else
        []
      end
    end)
  end

  defp blocked?(card), do: Enum.member?(card.flags, "blocked") or Card.blocked?(card)
end
