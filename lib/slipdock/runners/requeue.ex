defmodule Slipdock.Runners.Requeue do
  @moduledoc """
  Sends a card to the runners again once the question its job parked on is
  answered (#1115, KTD7).

  A wait asked from a runner job (`job_id`) that is answered queues one
  fresh job for the same rule, straight through `Slipdock.Runners.queue/2`
  rather than the rule's feed: the cool-down and "top of the list" don't
  apply to a card somebody just answered. Its prompt is the rule's runner
  action rendered again, with the question, the answer, who answered and
  the card's handoff put on top.

  What the answer does is recorded on the wait (`requeue_state`, with a note
  in `requeue_note`):

    * `queued` — a fresh job is queued (`requeue_job_id`), or the rule's job
      for the card was still queued and had its prompt rewritten in place.
    * `pending` — the rule still has a job open (a list_top rule keeps one at
      most, for this card or another): the answer goes once it closes, ahead
      of the next card (`drain/1`, from the rule's feed or the job ending).
    * `skipped` — the rule is off or deleted, the card is closed or has
      moved to another board tree: nothing is sent, and the card says why.
    * `failed` — the queue refused (full, or too many this minute): the card
      says so.

  A wait not asked from a job just closes (`none`).
  """

  import Ecto.Query

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.{Rule, Spec}
  alias Slipdock.Boards.{Card, Wait}
  alias Slipdock.Runners.{Job, Recovery}

  @doc """
  Runs `fun` — closing `wait` and what follows — with the asking job's rule
  held off in this process, so the waiting flag coming off can't feed the
  rule the card with its plain prompt before the answer is sent.
  """
  def quietly(%Wait{job_id: job_id}, fun) when is_integer(job_id) do
    case rule_of(Repo.get(Job, job_id)) do
      %Rule{} = rule -> Recovery.quietly(rule, fun)
      nil -> fun.()
    end
  end

  def quietly(_wait, fun), do: fun.()

  @doc """
  Acts on an answered `wait`: queues, rewrites, holds or explains, as the
  module doc says. Answers the wait's new `requeue_state` as an atom.
  """
  def after_answer(%Wait{job_id: nil}), do: :none

  def after_answer(%Wait{} = wait) do
    job = Repo.get(Job, wait.job_id)
    card = Repo.get(Card, wait.card_id)
    rule = rule_of(job)

    cond do
      is_nil(card) ->
        :skipped

      is_nil(job) or is_nil(rule) ->
        skip(wait, card, "the rule that sent the job that asked it has been deleted")

      not rule.enabled ->
        skip(wait, card, "rule “#{rule_name(rule)}” is off")

      card.completed or not is_nil(card.archived_at) ->
        skip(wait, card, "the card is closed")

      Boards.root_of_board(card.board_id) != job.root_board_id ->
        skip(
          wait,
          card,
          "the card has moved to another board tree, out of rule “#{rule_name(rule)}”'s reach"
        )

      true ->
        open = open_job(rule, card)
        other = open || (Spec.feed?(rule.spec) && any_open_job(rule))

        cond do
          match?(%Job{status: "queued"}, open) -> rewrite(wait, rule, card, open)
          other -> pend(wait, card, other)
          true -> queue(wait, rule, card)
        end
    end
  end

  @doc """
  Sends the answers that were held while `rule` had a job open (`pending`),
  oldest answer first, for as long as the rule takes them: one at most for
  a list_top rule. Answers the first job it queued, or nil.
  """
  def drain(%Rule{} = rule) do
    from(w in Wait,
      join: j in Job,
      on: j.id == w.job_id,
      where: j.rule_id == ^rule.id and w.requeue_state == "pending",
      order_by: [asc: w.closed_at, asc: w.id]
    )
    |> Repo.all()
    |> Enum.reduce(nil, fn wait, first ->
      case after_answer(wait) do
        :queued -> first || Repo.get(Job, Repo.get!(Wait, wait.id).requeue_job_id || 0)
        _ -> first
      end
    end)
  end

  def drain(_), do: nil

  ## Deciding -----------------------------------------------------------------

  defp rule_of(%Job{rule_id: id}) when is_integer(id), do: Repo.get(Rule, id)
  defp rule_of(_), do: nil

  defp rule_name(%Rule{name: name, id: id}) when name in [nil, ""], do: "##{id}"
  defp rule_name(%Rule{name: name}), do: name

  defp open_job(rule, card) do
    Repo.one(
      from(j in Job,
        where:
          j.rule_id == ^rule.id and j.card_id == ^card.id and j.status in ^Job.open_statuses(),
        limit: 1
      )
    )
  end

  defp any_open_job(rule) do
    Repo.one(
      from(j in Job,
        where: j.rule_id == ^rule.id and j.status in ^Job.open_statuses(),
        order_by: [asc: j.id],
        limit: 1
      )
    )
  end

  ## Acting -------------------------------------------------------------------

  defp queue(wait, rule, card) do
    with {:ok, attrs} <- Slipdock.Automations.Runner.runner_job(rule, card),
         attrs = Map.put(attrs, :prompt, prompt(wait, card, attrs.prompt)),
         {:ok, %Job{} = job} <- Runners.queue(card, attrs) do
      record(wait, "queued", "job ##{job.id}", job.id)

      Boards.log_activity(
        card.board_id,
        card.id,
        "runner",
        "sent ##{card.id} to the #{job.pool} runners again with the answer: job ##{job.id}"
      )

      :queued
    else
      # Two answers' effects racing: the other one queued it.
      {:ok, :already_open, %Job{status: "queued"} = job} -> rewrite(wait, rule, card, job)
      {:ok, :already_open, job} -> pend(wait, card, job)
      {:error, reason} -> fail(wait, card, reason)
    end
  end

  # The rule's job for the card hasn't been handed out yet: it goes with the
  # answer in it, rather than a second job after it.
  defp rewrite(wait, rule, card, job) do
    with {:ok, attrs} <- Slipdock.Automations.Runner.runner_job(rule, card) do
      prompt = prompt(wait, card, attrs.prompt)

      {count, _} =
        Repo.update_all(from(j in Job, where: j.id == ^job.id and j.status == "queued"),
          set: [prompt: prompt, updated_at: DateTime.utc_now(:second)]
        )

      if count == 1 do
        record(wait, "queued", "job ##{job.id} (still queued) now carries the answer", job.id)
        :queued
      else
        # Handed out in between: it runs without the answer, which goes after it.
        pend(wait, card, Repo.get(Job, job.id))
      end
    else
      {:error, reason} -> skip(wait, card, reason)
    end
  end

  defp pend(%Wait{requeue_state: "pending"}, _card, _job), do: :pending

  defp pend(wait, card, job) do
    where = if job.card_id == card.id, do: "on this card", else: "on ##{job.card_id}"
    record(wait, "pending", "after job ##{job.id} (#{job.status} #{where})", nil)

    Boards.add_comment(
      card,
      "The answer goes to the runners once job ##{job.id} (#{job.status} #{where}) has closed."
    )

    :pending
  end

  defp skip(wait, card, why) do
    record(wait, "skipped", why, nil)
    Boards.add_comment(card, "Answered, but #{why}; nothing was sent to the runners.")
    :skipped
  end

  defp fail(wait, card, reason) do
    record(wait, "failed", reason, nil)

    Boards.add_comment(
      card,
      "Answered, but the card couldn't be sent to the runners again: #{reason}. " <>
        "Send it again by hand once that clears."
    )

    :failed
  end

  defp record(wait, state, note, job_id) do
    Repo.update_all(from(w in Wait, where: w.id == ^wait.id),
      set: [requeue_state: state, requeue_note: note, requeue_job_id: job_id]
    )
  end

  ## The prompt ---------------------------------------------------------------

  @doc false
  # The question, the answer, who answered and the handoff, on top of the
  # rule's own prompt — the handoff cut first and then the answer, each
  # with a pointer to the card, to stay under the runners' prompt limit.
  def prompt(%Wait{} = wait, %Card{} = card, body) do
    wait = Repo.preload(wait, [:closed_by], force: true)
    max = Runners.limits().max_prompt

    by =
      if match?(%User{}, wait.closed_by), do: User.display_name(wait.closed_by), else: "someone"

    answer =
      [Wait.choice_text(wait, wait.choice), wait.answer]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" — ")

    handoff =
      case Boards.current_handoff(card.id) do
        nil -> nil
        h -> Enum.join(Enum.reject([h.next_step, h.body], &(&1 in [nil, ""])), "\n")
      end

    build = fn answer, handoff ->
      [
        "Question on card ##{card.id}: #{wait.needs}",
        "Answer: #{answer}",
        "Answered by: #{by}",
        if(handoff, do: "Handoff: #{handoff}"),
        "",
        "The card waited on this question; carry on with the answer.",
        "",
        body
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end

    full = build.(answer, handoff)

    if byte_size(full) <= max do
      full
    else
      cut = " … (cut short: the whole text is on card ##{card.id})"
      spare = max - byte_size(build.(answer, "")) - byte_size(cut)

      if handoff && spare > 0 do
        build.(answer, head(handoff, spare) <> cut)
      else
        spare = max - byte_size(build.("", nil)) - byte_size(cut)
        build.(head(answer, max(spare, 0)) <> cut, nil) |> head(max)
      end
    end
  end

  # The first `max` bytes of `text`, ending on a whole character.
  defp head(text, max) when byte_size(text) <= max, do: text

  defp head(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, n} ->
      if n + byte_size(g) > max,
        do: {:halt, {acc, n}},
        else: {:cont, {[g | acc], n + byte_size(g)}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
