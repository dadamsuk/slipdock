defmodule Slipdock.Boards.Waits do
  @moduledoc """
  Waits: a question on a card for a person, opened, moved, answered,
  withdrawn or resolved to its default, with the comments and hooks each of
  those fires.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Wait
  alias Slipdock.Repo

  @doc false
  def wait_preloads, do: [:on_user, :opened_by, :closed_by]

  ## Waits

  @doc """
  Opens a wait on `card`: it needs `needs` from a person (#1114). `actor` is
  who asks (`Slipdock.Actor`). `attrs` takes `needs` (required), `choices`
  (a short list of answers to pick from), `on_user_id` (nil waits on anyone)
  and `job_id`, the runner job asking, which must be claimed or running on
  this card or on a card above it (an epic's job asking about a subcard,
  #1755).

  The card is flagged `waiting` through `update_card/3`, so rules on the
  flag fire, and the wait remembers whether it set the flag. A wait on a
  named person other than the asker emails them (`Slipdock.Boards.WaitEmail`),
  and with inbound mail on they can answer by replying. A card has one
  open wait at most: a second is refused, naming the first.

  Who may open one is the caller's to check: anyone who may change the card.
  """
  def open_wait(%Card{} = card, actor, attrs) do
    card = Repo.get!(Card, card.id)
    user = Boards.ActivityLog.actor_user(actor)
    {attrs, told} = route_wait(card, attrs)

    with :ok <- no_open_wait(card),
         :ok <- check_wait_job(card, attrs[:job_id] || attrs["job_id"]),
         {:ok, wait} <-
           %Wait{
             card_id: card.id,
             opened_by_id: user && user.id,
             kind: actor[:kind],
             via: actor[:via],
             agent: actor[:agent],
             set_flag: not Enum.member?(card.flags, "waiting"),
             # The server's own waits say what they are for (#1779); never
             # from a request.
             purpose: attrs[:purpose]
           }
           |> Wait.changeset(attrs)
           |> Repo.insert()
           |> refuse_second_open(card) do
      wait = Repo.preload(wait, wait_preloads())

      if wait.set_flag,
        do:
          {:ok, _} =
            Boards.Cards.update_card(card, %{"flags" => card.flags ++ ["waiting"]},
              by: user,
              actor: actor,
              wait_hook: false
            )

      Boards.ActivityLog.log(
        Repo,
        card.board_id,
        card.id,
        "wait",
        "waits on #{Wait.on_name(wait)}: #{wait.needs}"
      )

      {:ok, _} = Boards.Comments.add_comment(card, opened_text(wait), by: user)
      Slipdock.EpicLog.wait_opened(card, wait)
      Slipdock.StepStatus.wait_opened(card, wait)
      Slipdock.Boards.WaitEmail.opened(wait, card)
      Slipdock.Boards.WaitEmail.told(wait, card, told)
      Boards.PubSub.broadcast(card.board_id)
      {:ok, wait}
    end
  end

  # Who the wait goes to (#1949, `Slipdock.WaitRoutes`): a named person
  # stands; otherwise the route for its kind (`other` when it has none), and
  # with no route, a wait given a kind is on the tree's owner while one given
  # none waits on anyone, as before. Returns the attrs, with `question` and
  # `on_user_id` filled in, and the people the route says to tell.
  defp route_wait(card, attrs) do
    given = blank_nil(attrs[:question] || attrs["question"])
    question = given || Slipdock.WaitRoutes.default_kind()
    attrs = put_wait_attr(attrs, :question, question)
    named? = not is_nil(attrs[:on_user_id] || attrs["on_user_id"])
    kind = String.downcase(question)

    if named? or not Enum.member?(Slipdock.WaitRoutes.kinds(), kind),
      do: {attrs, []},
      else: routed(card, attrs, kind, given)
  end

  defp routed(card, attrs, kind, given) do
    case Slipdock.WaitRoutes.place(card, kind) do
      {%{id: id}, told} -> {on(attrs, id), told}
      {nil, _} when is_nil(given) -> {attrs, []}
      {nil, _} -> {on(attrs, Board.root_owner_id(Repo.get!(Board, card.board_id))), []}
    end
  end

  defp on(attrs, id), do: put_wait_attr(attrs, :on_user_id, id)

  # Callers give attrs with string keys (requests) or atom keys (the
  # server's own waits); a changeset takes one kind, so keep theirs.
  defp put_wait_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_atom/1),
      do: attrs |> Map.delete(to_string(key)) |> Map.put(key, value),
      else: attrs |> Map.delete(key) |> Map.put(to_string(key), value)
  end

  defp blank_nil(v) when v in [nil, ""], do: nil
  defp blank_nil(v), do: v

  @doc """
  Puts an open wait on somebody else (#1949): `to_user_id`, with `why` said
  in a comment on the card. Used when a routed user leaves the board.
  """
  def move_wait(%Wait{} = wait, to_user_id, why) do
    card = Repo.get!(Card, wait.card_id)

    {:ok, moved} =
      wait |> Ecto.Changeset.change(on_user_id: to_user_id) |> Repo.update()

    moved = Repo.preload(moved, wait_preloads(), force: true)

    {:ok, _} =
      Boards.Comments.add_comment(card, "**Wait moved** to #{Wait.on_name(moved)}: #{why}.",
        by: nil
      )

    Slipdock.Boards.WaitEmail.opened(moved, card)
    Boards.PubSub.broadcast(card.board_id)
    {:ok, moved}
  end

  defp no_open_wait(card) do
    case current_wait(card) do
      nil -> :ok
      wait -> {:error, already_open(card, wait)}
    end
  end

  # Two opens racing past the check: the index has the last word.
  defp refuse_second_open({:error, %Ecto.Changeset{errors: errors}} = error, card) do
    if Keyword.has_key?(errors, :card_id),
      do: {:error, already_open(card, current_wait(card))},
      else: error
  end

  defp refuse_second_open(result, _card), do: result

  defp already_open(card, nil), do: "card ##{card.id} already has an open wait"

  defp already_open(card, wait) do
    "card ##{card.id} already has an open wait: “#{wait.needs}” " <>
      "(on #{Wait.on_name(wait)}, opened by #{Boards.ActivityLog.person_name(wait.opened_by)} " <>
      "at #{stamp(wait.inserted_at)}). Answer or withdraw it first."
  end

  # A job may be named only while it is working on this card or on one above
  # it (#1755: an epic's pass asks about a subcard from the epic's job), so
  # no caller can park somebody else's job, or one that has finished.
  defp check_wait_job(_card, nil), do: :ok
  defp check_wait_job(_card, ""), do: :ok

  defp check_wait_job(card, job_id) do
    job =
      case Integer.parse(to_string(job_id)) do
        {id, ""} -> Repo.get(Slipdock.Runners.Job, id)
        _ -> nil
      end

    cond do
      is_nil(job) ->
        {:error, "no job ##{job_id}"}

      job.card_id != card.id and
          not Enum.member?(Boards.Cards.ancestor_card_ids(card), job.card_id) ->
        {:error,
         "job ##{job.id} is working on another card: ##{card.id} isn't " <>
           "##{job.card_id} or beneath it"}

      not Enum.member?(~w(claimed running), job.status) ->
        {:error, "job ##{job.id} is #{job.status}: only a claimed or running job can wait"}

      true ->
        :ok
    end
  end

  defp opened_text(wait) do
    choices =
      wait.choices
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {text, n} -> "\n#{n}. #{text}" end)

    questions =
      if Wait.series?(wait) do
        "\n" <>
          (wait.questions
           |> Enum.with_index(1)
           |> Enum.map_join("", fn {q, n} -> "\n#{n}. #{q}" end))
      else
        ""
      end

    "Waiting on #{Wait.on_name(wait)}: #{wait.needs}" <> questions <> choices
  end

  @doc """
  Answers `card`'s open wait (or `wait` itself) for `actor`: `attrs` takes
  `answers` (one per question, in order: a list, or a map from the
  question's number counted from 1; blank for one left unanswered),
  `answer` (free text) and `choice` (the number of one of its choices,
  counted from 1), at least one of them. A wait of one question takes its
  answer as `answers` too. `skip: true` instead closes it unanswered
  (#1220) and moves the card on just the same. The answer is posted on the card
  as a comment from whoever answered, and the `waiting` flag comes off if
  the wait put it there. A wait asked from a runner job then sends the card
  to that job's rule again, with the answer (`Slipdock.Runners.Requeue`).

  An agent can't answer a wait it opened itself (KTD8): both classified as
  an agent and sharing a token or a job. A person always can, even on the
  agent's token. Of two answers racing, the second is told who answered
  first and when. Who may answer at all is the caller's to check: anyone
  who may change the card.
  """
  def answer_wait(%Card{} = card, actor, attrs) do
    case current_wait(card) do
      nil -> {:error, no_open_wait_text(card)}
      wait -> answer_wait(wait, actor, attrs)
    end
  end

  def answer_wait(%Wait{} = wait, actor, attrs) do
    wait = Repo.preload(wait, wait_preloads())

    if truthy?(wait_attr(attrs, :skip)),
      do: skip_wait(wait, actor),
      else: answer_open_wait(wait, actor, attrs)
  end

  defp answer_open_wait(wait, actor, attrs, opts \\ []) do
    answer = attrs |> wait_attr(:answer) |> blank_to_nil()

    with :ok <- not_self_answer(wait, actor),
         :ok <- Slipdock.Verified.may_close_wait(wait, actor),
         {:ok, answers} <- wait_answers(wait, wait_attr(attrs, :answers)),
         # One question: its answer is the answer.
         {answer, answers} = single_answer(wait, answer, answers),
         {:ok, choice} <- wait_choice(wait, wait_attr(attrs, :choice)),
         :ok <- some_answer(answer, choice, answers),
         :ok <- answer_length(answer),
         :ok <- Enum.reduce_while(answers, :ok, &answers_length/2) do
      # The flag coming off must not feed the asking job's rule the card with
      # its plain prompt before the answer is sent (KTD7).
      Slipdock.Runners.Requeue.quietly(wait, fn ->
        answered(wait, actor, [answer: answer, choice: choice, answers: answers], opts)
      end)
    end
  end

  defp answered(wait, actor, answer, opts) do
    with {:ok, closed} <- close_wait(wait, actor, "answered", answer) do
      card = Repo.get!(Card, wait.card_id)

      {:ok, _} =
        Boards.Comments.add_comment(card, answer_comment(closed, opts),
          by: Boards.ActivityLog.actor_user(actor)
        )

      Slipdock.EpicLog.wait_closed(card, "answered", actor)
      Slipdock.Runners.Requeue.after_answer(closed)
      Slipdock.Verified.wait_closed(closed, actor)
      {:ok, Wait |> Repo.get!(closed.id) |> Repo.preload(wait_preloads())}
    end
  end

  # Skipping (#1220): nothing is answered, but the card moves on as it
  # would on an answer — the flag off, and a runner's card sent again.
  defp skip_wait(wait, actor) do
    with :ok <- not_self_answer(wait, actor),
         :ok <- Slipdock.Verified.may_close_wait(wait, actor) do
      Slipdock.Runners.Requeue.quietly(wait, fn -> skipped(wait, actor) end)
    end
  end

  defp skipped(wait, actor) do
    with {:ok, closed} <- close_wait(wait, actor, "skipped", []) do
      card = Repo.get!(Card, wait.card_id)

      {:ok, _} =
        Boards.Comments.add_comment(
          card,
          "#{Boards.ActivityLog.actor_name(actor)} skipped the questions “#{closed.needs}”: " <>
            "carry on without the answers.",
          by: Boards.ActivityLog.actor_user(actor)
        )

      Slipdock.EpicLog.wait_closed(card, "skipped", actor)
      Slipdock.Runners.Requeue.after_answer(closed)
      Slipdock.Verified.wait_closed(closed, actor)
      {:ok, Wait |> Repo.get!(closed.id) |> Repo.preload(wait_preloads())}
    end
  end

  defp truthy?(value), do: Enum.member?([true, "true", "1", 1, "on", "yes"], value)

  # The answers, one per question in order, "" for one left blank.
  defp wait_answers(_wait, nil), do: {:ok, []}

  defp wait_answers(wait, %{} = by_number) do
    count = length(Wait.questions(wait))

    Enum.reduce_while(by_number, {:ok, List.duplicate("", count)}, fn {n, text}, {:ok, acc} ->
      case Integer.parse(to_string(n)) do
        {n, ""} when n in 1..count//1 ->
          {:cont, {:ok, List.replace_at(acc, n - 1, answer_text_of(text))}}

        _ ->
          {:halt, {:error, "answers are numbered 1 to #{count}, one per question"}}
      end
    end)
  end

  defp wait_answers(wait, answers) when is_list(answers) do
    count = length(Wait.questions(wait))

    if length(answers) > count,
      do:
        {:error,
         "#{length(answers)} answers for #{count} #{if count == 1, do: "question", else: "questions"}"},
      else:
        {:ok, Enum.map(answers, &answer_text_of/1) ++ List.duplicate("", count - length(answers))}
  end

  defp wait_answers(_wait, _),
    do: {:error, "answers is a list of strings, one per question"}

  defp answer_text_of(text) when is_binary(text), do: String.trim(text)
  defp answer_text_of(nil), do: ""
  defp answer_text_of(other), do: other |> to_string() |> String.trim()

  defp single_answer(wait, answer, answers) do
    if Wait.series?(wait) do
      {answer, answers}
    else
      case answers do
        [one] when one != "" ->
          {Enum.join(Enum.reject([one, answer], &is_nil/1), "\n\n"), []}

        _ ->
          {answer, []}
      end
    end
  end

  defp answers_length(a, :ok) when byte_size(a) > 8000,
    do: {:halt, {:error, "an answer is too long: at most 8000 characters each"}}

  defp answers_length(_a, :ok), do: {:cont, :ok}

  defp wait_attr(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

  defp no_open_wait_text(card) do
    case last_wait(card) do
      %Wait{close_reason: r} = w when r in ~w(answered skipped) -> already_closed(w)
      _ -> "card ##{card.id} has no open wait"
    end
  end

  defp not_self_answer(wait, actor) do
    if own_wait?(wait, actor),
      do: {:error, "an agent can't answer the wait it opened itself: a person has to answer it"},
      else: :ok
  end

  # An agent's own wait: both agents, sharing a job or a token and label.
  defp own_wait?(%Wait{kind: "agent"} = wait, %{kind: "agent"} = actor) do
    same_job = wait.job_id != nil and wait.job_id == actor[:job_id]
    same_token = wait.opened_by_id == actor[:user_id] and wait.agent == actor[:agent]
    same_job or same_token
  end

  defp own_wait?(_wait, _actor), do: false

  defp wait_choice(_wait, nil), do: {:ok, nil}
  defp wait_choice(_wait, ""), do: {:ok, nil}

  defp wait_choice(%Wait{choices: choices} = wait, choice) do
    n =
      case choice do
        n when is_integer(n) -> n
        text -> whole_number(text)
      end

    cond do
      choices == [] -> {:error, "the wait “#{wait.needs}” has no choices: answer in words"}
      Enum.member?(1..length(choices)//1, n) -> {:ok, n}
      true -> {:error, "choice must be a number from 1 to #{length(choices)}"}
    end
  end

  defp whole_number(text) do
    case Integer.parse(to_string(text)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp some_answer(nil, nil, answers) do
    if Enum.any?(answers, &(&1 != "")),
      do: :ok,
      else: {:error, "an answer needs text or a choice"}
  end

  defp some_answer(_, _, _), do: :ok

  defp answer_length(answer) when is_binary(answer) and byte_size(answer) > 8000,
    do: {:error, "the answer is too long: at most 8000 characters"}

  defp answer_length(_), do: :ok

  # The answer's comment: the caller's own (a proposal standing, #2096), else
  # the answer as given.
  defp answer_comment(closed, opts) do
    case opts[:comment] do
      nil -> answered_text(closed)
      text_for -> text_for.(closed)
    end
  end

  defp answered_text(wait) do
    if Wait.series?(wait),
      do: "Answered “#{wait.needs}”:\n\n#{Wait.answered_text(wait)}",
      else: "Answered “#{wait.needs}”: #{Wait.answered_text(wait)}"
  end

  @doc """
  Withdraws `card`'s open wait for `actor`: nobody needs the answer any
  more. The `waiting` flag comes off if the wait put it there. Who may is
  the caller's to check: anyone who may change the card, or who opened it.

  A moot wait clears itself (#2096): any agent that finds one may withdraw
  it, not only the one that opened it, but an agent withdrawing a wait it
  didn't open (another job, token or agent, or another person's) gives a
  `reason`, which the comment carries. The opener, a person, and a
  person's own token on the wait they opened, may give one or not. A wait a person decides (`Verified.may_close_wait/2`) stays
  theirs.
  """
  def withdraw_wait(%Card{} = card, actor, opts \\ []) do
    case current_wait(card) do
      nil ->
        {:error, "card ##{card.id} has no open wait"}

      wait ->
        reason = opts |> Keyword.get(:reason) |> blank_to_nil()

        with :ok <- withdraw_reason(wait, actor, reason),
             :ok <- reason_length(reason),
             :ok <- Slipdock.Verified.may_close_wait(wait, actor),
             {:ok, closed} <- close_wait(wait, actor, "withdrawn", opts) do
          {:ok, _} =
            Boards.Comments.add_comment(
              Repo.get!(Card, card.id),
              opts[:note] || withdrawn_text(actor, closed, reason),
              by: Boards.ActivityLog.actor_user(actor)
            )

          {:ok, closed}
        end
    end
  end

  defp withdraw_reason(wait, %{kind: "agent"} = actor, nil) do
    if own_wait?(wait, actor) or persons_own?(wait, actor),
      do: :ok,
      else:
        {:error,
         "an agent withdrawing a wait it didn't open says why: give a reason " <>
           "(what made it moot: answered elsewhere, the bar or description edited, " <>
           "the cited rule or decision in place, the card decided since)"}
  end

  defp withdraw_reason(_wait, _actor, _reason), do: :ok

  # A person may always withdraw their own wait, through a token too.
  defp persons_own?(%Wait{kind: kind, opened_by_id: id}, actor),
    do: kind != "agent" and id != nil and id == actor[:user_id]

  defp reason_length(reason) when is_binary(reason) and byte_size(reason) > 2000,
    do: {:error, "the reason is too long: at most 2000 characters"}

  defp reason_length(_), do: :ok

  defp withdrawn_text(actor, wait, nil),
    do: "#{Boards.ActivityLog.actor_name(actor)} withdrew the wait “#{wait.needs}”"

  defp withdrawn_text(actor, wait, reason),
    do: "#{Boards.ActivityLog.actor_name(actor)} withdrew the wait “#{wait.needs}”: #{reason}"

  @doc """
  An approval wait's proposal stands (#2096, `Slipdock.WaitDefaults`):
  `wait` (`Wait.approval?/1`) is answered with its `default_choice` by the
  server, the card says so (`after_text`, e.g. "4h"), and the card moves on
  as it would on a person's answer. Anything else is refused.
  """
  def default_wait(%Wait{} = wait, after_text) do
    wait = Repo.preload(wait, wait_preloads())

    if Wait.approval?(wait) and is_nil(wait.closed_at) do
      answer_open_wait(wait, Slipdock.Actor.automation(), %{choice: wait.default_choice},
        comment: fn closed ->
          "No answer after #{after_text}, so the proposal stands: " <>
            "“#{Wait.choice_text(closed, closed.choice)}” " <>
            "(the default for “#{closed.needs}”). Answer again on a new wait if it shouldn't."
        end
      )
    else
      {:error, "only an open approval wait (kind other, with choices and a default) defaults"}
    end
  end

  # Closing is one conditional update, so of two racing the second finds the
  # wait closed and is told by whom. The flag comes off afterwards if the
  # wait set it, unless the flag going is what closed it (`flag: false`).
  @doc false
  def close_wait(%Wait{} = wait, actor, reason, opts) do
    now = DateTime.utc_now(:second)
    user = Boards.ActivityLog.actor_user(actor)

    {count, _} =
      from(w in Wait, where: w.id == ^wait.id and is_nil(w.closed_at))
      |> Repo.update_all(
        set: [
          closed_at: now,
          closed_by_id: user && user.id,
          close_reason: reason,
          answer: opts[:answer],
          choice: opts[:choice],
          answers: opts[:answers] || []
        ]
      )

    closed = Wait |> Repo.get!(wait.id) |> Repo.preload(wait_preloads())

    if count == 0 do
      {:error, already_closed(closed)}
    else
      card = Repo.get!(Card, closed.card_id)

      if closed.set_flag and opts[:flag] != false and Enum.member?(card.flags, "waiting"),
        do:
          {:ok, _} =
            Boards.Cards.update_card(card, %{"flags" => List.delete(card.flags, "waiting")},
              by: user,
              actor: actor,
              wait_hook: false
            )

      Boards.ActivityLog.log(
        Repo,
        card.board_id,
        card.id,
        "wait",
        "wait #{reason}: #{closed.needs}"
      )

      Slipdock.Boards.WaitAlert.closed(closed)
      Boards.PubSub.broadcast(card.board_id)
      {:ok, closed}
    end
  end

  defp already_closed(%Wait{} = w) do
    what =
      case w.close_reason do
        "answered" -> "already answered"
        "skipped" -> "already skipped"
        "withdrawn" -> "already withdrawn"
        "card_completed" -> "already closed when the card was completed"
        "archived" -> "already closed when the card was archived"
        _ -> "already closed"
      end

    by = if w.closed_by, do: " by #{Boards.ActivityLog.person_name(w.closed_by)}", else: ""
    "the wait “#{w.needs}” was #{what}#{by} at #{stamp(w.closed_at)}"
  end

  @doc "The card's open wait, with who it is on and who opened it, or nil."
  def current_wait(%Card{id: id}), do: current_wait(id)

  def current_wait(card_id) when is_integer(card_id),
    do: Map.get(current_waits([card_id]), card_id)

  @doc "The open wait of each of `card_ids` that has one, by card id."
  def current_waits([]), do: %{}

  def current_waits(card_ids) when is_list(card_ids) do
    from(w in Wait, where: w.card_id in ^card_ids and is_nil(w.closed_at))
    |> Repo.all()
    |> Repo.preload(wait_preloads())
    |> Map.new(&{&1.card_id, &1})
  end

  @doc "The card's most recently closed wait, or nil."
  def last_wait(%Card{id: id}), do: Map.get(last_waits([id]), id)

  @doc "The most recently closed wait of each of `card_ids` that has had one."
  def last_waits([]), do: %{}

  def last_waits(card_ids) when is_list(card_ids) do
    from(w in Wait,
      where: w.card_id in ^card_ids and not is_nil(w.closed_at),
      distinct: w.card_id,
      order_by: [asc: w.card_id, desc: w.closed_at, desc: w.id]
    )
    |> Repo.all()
    |> Repo.preload(wait_preloads())
    |> Map.new(&{&1.card_id, &1})
  end

  @doc """
  Every wait the card has had, newest first, with who it was on, who
  opened and who closed it: the questions asked and answered (#1220).
  """
  def list_waits(%Card{id: id}) do
    from(w in Wait, where: w.card_id == ^id, order_by: [desc: w.inserted_at, desc: w.id])
    |> Repo.all()
    |> Repo.preload(wait_preloads())
  end

  @doc "How many waits have been opened on the card: the questions it has asked."
  def wait_count(%Card{id: id}),
    do: Repo.aggregate(from(w in Wait, where: w.card_id == ^id), :count)

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp stamp(_), do: "an unknown time"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(to_string(text)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
