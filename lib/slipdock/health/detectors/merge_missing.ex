defmodule Slipdock.Health.Detectors.MergeMissing do
  @moduledoc """
  An accepted card on a board that ships by pull request, shown as
  *merging*, with no open merge job for `minutes` (default 10). The fix
  queues the merge again (`Slipdock.Verified.queue_merge/3`, to the pool
  `merge_pool/2` picks), up to `max_attempts` (2) for the same acceptance;
  then it is flagged.
  """
  @behaviour Slipdock.Health.Detector

  alias Slipdock.Boards.Card
  alias Slipdock.Health.Context
  alias Slipdock.Health.Detectors.Finishing
  alias Slipdock.{Repo, Verified}
  alias Slipdock.Runners.Job

  @impl true
  def key, do: "merge_missing"
  @impl true
  def label, do: "Merge job missing"
  @impl true
  def defaults, do: %{"minutes" => 10}

  @impl true
  def detect(%Context{} = ctx, %{"minutes" => minutes}) do
    cards = Finishing.cards(ctx.board_ids, "merging")
    jobs = Finishing.jobs(Enum.map(cards, & &1.id), Verified.merge_kind())

    for card <- cards,
        mine = Map.get(jobs, card.id, []),
        not Enum.any?(mine, &Job.open?/1),
        since = Finishing.quiet_since(card, mine),
        Context.minutes_since(ctx, since) >= minutes do
      last = List.first(mine)

      %{
        subject: %{"card" => card.id},
        card_id: card.id,
        state: {card.id, card.verify_at && DateTime.to_iso8601(card.verify_at)},
        summary:
          "##{card.id} was accepted #{Context.minutes_since(ctx, since)} minutes ago and shows as " <>
            "merging, but no merge job is open " <>
            if(last,
              do: "(the last, ##{last.id}, ended #{Finishing.ended(last)}).",
              else: "(none was ever queued)."
            ),
        data: %{"card" => card.id}
      }
    end
  end

  @impl true
  def resolve(%{data: %{"card" => id}}, _attempt) do
    with %Card{verify_state: "merging"} = card <- Repo.get(Card, id),
         {:ok, %Job{} = job} <- Verified.queue_merge(card) do
      {:fixed, "queued merge job ##{job.id} for pool #{job.pool}"}
    else
      {:ok, :already_open, job} -> {:fixed, "merge job ##{job.id} is open"}
      # No runner on the tree takes merge jobs: the card says what to do.
      :none -> :no_fix
      _ -> :no_fix
    end
  end
end
