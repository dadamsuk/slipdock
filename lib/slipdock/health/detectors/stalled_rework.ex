defmodule Slipdock.Health.Detectors.StalledRework do
  @moduledoc """
  An epic in a doing list, put there by an agent, whose subcard was
  rejected `minutes` ago or more (default 10) and waits for its rework with
  no build job open on it, the epic or any card above the epic, and no open
  wait (#3184,
  `Slipdock.Verified.EpicRework.stalled/1`). No feed takes from a
  sub-board's list, so nothing would pick the rework up.

  A rejection sends such an epic again by itself
  (`Slipdock.Verified.EpicRework.send_again/2`); this is the backstop for
  one it couldn't (its job still open at the rejection and gone since, or
  the epic moved back by hand). The fix is the same: the epic goes back to
  the top of its feed's list, once; stalled again, it is flagged.
  """
  @behaviour Slipdock.Health.Detector

  import Ecto.Query

  alias Slipdock.Repo
  alias Slipdock.Boards.Card
  alias Slipdock.Health.Context
  alias Slipdock.Verified.EpicRework

  @impl true
  def key, do: "stalled_rework"
  @impl true
  def label, do: "Epic's rework, nobody on it"
  @impl true
  def defaults, do: %{"minutes" => 10, "max_attempts" => 1}

  @impl true
  def detect(%Context{} = ctx, %{"minutes" => minutes}) do
    doing = for {id, column} <- ctx.columns, Slipdock.Flow.doing_list?(column), do: id

    epics =
      from(c in Card,
        where:
          c.board_id in ^ctx.board_ids and c.column_id in ^doing and c.completed == false and
            is_nil(c.archived_at) and
            coalesce(c.verify_state, "") not in ["pending", "merging", "held"],
        select: {c.id, c}
      )
      |> Repo.all()
      |> Map.new()

    stalled = epics |> Map.keys() |> EpicRework.stalled()

    for {epic_id, subcards} <- Enum.sort(stalled),
        due = Enum.filter(subcards, &(&1.rejected_at && old?(ctx, &1.rejected_at, minutes))),
        due != [] do
      epic = epics[epic_id]
      first = hd(due)

      %{
        subject: %{"card" => epic_id, "cards" => Enum.map(due, & &1.id)},
        card_id: epic_id,
        state: Enum.map(due, &{&1.id, &1.rejected_at}),
        summary:
          "##{epic_id} “#{epic.title}” is in #{ctx.columns[epic.column_id].name}: " <>
            EpicRework.why(due) <>
            " (for #{Context.minutes_since(ctx, first.rejected_at)} minutes).",
        data: %{"card" => epic_id, "subcard" => first.id}
      }
    end
  end

  defp old?(ctx, at, minutes), do: Context.minutes_since(ctx, at) >= minutes

  @impl true
  def resolve(%{data: %{"subcard" => id}}, _attempt) do
    case Repo.get(Card, id) do
      %Card{} = subcard ->
        case EpicRework.send_again(subcard) do
          {:sent, _epic, column} -> {:fixed, "sent the epic again, to the top of #{column.name}"}
          _ -> :no_fix
        end

      nil ->
        :no_fix
    end
  end

  def resolve(_incident, _attempt), do: :no_fix
end
