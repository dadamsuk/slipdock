defmodule Slipdock.Verified.Jobs do
  @moduledoc """
  The verify and audit jobs of a card: queueing one for the board's verify
  pool, the runner that built the card and the one that decided it, and
  cancelling the verify jobs a decision makes needless.
  """

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Verified.{Actors, Audits, Prompts, Util}

  # The runner whose job made a decision, if one did (#1666): it is about
  # to finish that job, so it can take the merge next (#1754).
  @doc false
  def decider_runner(actor) do
    import Ecto.Query

    case Actors.actor_map(actor) do
      %{"job_id" => id} when is_integer(id) ->
        Repo.one(from(j in Slipdock.Runners.Job, where: j.id == ^id, select: j.runner_id))

      _ ->
        nil
    end
  end

  # A card an agent accepted (not a person), on a board with audits and a
  # verify pool, in the sample: queued for the verify pool as an audit,
  # never to the runner that built it or the one that verified it.
  @doc false
  def maybe_audit(%Card{} = card) do
    board = Util.board(card)
    n = Audits.audit_every(card)

    if board.verify_work and Util.present?(board.verify_pool) and agent_decided?(card) and
         Audits.audit_sampled?(card.id, n) do
      builder = builder_runner_id(card)
      verifier = decider_runner(card.verify_by)

      Slipdock.Runners.queue(card, %{
        pool: board.verify_pool,
        kind: verify_kind(),
        audit: true,
        prompt: Prompts.audit_prompt(card, board),
        exclude_runner_id: builder,
        exclude_runner_ids: Enum.uniq(Enum.reject([builder, verifier], &is_nil/1))
      })
    end

    :ok
  end

  defp agent_decided?(%Card{verify_by: %{"kind" => "agent", "via" => via}})
       when via != "assistant",
       do: true

  defp agent_decided?(_card), do: false

  ## Verify jobs ---------------------------------------------------------------

  @verify_kind "verify"

  @doc "The job kind a pending card is queued as (#1634)."
  def verify_kind, do: @verify_kind

  @doc """
  Queues a verify job again for a card still pending verification that has
  none open (the health monitor's `verify_missing`): to its board's verify
  pool, never to the runner that built it. `{:ok, job}` or `{:error, reason}`.
  """
  def requeue_verify(%Card{verify_state: "pending"} = card) do
    board = Util.board(card)

    if board.verify_work and board.verify_pool do
      Slipdock.Runners.queue(card, %{
        pool: board.verify_pool,
        kind: @verify_kind,
        prompt: Prompts.verify_prompt(card, board),
        exclude_runner_id: builder_runner_id(card)
      })
    else
      {:error, "the board has no verify pool"}
    end
  end

  def requeue_verify(%Card{}), do: {:error, "the card isn't pending verification"}

  @doc false
  def queue_verify_job(%Card{} = card, user) do
    board = Util.board(card)

    if board.verify_work and board.verify_pool do
      builder = builder_runner_id(card)

      case Slipdock.Runners.queue(card, %{
             pool: board.verify_pool,
             kind: @verify_kind,
             prompt: Prompts.verify_prompt(card, board),
             exclude_runner_id: builder
           }) do
        {:ok, job} ->
          say_if_no_one_can_take(card, job, board, builder, user)

        {:error, reason} ->
          Slipdock.Boards.Comments.add_comment(
            card,
            "**Verify job not queued** for pool `#{board.verify_pool}`: #{reason}. " <>
              "It waits for someone to verify it by hand.",
            by: user
          )
      end
    end
  end

  # The runner that built the card (#1625): the one running the job the
  # submission came from, else the last one to take a job on the card.
  @doc false
  def builder_runner_id(%Card{} = card) do
    import Ecto.Query
    alias Slipdock.Runners.Job

    from_job =
      case (card.verify_submitter || %{})["job_id"] do
        id when is_integer(id) ->
          Repo.one(from(j in Job, where: j.id == ^id, select: j.runner_id))

        _ ->
          nil
      end

    from_job ||
      Repo.one(
        from(j in Job,
          where: j.card_id == ^card.id and j.kind != @verify_kind and not is_nil(j.runner_id),
          order_by: [desc: j.id],
          limit: 1,
          select: j.runner_id
        )
      )
  end

  # A verify job no runner in its pool may take waits; the card says why.
  defp say_if_no_one_can_take(card, job, board, builder, user) do
    import Ecto.Query

    runners =
      Repo.all(
        from(r in Slipdock.Runners.Runner,
          where: r.board_id == ^Board.root_id(board) and r.pool == ^board.verify_pool,
          select: r.id
        )
      )

    why =
      cond do
        runners == [] ->
          "no runner is in pool `#{board.verify_pool}` yet"

        builder && runners == [builder] ->
          "the only runner in pool `#{board.verify_pool}` built this card, and a card's " <>
            "builder doesn't verify it"

        true ->
          nil
      end

    if why do
      Slipdock.Boards.Comments.add_comment(
        card,
        "**Verify job ##{job.id} waits:** #{why}. Add a runner to the pool, or verify it by hand.",
        by: user
      )
    end

    :ok
  end

  # Whoever decides first decides: the other verify jobs on the card stop
  # (an audit, queued by an acceptance, isn't one of them: #1780).
  @doc false
  def cancel_verify_jobs(%Card{id: card_id}, actor) do
    import Ecto.Query
    mine = Actors.actor_map(actor)["job_id"]

    from(j in Slipdock.Runners.Job,
      where:
        j.card_id == ^card_id and j.kind == @verify_kind and not j.audit and
          j.status in ^Slipdock.Runners.Job.open_statuses()
    )
    |> Repo.all()
    |> Enum.reject(&(&1.id == mine))
    |> Enum.each(&Slipdock.Runners.cancel_job/1)
  end
end
