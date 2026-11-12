defmodule Slipdock.Health.Detectors.VerifyMissing do
  @moduledoc """
  A card pending verification, on a board with a verify pool, with no open
  verify job for `minutes` (default 10): one was cancelled, failed or never
  queued. The fix queues it again (`Slipdock.Verified.requeue_verify/1`: the
  board's verify pool, never the card's builder), up to `max_attempts` (2)
  for the same submission; then it is flagged. A refusal that would come
  again (`Slipdock.Runners.lasting_refusal?/1`) is flagged at once, with
  the reason, rather than retried (#2705).

  An open verify job counts whatever its age: a card submitted again while
  still pending gets a new `verify_at` but keeps the job already queued
  (`Slipdock.Verified.submitted/3` queues no second), so it is not missing.
  With none open, only the jobs of the card's current submission (queued at
  or after its `verify_at`) count as its last and its quiet time (#2760): a
  job from an earlier round, which gave its verdict and sent the card back,
  is not this submission's "last" job. On
  2026-11-10 three resubmissions whose verify prompt was over the runners'
  cap were flagged as though the earlier round's job (ended `done`, with a
  rejection) had ended without a verdict.
  """
  @behaviour Slipdock.Health.Detector

  alias Slipdock.Boards.Card
  alias Slipdock.Health.Context
  alias Slipdock.Health.Detectors.Finishing
  alias Slipdock.{Repo, Runners, Verified}
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
        all = Map.get(jobs, card.id, []),
        not Enum.any?(all, &Job.open?/1),
        mine = this_submission(card, all),
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
              else: "(none was queued for this submission)."
            ),
        data: %{"card" => card.id}
      }
    end
  end

  # A job queued before the card's latest hand-on belongs to an earlier round.
  defp this_submission(%Card{verify_at: nil}, jobs), do: jobs

  defp this_submission(%Card{verify_at: at}, jobs),
    do: Enum.filter(jobs, &(DateTime.compare(&1.inserted_at, at) != :lt))

  @impl true
  def resolve(%{data: %{"card" => id}}, _attempt) do
    with %Card{} = card <- Repo.get(Card, id),
         {:ok, %Job{} = job} <- Verified.requeue_verify(card) do
      {:fixed, "queued verify job ##{job.id} for pool #{job.pool}"}
    else
      {:ok, :already_open, job} -> {:fixed, "verify job ##{job.id} is open"}
      {:error, reason} -> not_queued(reason)
      _ -> :no_fix
    end
  end

  defp not_queued(reason) do
    if Runners.lasting_refusal?(reason),
      do:
        {:no_fix,
         "Couldn't queue a verify job: #{reason}. Queueing it again would be refused the same way."},
      else: {:tried, "couldn't queue a verify job: #{reason}"}
  end
end
