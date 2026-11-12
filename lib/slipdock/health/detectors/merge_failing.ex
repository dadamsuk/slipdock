defmodule Slipdock.Health.Detectors.MergeFailing do
  @moduledoc """
  A card whose merge has failed twice (`failures`, default 2) and whose
  latest merge job failed too. A merge that fails sends the card back as
  rejected each time; the flag tells a person it is looping. A merge job
  that finds the pull request already merged isn't a rejection (#2637): at
  the accepted commit, whoever merged it, it records a merge, and at another
  head the card stays merging, for a person to mark merged by hand. That
  job ends failed but isn't counted here as a failing merge:
  `merge_missing` flags the card once, for a person, rather than queuing the
  merge again (`Slipdock.Verified.already_merged?/1`, #2759). A card still
  merging because no runner could merge it here is flagged as still
  merging, not as looping. No fix: flagged, with the merges' reasons.
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

    merging =
      Repo.all(from(c in Card, where: c.id in ^ids and c.verify_state == "merging", select: c.id))
      |> MapSet.new()

    for {card_id, jobs} <- Finishing.jobs(ids, Verified.merge_kind()),
        # A merge that found the pull request already merged isn't a failing
        # merge (#2759): no merge was tried, and none would succeed.
        [latest | _] = counted <- [Enum.reject(jobs, &Verified.already_merged?/1)],
        latest.status == "failed",
        failed = Enum.filter(counted, &(&1.status == "failed")),
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
            looping(MapSet.member?(merging, card_id)) <> " (#{reasons})."
      }
    end
    |> Enum.sort_by(& &1.card_id)
  end

  # A card still merging wasn't sent back: no runner could merge it here
  # (#2662). (One whose merge found the pull request already merged isn't
  # counted at all, #2759.)
  defp looping(true), do: "it is still merging, not sent back as rejected"
  defp looping(false), do: "it is looping between accepted and rejected"
end
