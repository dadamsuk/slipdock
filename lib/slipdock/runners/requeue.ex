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
    * `queued`, too, when a list_top rule's open job is another card's and
      still queued (#1750): nobody has taken it, so it is withdrawn
      (`Slipdock.Runners.withdraw_job/2`) and the answer takes its slot. Its
      card keeps its place, is told so, and is the next one the feed sends.
      Waiting for it instead could be forever: whatever holds it (a lane,
      a pause, the WIP limit) may be the answered card itself.
    * `pending` — the rule's open job has been handed out (claimed or
      running), for this card or another, or is another answer's: the answer
      goes once it closes, ahead of the next card (`drain/1`, from the
      rule's feed or the job ending).
    * `skipped` — the rule is off or deleted, the card is closed or has
      moved to another board tree: nothing is sent, and the card says why.
    * `failed` — the queue refused (full, or too many this minute): the card
      says so.

  A wait not asked from a job just closes (`none`).

  A wait on a subcard asked from the epic's job (#1755) sends the job's own
  card, the epic, again: the rule, the open job and the closed or moved
  checks are the epic's, and the prompt names the subcard the question was
  on. What the answer did is said on the subcard, where it was answered.
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
    asked = Repo.get(Card, wait.card_id)
    # The card the job was working on: the wait's own, or the epic above it.
    card =
      if job && asked && job.card_id != asked.id, do: Repo.get(Card, job.card_id), else: asked

    rule = rule_of(job)

    cond do
      is_nil(asked) or is_nil(card) ->
        :skipped

      is_nil(job) or is_nil(rule) ->
        skip(wait, card, "the rule that sent the job that asked it has been deleted")

      not rule.enabled ->
        skip(wait, card, "rule “#{rule_name(rule)}” is off")

      card.completed or not is_nil(card.archived_at) ->
        skip(wait, card, "#{the_card(wait, card)} is closed")

      Boards.root_of_board(card.board_id) != job.root_board_id ->
        skip(
          wait,
          card,
          "#{the_card(wait, card)} has moved to another board tree, " <>
            "out of rule “#{rule_name(rule)}”'s reach"
        )

      true ->
        open = open_job(rule, card)
        other = open || (Spec.feed?(rule.spec) && any_open_job(rule))

        cond do
          match?(%Job{status: "queued"}, open) ->
            rewrite(wait, rule, card, open)

          match?(%Job{status: "queued"}, other) and not answer?(other) ->
            give_way(wait, rule, card, other)

          other ->
            pend(wait, card, other)

          true ->
            queue(wait, rule, card)
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

  # The job carries an answer already: a second answer waits for it.
  defp answer?(%Job{id: id}) do
    Repo.exists?(from(w in Wait, where: w.requeue_job_id == ^id and w.requeue_state == "queued"))
  end

  ## Acting -------------------------------------------------------------------

  # Another card's job from the list_top rule is still queued: the answer
  # takes its slot, under the feed's lock so the feed can't send a card in
  # between. Handed out meanwhile, it holds the answer after all.
  defp give_way(wait, rule, card, job) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [7_400, rule.id])

        case Runners.withdraw_job(job, "gave way to the answer on ##{card.id}") do
          {:ok, job} ->
            result = queue(wait, rule, card, " (job ##{job.id} on ##{job.card_id} gave way)")
            tell_withdrawn(job, card)
            result

          :error ->
            after_answer(wait)
        end
      end)

    result
  end

  defp tell_withdrawn(job, card) do
    with %Card{} = withdrawn <- Repo.get(Card, job.card_id) do
      Boards.add_comment(
        withdrawn,
        "Job ##{job.id} gave way to the answer on ##{card.id}, which went to the runners " <>
          "first. This card keeps its place in the list and goes next."
      )
    end
  end

  defp queue(wait, rule, card, note \\ "") do
    with {:ok, attrs} <- Slipdock.Automations.Runner.runner_job(rule, card),
         attrs = Map.put(attrs, :prompt, prompt(wait, card, attrs.prompt)),
         {:ok, %Job{} = job} <- Runners.queue(card, attrs) do
      record(wait, "queued", "job ##{job.id}" <> note, job.id)

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
    where = if job.card_id == wait.card_id, do: "on this card", else: "on ##{job.card_id}"
    record(wait, "pending", "after job ##{job.id} (#{job.status} #{where})", nil)

    why =
      if job.status == "queued",
        do: "it carries another answer, which goes first",
        else: "it is already with a runner"

    Boards.add_comment(
      told(wait, card),
      "The answer goes to the runners once job ##{job.id} (#{job.status} #{where}) " <>
        "has closed: #{why}."
    )

    :pending
  end

  defp skip(wait, card, why) do
    record(wait, "skipped", why, nil)

    Boards.add_comment(
      told(wait, card),
      "#{done(wait)}, but #{why}; nothing was sent to the runners."
    )

    :skipped
  end

  defp fail(wait, card, reason) do
    record(wait, "failed", reason, nil)

    Boards.add_comment(
      told(wait, card),
      "#{done(wait)}, but #{the_card(wait, card)} couldn't be sent to the runners again: #{reason}. " <>
        "Send it again by hand once that clears."
    )

    :failed
  end

  # Said on the card the question was on: the subcard, for an epic's job.
  defp told(%Wait{card_id: id}, %Card{id: id} = card), do: card
  defp told(wait, card), do: Repo.get(Card, wait.card_id) || card

  defp the_card(%Wait{card_id: id}, %Card{id: id}), do: "the card"
  defp the_card(_wait, card), do: "card ##{card.id}, whose job asked it,"

  defp done(%Wait{close_reason: "skipped"}), do: "Skipped"
  defp done(_wait), do: "Answered"

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
    wait = Repo.preload(wait, [:closed_by, :card], force: true)
    max = Runners.limits().max_prompt

    by =
      if match?(%User{}, wait.closed_by), do: User.display_name(wait.closed_by), else: "someone"

    answer =
      if wait.close_reason == "skipped",
        do: "(skipped: #{by} chose not to answer; use your own judgement)",
        else: Wait.answered_text(wait)

    handoff =
      case Boards.current_handoff(card.id) do
        nil -> nil
        h -> Enum.join(Enum.reject([h.next_step, h.body], &(&1 in [nil, ""])), "\n")
      end

    build = fn answer, handoff ->
      [
        question_lines(wait, card, answer),
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
      cut = &" … (cut short: the whole text is on card ##{&1})"
      spare = max - byte_size(build.(answer, "")) - byte_size(cut.(card.id))

      if handoff && spare > 0 do
        build.(answer, head(handoff, spare) <> cut.(card.id))
      else
        cut = cut.(wait.card_id)
        spare = max - byte_size(build.("", nil)) - byte_size(cut)
        build.(head(answer, max(spare, 0)) <> cut, nil) |> head(max)
      end
    end
  end

  # A series' answer already numbers its questions (#1220). A subcard's
  # question is named with its title (#1755).
  defp question_lines(wait, card, answer) do
    on = on_card(wait, card)

    if Wait.series?(wait) and wait.close_reason != "skipped",
      do: "Questions on #{on}: #{wait.needs}\nAnswers:\n#{answer}",
      else: "Question on #{on}: #{wait.needs}\nAnswer: #{answer}"
  end

  defp on_card(%Wait{card_id: id}, %Card{id: id}), do: "card ##{id}"

  defp on_card(%Wait{card: %Card{} = sub}, card),
    do: "subcard ##{sub.id} “#{sub.title}” (beneath ##{card.id})"

  defp on_card(wait, _card), do: "card ##{wait.card_id}"

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
