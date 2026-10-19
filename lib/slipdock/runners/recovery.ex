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

  A job that ended **parked** — its agent asked a person something (#1115,
  KTD6) — has its card put back on top of its `list_top` rule's list,
  flagged waiting, whatever the rule's `requeue_stuck`: the next card, which
  `next_card` reaches past the waiting one, can go while the question is
  open. That spends no retry (`recovery: "parked"`), and the answer, not the
  feed, sends the card again (see `Slipdock.Runners.Requeue`). An
  event-triggered rule feeds no list, so its parked card stays where it is.
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
         %Rule{} = rule <- rule_id && Repo.get(Rule, rule_id) do
      # The changes below come back as events that would feed the rule before
      # the card is where it belongs; whoever called this feeds it after.
      cond do
        job.status == "parked" ->
          if Spec.feed?(rule.spec), do: quietly(rule, fn -> park(job, rule) end), else: :ok

        (limit = requeue_limit(rule)) > 0 ->
          case stuck_card(job) do
            %Card{} = card ->
              quietly(rule, fn ->
                if requeued(job, card) < limit,
                  do: requeue(job, rule, card, limit),
                  else: give_up(job, card, limit)
              end)

            nil ->
              :ok
          end

        true ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  @doc false
  # Runs `fun` with `rule`'s feed held off in this process: the events its
  # changes dispatch would otherwise feed the rule before they are done.
  def quietly(rule, fun) do
    previous = Process.get({:feeding, rule.id})
    Process.put({:feeding, rule.id}, true)

    try do
      fun.()
    after
      if previous, do: :ok, else: Process.delete({:feeding, rule.id})
    end
  end

  # A parked job's card goes back on top of its rule's list, flagged
  # waiting, if it is still open on the rule's board.
  defp park(job, rule) do
    with %Card{archived_at: nil, completed: false} = card <- Repo.get(Card, job.card_id),
         true <- card.board_id == rule.board_id,
         {:ok, board} <- fetch_board(rule.board_id),
         {:ok, column} <- Boards.find_column(board, to_string(rule.spec["trigger"]["column"])),
         true <- mark(job, "parked") do
      wait = Boards.current_wait(card)
      unassign = rule.spec["trigger"]["unassigned"] == true and assigned?(card)

      if wait && "waiting" not in card.flags,
        do: Boards.update_card(card, %{"flags" => card.flags ++ ["waiting"]}, wait_hook: false)

      if unassign, do: Boards.update_card(Repo.get!(Card, card.id), %{"assignee_ids" => []})

      Boards.move_card_to_index(Repo.get!(Card, card.id), column, :top,
        actor: Slipdock.Actor.automation()
      )

      question = if wait, do: ": “#{wait.needs}”", else: ""

      Boards.add_comment(
        Repo.get!(Card, card.id),
        "Runner job ##{job.id} parked on a question#{question}. Moved back to the top of " <>
          "#{column.name}#{if unassign, do: ", unassigned,"} and left waiting, so the next " <>
          "card can go; answering the question sends this one to the runners again."
      )

      Boards.log_activity(
        card.board_id,
        card.id,
        "runner",
        "put ##{card.id} back on #{column.name} after job ##{job.id} parked"
      )

      :parked
    else
      _ -> :ok
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

      Boards.move_card_to_index(Repo.get!(Card, card.id), column, :top,
        actor: Slipdock.Actor.automation()
      )

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
