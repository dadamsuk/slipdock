defmodule Slipdock.Runners.Recovery do
  @moduledoc """
  Puts back a card its job left in progress.

  A job that ends — done, failed, cancelled or timed out — with its card
  still open in an in-progress list would hold a `list_top` rule that waits
  while anything is in progress (`wait_while_doing`) for good: every later
  job waits on that card. A rule whose `runner` action has
  `requeue_stuck: N` has the server deal with it when the job ends: the card
  gets a comment and goes back to the top of the rule's list, up to N times;
  after that it is flagged blocked and left where it is, with a comment, so
  the runner waits until somebody moves or closes it.

  Only the job's own card is touched, and only by a job that was handed out
  at least once (a job cancelled while it sat in the queue never had the
  card). The count is per rule and card: the jobs from that rule on that
  card that put it back since the card was last completed. What happened is
  recorded on the job (`recovery`: `"requeued"` or `"gave_up"`).
  """

  import Ecto.Query

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Automations.{Rule, Spec}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Runners.Job

  @max 10

  @doc "The most times a rule may put a card back."
  def max_requeues, do: @max

  @doc "How many times `rule` puts a card back (its runner action's `requeue_stuck`), 0 when it doesn't."
  def requeue_limit(%Rule{spec: spec}) do
    if Spec.feed?(spec) do
      spec
      |> Spec.actions()
      |> Enum.find_value(0, &(&1["type"] == "runner" && &1["requeue_stuck"]))
      |> case do
        n when is_integer(n) and n > 0 -> n
        _ -> 0
      end
    else
      0
    end
  end

  @doc """
  Deals with `job`'s card if the job has ended with it still in progress.
  Answers `{:requeued, n}`, `:gave_up` or `:ok` when there was nothing to do.
  """
  def recover(%Job{id: id}) do
    with %Job{rule_id: rule_id, attempts: attempts, recovery: nil} = job when attempts > 0 <-
           Repo.get(Job, id),
         true <- job.status in Job.finished_statuses(),
         %Rule{} = rule <- rule_id && Repo.get(Rule, rule_id),
         limit when limit > 0 <- requeue_limit(rule),
         %Card{} = card <- stuck_card(job) do
      # The changes below come back as events that would feed the rule before
      # the card is where it belongs; whoever called this feeds it after.
      quietly(rule, fn ->
        if requeued(job, card) < limit,
          do: requeue(job, rule, card, limit),
          else: give_up(job, card, limit)
      end)
    else
      _ -> :ok
    end
  end

  defp quietly(rule, fun) do
    previous = Process.get({:feeding, rule.id})
    Process.put({:feeding, rule.id}, true)

    try do
      fun.()
    after
      if previous, do: :ok, else: Process.delete({:feeding, rule.id})
    end
  end

  # The job's card, if it is still open in an in-progress list.
  defp stuck_card(job) do
    Repo.one(
      from(c in Card,
        join: col in assoc(c, :column),
        where:
          c.id == ^job.card_id and col.category == "doing" and is_nil(c.archived_at) and
            c.completed == false
      )
    )
  end

  defp requeued(job, card) do
    from(j in Job,
      where:
        j.rule_id == ^job.rule_id and j.card_id == ^card.id and j.recovery == "requeued" and
          j.id != ^job.id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Starts `card`'s count again: called when it is completed. The jobs that put
  it back keep a record of it (`"requeued_before_done"`) but no longer count.
  """
  def forget(%Card{id: card_id}) do
    Repo.update_all(from(j in Job, where: j.card_id == ^card_id and j.recovery == "requeued"),
      set: [recovery: "requeued_before_done"]
    )

    :ok
  end

  defp requeue(job, rule, card, limit) do
    with {:ok, board} <- fetch_board(rule.board_id),
         {:ok, column} <- Boards.find_column(board, to_string(rule.spec["trigger"]["column"])),
         true <- mark(job, "requeued") do
      n = requeued(job, card) + 1
      # A rule that only sends cards nobody has taken would pass over the
      # card its own job took.
      unassign = rule.spec["trigger"]["unassigned"] == true and assigned?(card)

      Boards.add_comment(
        card,
        "Runner job ##{job.id} ended (#{why(job)}) with this card still in progress. " <>
          "Moved back to the top of #{column.name}#{if unassign, do: ", unassigned,"} for " <>
          "retry #{n} of #{limit}: the next job picks it up from the comments and the " <>
          "working tree."
      )

      if unassign, do: Boards.update_card(Repo.get!(Card, card.id), %{"assignee_ids" => []})
      Boards.move_card_to_index(Repo.get!(Card, card.id), column, :top)

      Boards.log_activity(
        card.board_id,
        card.id,
        "runner",
        "put ##{card.id} back on #{column.name} after job ##{job.id} (retry #{n} of #{limit})"
      )

      {:requeued, n}
    else
      _ -> :ok
    end
  end

  defp give_up(job, card, limit) do
    if mark(job, "gave_up") do
      card = Repo.get!(Card, card.id)
      Boards.update_card(card, %{"flags" => Enum.uniq(card.flags ++ ["blocked"])})

      Boards.add_comment(
        card,
        "Runner job ##{job.id} ended (#{why(job)}) with this card still in progress, after " <>
          "#{limit} #{if limit == 1, do: "retry", else: "retries"}. Flagged blocked and left " <>
          "in progress: a runner that waits while anything is in progress waits until " <>
          "somebody moves or closes it."
      )

      Boards.log_activity(
        card.board_id,
        card.id,
        "runner",
        "gave up on ##{card.id} after job ##{job.id}: flagged blocked"
      )

      :gave_up
    else
      :ok
    end
  end

  defp assigned?(card) do
    card = Repo.preload(card, :assignees)
    not is_nil(card.assignee_id) or card.assignees != []
  end

  defp fetch_board(id) do
    case Repo.get(Board, id) do
      nil -> :error
      board -> {:ok, board}
    end
  end

  # Once per job, whoever gets there first.
  defp mark(job, recovery) do
    {count, _} =
      Repo.update_all(from(j in Job, where: j.id == ^job.id and is_nil(j.recovery)),
        set: [recovery: recovery]
      )

    count == 1
  end

  defp why(%Job{status: "timeout"}), do: "timed out"
  defp why(%Job{status: "cancelled"}), do: "cancelled"
  defp why(%Job{status: status, error: error}) when is_binary(error), do: "#{status}: #{error}"
  defp why(%Job{status: status, exit_code: nil}), do: status
  defp why(%Job{status: status, exit_code: code}), do: "#{status}, exit #{code}"
end
