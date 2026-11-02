defmodule Slipdock.Verified do
  @moduledoc """
  Verified work (#1620): optional, per-board checks on what an agent says it
  finished. Every switch is off by default, and with them all off nothing
  here changes anything.

    * **The bar** (`Board.bar_required`, #1631): what done means for a card,
      written before work starts. An agent can't move a card into a doing
      list without one, and the bar locks the first time the card enters a
      doing list with one written. After that an agent can't change it; a
      person still can.
    * **Evidence** (`Board.evidence_required`, #1632): an agent completing a
      card says what it checked (`evidence`) and, if there is one, the commit
      it checked at (`evidence_commit`), in the same write or beforehand. The
      evidence is posted as a comment when the card completes, and cleared
      when it is reopened, so the next completion carries its own.
    * **Verification** (`Board.verify_work`, #1633): an agent completing a
      card submits it instead. It stays open, `verify_state: "pending"`,
      flagged `review`, until a different actor decides (`decide/5`):
      accepting completes it and moves it to the done list; rejecting needs
      a reason, which is kept, commented and left as the handoff's next
      step. A person completing a pending card accepts it.
    * **Verify jobs** (`Board.verify_pool`, #1634): with a pool named, a
      card going pending is queued for that runner pool as a `verify` job,
      its prompt saying what to check and how to decide. A decision cancels
      any other verify job still open on the card.

  The checks apply to agents (`Slipdock.Actor` kind `"agent"`), not to the
  in-app assistant, which acts on a person's say in the web app, nor to
  people or automations: a person is who the checks report to.
  """

  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Repo

  @doc "Whether the checks apply to a change made by `actor`."
  def gated?(%{kind: "agent", via: via}) when via != "assistant", do: true
  def gated?(_actor), do: false

  @doc "Whether `board` has any of the switches on, and which."
  def switches(%Board{} = board) do
    [bar: board.bar_required, evidence: board.evidence_required, verify: board.verify_work]
    |> Enum.filter(fn {_, on} -> on == true end)
    |> Keyword.keys()
  end

  ## The bar ------------------------------------------------------------------

  @doc """
  `{:ok, attrs, changes}` — `attrs` as they are to be cast, and `changes` to
  put on the card besides (the verification fields, which are never cast) —
  or `{:error, field, message}` when `actor` may not make the change they
  describe to `card`: an agent changing a locked bar, or completing a card
  with no evidence on a board that asks for it.

  On a board that verifies work, an agent's completion becomes a
  submission, and a person's completion of a pending card an acceptance.
  """
  def check_update(%Card{} = card, attrs, actor) do
    with :ok <- check_bar_edit(card, attrs, actor),
         :ok <- check_evidence(card, attrs, actor) do
      {attrs, changes} = card |> clear_evidence(attrs) |> verification(card, actor)
      {:ok, attrs, changes}
    end
  end

  defp check_bar_edit(%Card{bar_locked_at: nil}, _attrs, _actor), do: :ok

  defp check_bar_edit(%Card{} = card, attrs, actor) do
    new = fetch(attrs, :bar)

    cond do
      new == :none or not gated?(actor) ->
        :ok

      trim(new) == trim(card.bar) ->
        :ok

      not board(card).bar_required ->
        :ok

      true ->
        {:error, :bar,
         "is locked: it was set before work started and only a person can change it now"}
    end
  end

  @doc """
  `:ok`, or `{:error, message}` when `actor` may not move `card` into `to`:
  an agent starting work on a card with no bar on a board that asks for one,
  or completing one by a move with no evidence on a board that asks for it.
  """
  def check_move(%Card{} = card, %Column{} = to, actor) do
    cond do
      doing?(to) and blank?(card.bar) and gated?(actor) and board(card).bar_required ->
        {:error,
         "this board asks for each card's bar before work starts: write what done means " <>
           "for card ##{card.id} (its `bar`), then move it"}

      message = check_done_move(card, to, actor) ->
        {:error, message}

      Column.done?(to) and not card.completed and gated?(actor) and board(card).verify_work ->
        {:error,
         "this board verifies work: submit card ##{card.id} by completing it (complete_card, " <>
           "`slipdock done`), and a different agent or a person accepts it into the done list"}

      true ->
        :ok
    end
  end

  @doc """
  After `card` has moved into `to`: the bar locks when work starts, if it is
  written and the board asks for one.
  """
  def moved(%Card{bar_locked_at: nil} = card, %Column{} = to) do
    if doing?(to) and not blank?(card.bar) and board(card).bar_required do
      card
      |> Ecto.Changeset.change(bar_locked_at: DateTime.utc_now(:second))
      |> Repo.update()
    else
      {:ok, card}
    end
  end

  def moved(%Card{} = card, _to), do: {:ok, card}

  ## Evidence -----------------------------------------------------------------

  @evidence_message "is required: this board asks an agent completing a card for what it " <>
                      "checked (evidence, and the commit it checked at if there is one)"

  defp check_evidence(%Card{} = card, attrs, actor) do
    if completes?(card, attrs) and gated?(actor) and
         blank?(given(attrs, :evidence, card.evidence)) and board(card).evidence_required,
       do: {:error, :evidence, @evidence_message},
       else: :ok
  end

  # Reopened on a board that asks for evidence: what it carried was for the
  # completion that is being undone (and was kept as a comment then).
  defp clear_evidence(%Card{completed: true} = card, attrs) do
    if fetch(attrs, :completed) in [false, "false"] and
         not (blank?(card.evidence) and blank?(card.evidence_commit)) and
         board(card).evidence_required,
       do: attrs |> stringify() |> Map.merge(%{"evidence" => nil, "evidence_commit" => nil}),
       else: attrs
  end

  defp clear_evidence(_card, attrs), do: attrs

  @doc """
  The message an agent gets moving a card into a done list with no evidence
  on a board that asks for it, or nil when it may.
  """
  def check_done_move(%Card{completed: false} = card, %Column{} = to, actor) do
    if Column.done?(to) and gated?(actor) and blank?(card.evidence) and
         board(card).evidence_required,
       do:
         "this board asks for evidence when an agent completes a card: complete card ##{card.id} " <>
           "with what you checked (`evidence`, and `evidence_commit`) rather than moving it"
  end

  def check_done_move(_card, _to, _actor), do: nil

  @doc """
  After `before` has been saved as `updated`: a card completed (or submitted
  for verification) with evidence on a board that asks for it gets the
  evidence as a comment, by `user` — once: not again when it is accepted.
  """
  def saved(%Card{} = before, %Card{} = updated, user) do
    finished? =
      (not before.completed and updated.completed and before.verify_state != "pending") or
        (before.verify_state != "pending" and updated.verify_state == "pending")

    if before.verify_state != "pending" and updated.verify_state == "pending",
      do: queue_verify_job(updated, user)

    # Accepted by a person completing it: no job need check it now.
    if before.verify_state == "pending" and updated.verify_state == "accepted",
      do: cancel_verify_jobs(updated, nil)

    if finished? and not blank?(updated.evidence) and board(updated).evidence_required do
      commit =
        if updated.evidence_commit, do: "\n\nCommit: `#{updated.evidence_commit}`", else: ""

      Slipdock.Boards.add_comment(updated, "**Evidence.**\n\n#{updated.evidence}#{commit}",
        by: user
      )
    end

    :ok
  end

  defp completes?(%Card{completed: false}, attrs), do: fetch(attrs, :completed) in [true, "true"]
  defp completes?(_card, _attrs), do: false

  # What `attrs` set `key` to, else what the card already has.
  defp given(attrs, key, current) do
    case fetch(attrs, key) do
      :none -> current
      value -> value
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  ## Verification -------------------------------------------------------------

  # What a completion means on a board that verifies work.
  defp verification(attrs, %Card{} = card, actor) do
    cond do
      not completes?(card, attrs) ->
        {attrs, []}

      gated?(actor) and board(card).verify_work ->
        # Submitted: open, pending, flagged for review.
        attrs =
          attrs
          |> stringify()
          |> Map.delete("completed")
          |> Map.put("flags", Enum.uniq(given(attrs, :flags, card.flags) ++ ["review"]))

        {attrs,
         verify_state: "pending",
         verify_submitter: actor_map(actor),
         verify_by: nil,
         verify_note: nil,
         verify_commit: nil,
         verify_at: now()}

      card.verify_state == "pending" and not gated?(actor) ->
        # A person (or a rule) completing a pending card accepts it.
        {attrs |> stringify() |> Map.put("flags", given(attrs, :flags, card.flags) -- ["review"]),
         verify_state: "accepted", verify_by: actor_map(actor), verify_at: now()}

      true ->
        {attrs, []}
    end
  end

  @doc """
  Decides a pending card: `decision` is `"accept"` or `"reject"`, `params`
  carry `"reason"` (required to reject) and `"commit"` (the commit the
  verifier checked at; it must be the evidence's, when both are given).
  `actor` decides, and must not be who submitted it; `user` is who it is
  recorded as.

  Accepting completes the card and moves it to the board's done list.
  Rejecting leaves it where it is, with the reason as a comment and as the
  handoff's next step, and its evidence cleared for the next attempt.

  `{:ok, card}`, or `{:error, status, message}` in the API's shapes.
  """
  def decide(%Card{} = card, decision, params, actor, user) do
    reason = params |> Map.get("reason") |> trim()
    commit = params |> Map.get("commit") |> trim()

    cond do
      decision not in ~w(accept reject) ->
        {:error, :unprocessable_entity, "decision must be accept or reject"}

      card.verify_state != "pending" ->
        {:error, :conflict, "card ##{card.id} isn't waiting for verification"}

      same_actor?(card.verify_submitter, actor) ->
        {:error, :forbidden,
         "you submitted card ##{card.id}: a different agent, or a person, verifies it"}

      decision == "reject" and reason == "" ->
        {:error, :unprocessable_entity, "a rejection needs its reason"}

      commit != "" and card.evidence_commit not in [nil, ""] and
          not commit_matches?(commit, card.evidence_commit) ->
        {:error, :unprocessable_entity,
         "the evidence is for commit #{card.evidence_commit}: verify the work at that commit"}

      true ->
        with {:ok, _} = decided <-
               apply_decision(card, decision, %{reason: reason, commit: commit}, actor, user) do
          cancel_verify_jobs(card, actor)
          decided
        end
    end
  end

  defp apply_decision(card, "accept", %{reason: note, commit: commit}, actor, user) do
    changes = [
      verify_state: "accepted",
      verify_by: actor_map(actor),
      verify_note: blank_to_nil(note),
      verify_commit: blank_to_nil(commit),
      verify_at: now()
    ]

    with {:ok, card} <-
           Slipdock.Boards.update_card(
             card,
             %{"completed" => true, "flags" => card.flags -- ["review"]},
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      comment(card, "**Accepted** by #{who(actor, user)}.", note, user)
      done = card |> board() |> Repo.preload(:columns) |> Map.get(:columns) |> done_list()

      if done && done.id != card.column_id,
        do: Slipdock.Boards.move_card(card.id, done.id, nil, actor: actor)

      {:ok, Repo.get!(Card, card.id)}
    end
    |> api_error()
  end

  defp apply_decision(card, "reject", %{reason: reason, commit: commit}, actor, user) do
    changes = [
      verify_state: "rejected",
      verify_by: actor_map(actor),
      verify_note: reason,
      verify_commit: blank_to_nil(commit),
      verify_at: now()
    ]

    with {:ok, card} <-
           Slipdock.Boards.update_card(
             card,
             %{"flags" => card.flags -- ["review"], "evidence" => nil, "evidence_commit" => nil},
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      comment(card, "**Rejected** by #{who(actor, user)}.", reason, user)

      Slipdock.Boards.leave_handoff(card, user, %{
        next_step: String.slice("Rejected: " <> one_line(reason), 0, 280),
        body: reason,
        via: handoff_via(actor)
      })

      {:ok, Repo.get!(Card, card.id)}
    end
    |> api_error()
  end

  ## Verify jobs ---------------------------------------------------------------

  @verify_kind "verify"

  @doc "The job kind a pending card is queued as (#1634)."
  def verify_kind, do: @verify_kind

  defp queue_verify_job(%Card{} = card, user) do
    board = board(card)

    if board.verify_work and board.verify_pool do
      case Slipdock.Runners.queue(card, %{
             pool: board.verify_pool,
             kind: @verify_kind,
             prompt: verify_prompt(card, board)
           }) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Slipdock.Boards.add_comment(
            card,
            "**Verify job not queued** for pool `#{board.verify_pool}`: #{reason}. " <>
              "It waits for someone to verify it by hand.",
            by: user
          )
      end
    end
  end

  @doc """
  What a verify job's agent is told (#1634): the card, its bar and evidence,
  and how to decide. Rendered when the job is queued.
  """
  def verify_prompt(%Card{} = card, %Board{} = board) do
    url = "#{Slipdock.Automations.Runner.base_url()}/boards/#{board.id}/cards/#{card.id}"
    commit = card.evidence_commit
    at = if commit, do: " --evidence-commit #{commit}", else: ""

    """
    Verify card ##{card.id} “#{card.title}” on #{board.name} before it counts as done: #{url}

    Another agent did the work and submitted it. You are the second agent: check the work, don't redo it, and don't change the code or the card beyond your decision.

    The bar (what done means):
    #{if blank?(card.bar), do: "(none written: check it against the card's description)", else: card.bar}

    The evidence it gave:
    #{if blank?(card.evidence), do: "(none)", else: card.evidence}
    Commit: #{commit || "(none given)"}

    1. Read the card and its comments: `slipdock card #{card.id}`.
    2. #{if commit, do: "Check out #{commit} in the project's repository", else: "Find the work in the project's repository"} and check each part of the bar against it: run the tests it names, read the change.
    3. Decide once:
       - `slipdock verify #{card.id} accept#{at} --reason "what you checked"`
       - `slipdock verify #{card.id} reject#{at} --reason "what falls short of the bar, specifically"`
    A rejection goes back to whoever takes the card next, so say exactly what to fix.
    """
  end

  # Whoever decides first decides: the other verify jobs on the card stop.
  defp cancel_verify_jobs(%Card{id: card_id}, actor) do
    import Ecto.Query
    mine = actor_map(actor)["job_id"]

    from(j in Slipdock.Runners.Job,
      where:
        j.card_id == ^card_id and j.kind == @verify_kind and
          j.status in ^Slipdock.Runners.Job.open_statuses()
    )
    |> Repo.all()
    |> Enum.reject(&(&1.id == mine))
    |> Enum.each(&Slipdock.Runners.cancel_job/1)
  end

  defp api_error({:error, %Ecto.Changeset{} = cs}), do: {:error, cs}
  defp api_error(other), do: other

  defp comment(card, line, note, user) do
    body = if note in [nil, ""], do: line, else: "#{line}\n\n#{note}"
    Slipdock.Boards.add_comment(card, body, by: user)
  end

  defp done_list(columns) do
    columns |> Enum.sort_by(& &1.position) |> Enum.find(&Column.done?/1)
  end

  @doc """
  Whether two actors (`Slipdock.Actor` maps, as stored or as built) are the
  same one: the same kind, person, token label and runner job. Two runner
  jobs, two tokens, or a person and an agent are different.
  """
  def same_actor?(nil, _actor), do: false

  def same_actor?(a, b) do
    a = actor_map(a)
    b = actor_map(b)
    Map.take(a, ~w(kind user_id agent job_id)) == Map.take(b, ~w(kind user_id agent job_id))
  end

  defp actor_map(nil), do: nil

  defp actor_map(actor) do
    Map.new(~w(kind via user_id agent job_id), fn key ->
      {key, Map.get(actor, key, Map.get(actor, String.to_existing_atom(key)))}
    end)
  end

  defp who(actor, user) do
    a = actor_map(actor)

    cond do
      a["kind"] == "agent" and a["agent"] -> "agent “#{a["agent"]}”"
      a["kind"] == "agent" -> "an agent"
      user -> Slipdock.Accounts.User.display_name(user)
      true -> "somebody"
    end
  end

  defp handoff_via(actor) do
    case actor_map(actor)["via"] do
      "web" -> "ui"
      via when via in ~w(api mcp cli runner) -> via
      _ -> "api"
    end
  end

  defp commit_matches?(a, b) do
    a = String.downcase(a)
    b = String.downcase(b)
    String.starts_with?(a, b) or String.starts_with?(b, a)
  end

  defp one_line(text), do: text |> String.split(~r/\R/, parts: 2) |> hd()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp now, do: DateTime.utc_now(:second)

  ## Helpers ------------------------------------------------------------------

  defp doing?(%Column{category: "doing"}), do: true
  defp doing?(_), do: false

  defp board(%Card{board: %Board{} = board}), do: board
  defp board(%Card{board_id: id}), do: Repo.get!(Board, id)

  # A key from string- or atom-keyed attrs; :none when it isn't there.
  defp fetch(attrs, key) do
    cond do
      Map.has_key?(attrs, to_string(key)) -> attrs[to_string(key)]
      Map.has_key?(attrs, key) -> attrs[key]
      true -> :none
    end
  end

  defp trim(nil), do: ""
  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(other), do: to_string(other)

  defp blank?(text), do: trim(text) == ""
end
