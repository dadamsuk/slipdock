defmodule Slipdock.Health.Detectors.VerifyMissing do
  @moduledoc """
  A card pending verification, on a board with a verify pool, with no open
  verify job for `minutes` (default 10): one was cancelled, failed or never
  queued. The fix queues it again (`Slipdock.Verified.requeue_verify/1`: the
  board's verify pool, never the card's builder), up to `max_attempts` (2)
  for the same submission; then it is flagged.
  """
  @behaviour Slipdock.Health.Detector

  alias Slipdock.Boards.Card
  alias Slipdock.Health.Context
  alias Slipdock.Health.Detectors.Finishing
  alias Slipdock.{Repo, Verified}
  alias Slipdock.Runners.Job

  @impl true
  def key, do: "verify_missing"
  @impl true
  def label, do: "Verify job missing"
  @impl true
  def defaults, do: %{"minutes" => 10}

  @impl true
  def detect(%Context{} = ctx, %{"minutes" => minutes}) do
    cards =
      Enum.filter(
        Finishing.cards(ctx.board_ids, "pending"),
        &(&1.board.verify_work and is_binary(&1.board.verify_pool))
      )

    jobs = Finishing.jobs(Enum.map(cards, & &1.id), Verified.verify_kind())

    for card <- cards,
        mine = Map.get(jobs, card.id, []),
        not Enum.any?(mine, &Job.open?/1),
        since = Finishing.quiet_since(card, mine),
        Context.minutes_since(ctx, since) >= minutes do
      last = List.first(mine)

      %{
        subject: %{"card" => card.id},
        card_id: card.id,
        # The submission, so re-queueing it stays bounded however often it fails.
        state: {card.id, card.verify_at && DateTime.to_iso8601(card.verify_at)},
        summary:
          "##{card.id} has waited #{Context.minutes_since(ctx, since)} minutes for verification " <>
            "with no verify job open in pool #{card.board.verify_pool} " <>
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
    with %Card{} = card <- Repo.get(Card, id),
         {:ok, %Job{} = job} <- Verified.requeue_verify(card) do
      {:fixed, "queued verify job ##{job.id} for pool #{job.pool}"}
    else
      {:ok, :already_open, job} -> {:fixed, "verify job ##{job.id} is open"}
      {:error, reason} -> {:tried, "couldn't queue a verify job: #{reason}"}
      _ -> :no_fix
    end
  end
end
