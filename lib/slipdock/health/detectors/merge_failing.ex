defmodule Slipdock.Health.Detectors.MergeFailing do
  @moduledoc """
  A card whose merge has failed twice (`failures`, default 2) and whose
  latest merge job failed too. The card is already back as rejected each
  time; the flag tells a person it is looping. A merge job that finds the
  pull request already merged records a merge, not a failure (#2637): it
  isn't a rejection and doesn't count towards `failures`. No fix: flagged,
  with the merges' reasons.
  """
  @behaviour Slipdock.Health.Detector

  import Ecto.Query

  alias Slipdock.Boards.Card
  alias Slipdock.Health.Context
  alias Slipdock.Health.Detectors.Finishing
  alias Slipdock.{Repo, Verified}

  @impl true
  def key, do: "merge_failing"
  @impl true
  def label, do: "Merge keeps failing"
  @impl true
  def defaults, do: %{"failures" => 2}

  @impl true
  def detect(%Context{} = ctx, %{"failures" => failures}) do
    ids =
      Repo.all(
        from(c in Card,
          where: c.board_id in ^ctx.board_ids and c.completed == false and is_nil(c.archived_at),
          select: c.id
        )
      )

    for {card_id, [latest | _] = jobs} <- Finishing.jobs(ids, Verified.merge_kind()),
        latest.status == "failed",
        failed = Enum.filter(jobs, &(&1.status == "failed")),
        length(failed) >= failures do
      reasons =
        failed
        |> Enum.take(failures)
        |> Enum.map_join("; ", &"##{&1.id}: #{&1.error || "no reason given"}")

      %{
        subject: %{"card" => card_id},
        card_id: card_id,
        # A new failure is a new state.
        state: latest.id,
        summary:
          "The merge of ##{card_id} has failed #{length(failed)} times, most recently job ##{latest.id}: " <>
            "it is looping between accepted and rejected (#{reasons})."
      }
    end
    |> Enum.sort_by(& &1.card_id)
  end
end
