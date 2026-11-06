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
      a reason, which is kept and commented (the handoff only points at it),
      the builder's own assignment comes off, and the card goes back to the
      top of the ready list with its rejection counted, next for the feed. A person completing a pending card accepts it.
    * **Shipping by pull request** (`Board.ship_via`, #1654): the builder
      opens a pull request instead of pushing the default branch, and names
      it in `evidence_pr`, which a board asking for evidence requires.
    * **Verify jobs** (`Board.verify_pool`, #1634): with a pool named, a
      card going pending is queued for that runner pool as a `verify` job,
      its prompt saying what to check and how to decide. A decision cancels
      any other verify job still open on the card.

  Two checks have no switch. An agent can't complete (or submit) a card
  whose sub-board still has open cards, by a write or a move into a done
  list; the refusal names them (`open_subcards/1`, #1758). And an agent
  can't reopen a completed card, by unticking it or moving it out of a done
  list (`reopen_message/2`, #1850). Each guards against a contradiction, an
  epic done over unfinished work or finished work undone by a script,
  rather than asking more of an agent's work, so they hold on every board.

  The checks apply to agents (`Slipdock.Actor` kind `"agent"`), not to the
  in-app assistant, which acts on a person's say in the web app, nor to
  people or automations: a person is who the checks report to.
  """

  import Ecto.Query, only: [from: 2]

  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Repo

  @doc "Whether the checks apply to a change made by `actor`."
  def gated?(%{kind: "agent", via: via}) when via != "assistant", do: true
  def gated?(_actor), do: false

  @doc """
  Whether `card` is awaiting verification on a board that ships by push
  (#1661). Its work is on the default branch already and nobody is editing
  its files, so while it is pending it releases its lane (`Slipdock.Lanes`)
  and counts as finished for the cards that depend on it
  (`Slipdock.Boards.Card.blocked?/1`, through `Boards.dependency_query/0`).
  A rejection ends both. On a board that ships by pull request the work is
  on an unmerged branch, so a pending card keeps both until the merge.

  The queries in `Slipdock.Lanes`, `Slipdock.Rollup` and
  `Boards.dependency_query/0` say the same in SQL.
  """
  def released?(card, board \\ nil)

  def released?(%Card{verify_state: "pending"} = card, board),
    do: not Board.ships_by_pr?(board || board(card))

  def released?(_card, _board), do: false

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
  describe to `card`: an agent changing a locked bar, completing a card
  whose sub-board has open cards (on any board), or completing one with no
  evidence on a board that asks for it.

  On a board that verifies work, an agent's completion becomes a
  submission, and a person's completion of a pending card an acceptance.
  """
  def check_update(%Card{} = card, attrs, actor) do
    with :ok <- check_reopen(card, attrs, actor),
         :ok <- check_bar_edit(card, attrs, actor),
         :ok <- check_subcards(card, attrs, actor),
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
  an agent taking a completed card out of a done list (on any board),
  starting work on a card with no bar on a board that asks for one,
  completing one by a move while its sub-board has open cards (on any
  board), or with no evidence on a board that asks for it.
  """
  def check_move(%Card{} = card, %Column{} = to, actor) do
    cond do
      message = reopen_move_message(card, to, actor) ->
        {:error, message}

      doing?(to) and blank?(card.bar) and gated?(actor) and board(card).bar_required ->
        {:error,
         "this board asks for each card's bar before work starts: write what done means " <>
           "for card ##{card.id} (its `bar`), then move it"}

      message = check_subcards_move(card, to, actor) ->
        {:error, message}

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

  @doc """
  The checks of a move into `column`, for a card being created there (#1815):
  `changeset` (a new card's) with a `bar` error when `actor` (an agent) may
  not start work on it, because the list is a doing list, the board asks for
  a bar and the card has none; else with the bar locked, as a move into the
  list would lock it. A changeset already invalid, or for any other list,
  comes back as it was.
  """
  def check_create(%Ecto.Changeset{valid?: true} = changeset, %Column{} = column, actor) do
    card = Ecto.Changeset.apply_changes(changeset)

    cond do
      not doing?(column) or not board(card).bar_required ->
        changeset

      blank?(card.bar) and gated?(actor) ->
        Ecto.Changeset.add_error(
          changeset,
          :bar,
          "is needed to start work: this board asks for each card's bar before work " <>
            "starts, so write what done means (its `bar`) to create a card in " <>
            "#{column.name}, or create it in another list"
        )

      blank?(card.bar) ->
        changeset

      true ->
        Ecto.Changeset.put_change(changeset, :bar_locked_at, DateTime.utc_now(:second))
    end
  end

  def check_create(%Ecto.Changeset{} = changeset, _column, _actor), do: changeset

  ## Done stays done (#1850) --------------------------------------------------

  @doc """
  The message an agent gets reopening `card`, or nil when it may. On every
  board, an agent can't untick a completed card or move it out of a done
  list into one that isn't: nothing an agent does needs it (a rejection
  comes before Done, a retry only puts back a card left in progress, and a
  recurring card is copied), and a script that does it undoes finished work.
  Reopening is a person's call.
  """
  def reopen_message(%Card{completed: true} = card, actor) do
    if gated?(actor),
      do:
        "card ##{card.id} is done, and an agent can't reopen it (untick it or move it out of " <>
          "the done list): a person reopens finished work. If it needs more, add a card for " <>
          "that and link it"
  end

  def reopen_message(_card, _actor), do: nil

  defp check_reopen(card, attrs, actor) do
    with true <- fetch(attrs, :completed) in [false, "false"],
         message when is_binary(message) <- reopen_message(card, actor) do
      {:error, :completed, "is refused: " <> message}
    else
      _ -> :ok
    end
  end

  @doc """
  The message an agent gets moving a completed `card` out of a done list
  into `to`, which isn't one, or nil when it may.
  """
  def reopen_move_message(%Card{completed: true} = card, %Column{} = to, actor) do
    if gated?(actor) and not Column.done?(to) and Column.done?(Repo.get!(Column, card.column_id)),
      do: reopen_message(card, actor)
  end

  def reopen_move_message(_card, _to, _actor), do: nil

  ## Open subcards (#1758) ----------------------------------------------------

  # How many open subcards a refusal names before it says how many more.
  @named_subcards 10

  @doc """
  The cards still open on `card`'s sub-board, as `{id, title}` in id order:
  not completed, not archived and not submitted for verification (pending,
  or accepted and merging, which is the verifier's to finish). A subcard
  that is complete counts as done whatever its own sub-board holds. An
  archived sub-board, or none, has none.
  """
  def open_subcards(%Card{id: id}) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where:
        b.parent_card_id == ^id and is_nil(b.archived_at) and c.completed == false and
          is_nil(c.archived_at) and coalesce(c.verify_state, "") not in ["pending", "merging"],
      order_by: c.id,
      select: {c.id, c.title}
    )
    |> Repo.all()
  end

  defp check_subcards(card, attrs, actor) do
    with true <- completes?(card, attrs) and gated?(actor),
         message when is_binary(message) <- subcards_message(card) do
      {:error, :completed, "is refused: " <> message}
    else
      _ -> :ok
    end
  end

  defp check_subcards_move(card, to, actor) do
    if Column.done?(to) and not card.completed and gated?(actor), do: subcards_message(card)
  end

  # Why `card` can't be completed by an agent yet, or nil when it can.
  defp subcards_message(%Card{} = card) do
    case open_subcards(card) do
      [] ->
        nil

      open ->
        {named, rest} = Enum.split(open, @named_subcards)
        names = Enum.map_join(named, ", ", fn {id, title} -> "##{id} #{title}" end)
        more = if rest == [], do: "", else: " and #{length(rest)} more"
        verb = if length(open) == 1, do: "is", else: "are"

        "card ##{card.id} has open subcards: #{names}#{more} #{verb} still open. " <>
          "Finish or archive them first, then complete it"
    end
  end

  ## Evidence -----------------------------------------------------------------

  @evidence_message "is required: this board asks an agent completing a card for what it " <>
                      "checked — none of evidence (what you checked), evidence_commit (and " <>
                      "evidence_branch), evidence_tests (the test files), evidence_suite " <>
                      "({result: passed|failed, passed, failed}) or evidence_pr (the pull " <>
                      "request's URL) was given"

  # The fields evidence is made of (#1632, #1623): any one of them is some.
  @evidence_fields ~w(evidence evidence_commit evidence_branch evidence_tests evidence_suite evidence_pr)a

  @pr_message "is required: this board ships by pull request, so an agent completing a " <>
                "card names the pull request its work is in (evidence_pr, `slipdock done " <>
                "--pr URL`); push the card's branch and open one, never the default branch"

  defp check_evidence(%Card{} = card, attrs, actor) do
    cond do
      not (completes?(card, attrs) and gated?(actor) and board(card).evidence_required) ->
        :ok

      not evidence?(card, attrs) ->
        {:error, :evidence, @evidence_message}

      Board.ships_by_pr?(board(card)) and
          not present?(given(attrs, :evidence_pr, card.evidence_pr)) ->
        {:error, :evidence_pr, @pr_message}

      true ->
        :ok
    end
  end

  @doc "Whether `card` carries any evidence (or would, with `attrs`)."
  def evidence?(card, attrs \\ %{}) do
    Enum.any?(@evidence_fields, fn key -> present?(given(attrs, key, Map.get(card, key))) end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value) or is_map(value), do: value != [] and value != %{}
  defp present?(value), do: not is_nil(value)

  defp no_evidence, do: Map.new(@evidence_fields, &{to_string(&1), nil})

  # Reopened on a board that asks for evidence: what it carried was for the
  # completion that is being undone (and was kept as a comment then).
  defp clear_evidence(%Card{completed: true} = card, attrs) do
    if fetch(attrs, :completed) in [false, "false"] and evidence?(card) and
         board(card).evidence_required,
       do: attrs |> stringify() |> Map.merge(no_evidence()),
       else: attrs
  end

  defp clear_evidence(_card, attrs), do: attrs

  @doc """
  The message an agent gets moving a card into a done list with no evidence
  on a board that asks for it, or nil when it may.
  """
  def check_done_move(%Card{completed: false} = card, %Column{} = to, actor) do
    if Column.done?(to) and gated?(actor) and not evidence?(card) and
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

    if before.verify_state != "pending" and updated.verify_state == "pending" do
      queue_verify_job(updated, user)

      # Shipped by push: it no longer holds up the cards that depend on it.
      if released?(updated), do: Slipdock.Boards.unblock_dependents(updated, by: user)
    end

    # Accepted by a person completing it: no job need check it now.
    if before.verify_state == "pending" and updated.verify_state == "accepted",
      do: cancel_verify_jobs(updated, nil)

    if finished? and evidence?(updated) and board(updated).evidence_required,
      do: Slipdock.Boards.add_comment(updated, evidence_text(updated), by: user)

    :ok
  end

  @doc """
  A card's evidence as Markdown (#1632, #1623): what was checked, then the
  commit and branch, the suite's result and the test files.
  """
  def evidence_text(%Card{} = card) do
    suite = card.evidence_suite

    [
      "**Evidence.**",
      card.evidence,
      card.evidence_commit &&
        "Commit: `#{card.evidence_commit}`" <>
          if(card.evidence_branch, do: " on `#{card.evidence_branch}`", else: ""),
      is_nil(card.evidence_commit) && card.evidence_branch && "Branch: `#{card.evidence_branch}`",
      card.evidence_pr && "Pull request: #{card.evidence_pr}",
      suite && "Suite: #{suite_text(suite)}",
      card.evidence_tests not in [nil, []] &&
        "Tests:\n" <> Enum.map_join(card.evidence_tests, "\n", &"- `#{&1}`")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("\n\n")
  end

  @doc "A suite's result in words: `passed (38 passed, 0 failed)`."
  def suite_text(%{} = suite) do
    counts =
      [{suite["passed"], "passed"}, {suite["failed"], "failed"}]
      |> Enum.reject(fn {n, _} -> is_nil(n) end)
      |> Enum.map_join(", ", fn {n, what} -> "#{n} #{what}" end)

    if counts == "", do: suite["result"], else: "#{suite["result"]} (#{counts})"
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

  ## Who an agent assigned (#1659) ------------------------------------------

  @doc """
  After a write changed `card`'s assignees from `before` to `now`, by
  `actor`: keeps `agent_assignee_ids`, the people an agent put on it. An
  agent's additions join it; whoever is taken off leaves it; a person (or
  the assistant, or a rule) adding someone makes that one theirs. A
  rejection takes off whoever is still on the list (`decide/5`).
  """
  def assigned(%Card{} = card, before, now, actor) when is_list(before) and is_list(now) do
    added = now -- before
    mine = card.agent_assignee_ids || []

    ids =
      if gated?(actor),
        do: Enum.uniq(mine ++ added) -- (before -- now),
        else: mine -- (added ++ (before -- now))

    ids = Enum.filter(ids, &(&1 in now))

    if Enum.sort(ids) != Enum.sort(mine) do
      import Ecto.Query
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [agent_assignee_ids: ids])
    end

    :ok
  end

  def assigned(_card, _before, _now, _actor), do: :ok

  ## Shipping by pull request -------------------------------------------------

  @doc "The branch a card's work goes on when its board ships by pull request (#1655)."
  def pr_branch(%Card{id: id}), do: "card-#{id}"

  @doc """
  What the builder of `card` is told when its board ships by pull request
  (#1655), or nil when it ships by push: never push the default branch,
  push `card-<id>` and open (or update) the pull request, and name it when
  completing. Said in a claimed job's prompt and in the card's JSON, so a
  runner or an older skill needs nothing else to know.

  A card tagged `security` (see `neutral?/1`, #1794) gets a neutral pull
  request instead: the repository may be public, and a PR describes the
  hole for anyone to read before the fix deploys. Its title is
  `neutral_pr_title/1`, never the card's; its body is only the card id,
  never `--fill` from the commits; and the builder is told to keep the
  commits, title and body to a neutral description of the change.
  """
  def ship_instructions(%Card{} = card) do
    if Board.ships_by_pr?(board(card)) do
      branch = pr_branch(card)
      neutral = neutral?(card)

      create =
        if neutral,
          do:
            ~s(gh pr create --head #{branch} --title "#{neutral_pr_title(card)}" --body "Card ##{card.id}.")
            |> then(&"`#{&1}` (a neutral title, not the card's)"),
          else: "`gh pr create --head #{branch} --title \"#{pr_title(card)}\" --fill`"

      """
      This board ships by pull request: never push the default branch.
      - Work on the branch `#{branch}`: `git fetch origin && git switch #{branch}` if it is on origin (a rejected card's earlier attempt), else `git switch -c #{branch}`. Rebase it on the default branch before pushing.
      - Commit with the card id (##{card.id}) in the message, then `git push -u origin #{branch}`.
      - Open the pull request once: `gh pr view #{branch}` shows one already open, which the push has updated; otherwise #{create}.
      #{if neutral, do: neutral_note() <> "\n", else: ""}- Before pushing, run the tests you added or changed and the project's own pre-push checks, not the whole suite: the pull request's CI runs it. Its pre-push checks are the ones its `CLAUDE.md`, contributing guide or handbook lists, often one command that runs what CI checks; if it lists none, formatting and a compile that fails on warnings.
      - The build to watch is the pull request's (`gh pr checks #{branch} --watch --fail-fast`, so a failed check stops the watch when it fails). Fix what it finds in this pass. If the pull request has no checks, run the whole suite yourself.
      - Complete the card with its URL: `slipdock done #{card.id} --pr <url>` (complete_card `pr`), with the rest of your evidence: CI's result as the suite (`--suite passed`, with its counts if CI shows them) and its run in `--evidence`. Accepting the card merges it; don't merge it yourself.
      """
      |> String.trim_trailing()
    end
  end

  defp neutral_note do
    "- This is a security fix, and the pull request, its commits and the branch are public before it deploys. " <>
      "Describe the change neutrally everywhere they show (commit messages, the PR's title and body, code comments): " <>
      "what it does in general terms (\"Tighten access checks in board events\"), never the hole, how to exploit it " <>
      "or a list of the affected endpoints. The detail stays on this card until the fix is deployed; " <>
      "after that, the closing comment may link to it."
  end

  @doc """
  Whether `card`'s pull request is to be neutral (#1794): it is tagged
  `security`. Its tags are loaded if they aren't.
  """
  def neutral?(%Card{} = card) do
    card
    |> Repo.preload(:tags)
    |> Map.fetch!(:tags)
    |> Enum.any?(&(String.downcase(&1.name) == "security"))
  end

  @doc "The pull request title a security card gets (#1794): its id and nothing else."
  def neutral_pr_title(%Card{id: id}), do: "Maintenance (##{id})"

  defp pr_title(%Card{} = card) do
    title = card.title |> String.replace(~s("), "'") |> String.slice(0, 80)
    "#{title} (##{card.id})"
  end

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
  Rejecting puts it back at the top of the board's ready list (where there
  is one), with the reason as a comment and on the card (`verify_note`), a
  handoff pointing at it, the assignees an agent put on it taken off (a
  person's stay), its evidence cleared for the next attempt and its
  rejections counted; then the board's feed runs, so it goes next.

  `{:ok, card}`, or `{:error, status, message}` in the API's shapes.
  """
  def decide(%Card{} = card, decision, params, actor, user)
      when decision in ["agree", "disagree"] do
    reason = params |> Map.get("reason") |> trim()
    audit_decision(card, decision, params, reason, in_runner_job(actor, card), user)
  end

  def decide(%Card{} = card, decision, params, actor, user) do
    actor = in_runner_job(actor, card)
    reason = params |> Map.get("reason") |> trim()
    commit = params |> Map.get("commit") |> trim()

    cond do
      decision == "merged" ->
        merged_by_hand(card, commit, actor, user)

      decision not in ~w(accept reject) ->
        {:error, :unprocessable_entity,
         "decision must be accept, reject or merged (agree or disagree for an audit)"}

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
        with {:ok, checks} <- verdict(card, decision, params, reason, actor),
             {:ok, _} = decided <-
               apply_decision(
                 card,
                 decision,
                 %{reason: reason, commit: commit, checks: checks},
                 actor,
                 user
               ) do
          cancel_verify_jobs(card, actor)
          decided
        end
    end
  end

  # The decision's verdict in parts (#1778), from `params["checks"]`, or for
  # a rejection given none, the checks its reason cites (`bar 2: …`). A
  # rejection names at least one failing part (a person's, given no parts at
  # all, may stand on its reason); an acceptance carries none but a missed
  # `should` rule. nil when there are no parts to keep.
  defp verdict(card, decision, params, reason, actor) do
    alias Slipdock.Verified.Checks

    with {:ok, given} <- checks_param(params) do
      checks =
        if given == %{} and decision == "reject", do: Checks.from_reason(reason), else: given

      checks = Checks.with_severity(checks, handbook_rules(card))
      # A person's rejection, given no parts at all, may stand on its reason.
      must_fail = given != %{} or gated?(actor)

      with :ok <- verdict_holds(decision, checks, must_fail) do
        {:ok, stored_checks(checks, given)}
      end
    end
  end

  defp verdict_holds("reject", checks, true) do
    if Slipdock.Verified.Checks.failing(checks) == [],
      do:
        {:error, :unprocessable_entity,
         "a rejection names what fails: give a failing check (`--check bar:2=fail:why`, " <>
           "`rule:UX-4=broken`, `ask=misses`, `handbook_line=disputed`), or start the reason " <>
           "with the one it fails (`bar 2: …`, `the ask: …`, `UX-4: …`, `Handbook line: …`)"},
      else: :ok
  end

  defp verdict_holds("accept", checks, _must_fail) do
    case Slipdock.Verified.Checks.blocking(checks) do
      [] ->
        :ok

      blocking ->
        {:error, :unprocessable_entity,
         "an acceptance can't carry a failing check: " <>
           Enum.join(blocking, ", ") <>
           " (a broken `must` rule, a bar item, the ask, the suite or the Handbook line is a rejection)"}
    end
  end

  defp verdict_holds(_decision, _checks, _must_fail), do: :ok

  # nil when there are no parts; parts read from the reason are marked, as
  # the comment already says them.
  defp stored_checks(checks, _given) when checks == %{}, do: nil
  defp stored_checks(checks, given) when given == %{}, do: Map.put(checks, "from_reason", true)
  defp stored_checks(checks, _given), do: checks

  defp checks_param(params) do
    case Slipdock.Verified.Checks.parse(Map.get(params, "checks")) do
      {:ok, _} = ok -> ok
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  # The handbook's rules for the card's tree, for the severity of each rule
  # a verdict names; none without a handbook.
  defp handbook_rules(card) do
    case card |> board() |> Slipdock.Handbook.find() do
      nil -> []
      handbook -> Slipdock.Handbook.Rules.rules(handbook)
    end
  end

  # A decision made in a runner job on this card (#1666) is the runner's:
  # the CLI or MCP token is the same one the builder and interactive
  # sessions use, so its label can't say who decided. The job must be on
  # this card and have a runner, so a header naming some other job credits
  # nothing.
  defp in_runner_job(actor, %Card{id: card_id}) do
    a = actor_map(actor) || %{}

    with id when is_integer(id) <- a["job_id"],
         %Slipdock.Runners.Job{card_id: ^card_id, runner_id: rid} when is_integer(rid) <-
           Repo.get(Slipdock.Runners.Job, id),
         %Slipdock.Runners.Runner{name: name} <- Repo.get(Slipdock.Runners.Runner, rid) do
      Slipdock.Actor.runner(a["user_id"], id, name)
    else
      _ -> actor
    end
  end

  defp apply_decision(
         card,
         "accept",
         %{reason: note, commit: commit, checks: checks},
         actor,
         user
       ) do
    if Board.ships_by_pr?(board(card)),
      do: accept_to_merge(card, note, commit, checks, actor, user),
      else: accept_and_complete(card, note, commit, checks, actor, user)
  end

  defp apply_decision(
         card,
         "reject",
         %{reason: reason, commit: commit, checks: checks},
         actor,
         user
       ) do
    changes = [
      verify_checks: checks,
      verify_state: "rejected",
      verify_by: actor_map(actor),
      verify_note: reason,
      verify_commit: blank_to_nil(commit),
      verify_at: now(),
      verify_rejections: (card.verify_rejections || 0) + 1
    ]

    count = (card.verify_rejections || 0) + 1
    limit = rejection_limit(card)
    # Over the limit (#1779), a person decides: the evidence stays for an
    # acceptance as is, and a wait holds the card out of the feed.
    over = limit > 0 and count > limit
    attrs = if over, do: %{}, else: no_evidence()

    with {:ok, card} <-
           Slipdock.Boards.update_card(
             card,
             Map.put(attrs, "flags", card.flags -- ["review"]),
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      by = who(actor, user)
      comment(card, "**Rejected** by #{by}.", with_parts(reason, checks), user)
      Slipdock.Findings.Signals.rejected(card, reason, checks, actor)
      if over, do: ask_a_person(card, count, limit, actor, user)
      send_back(card, "Rework: rejected by #{by}, reason under Verification", actor, user)
    end
    |> api_error()
  end

  ## Repeated rejections (#1779) ----------------------------------------------

  @limit_purpose "verify_limit"
  @rework_choice "Rework as rejected"
  @accept_choice "Accept as is"

  @doc """
  How many rejections a card on `card`'s tree may have before the next goes
  to a person (#1779): its root board's `verify_rejection_limit`. 0 is no
  limit.
  """
  def rejection_limit(%Card{} = card) do
    board = board(card)
    root = if board.root_id, do: Repo.get(Board, board.root_id) || board, else: board
    root.verify_rejection_limit || 0
  end

  # The rejection over the limit: the reasons so far as a comment, then a
  # wait on the board's owner to rework the card as rejected or accept it.
  defp ask_a_person(card, count, limit, actor, user) do
    reasons =
      card
      |> rejection_reasons()
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {r, n} -> "#{n}. #{r}" end)

    comment(
      card,
      "**Rejected #{count} times**, past the board's limit of #{limit}: a person decides now.",
      "The reasons so far:\n\n" <> reasons,
      user
    )

    owner = card |> board() |> Slipdock.Handbook.root() |> Map.get(:owner_id)

    case Slipdock.Boards.open_wait(card, actor, %{
           needs:
             "Card ##{card.id} was rejected #{count} times (the board allows #{limit}). " <>
               "Rework it as rejected, or accept it as is? The reasons are in the comments; " <>
               "you can edit the bar before you answer.",
           choices: [@rework_choice, @accept_choice],
           on_user_id: owner,
           purpose: @limit_purpose
         }) do
      {:ok, _} ->
        :ok

      {:error, why} ->
        comment(
          card,
          "**No wait opened** for a person to decide: #{inspect_error(why)}",
          nil,
          user
        )
    end
  end

  defp inspect_error(why) when is_binary(why), do: why
  defp inspect_error(why), do: inspect(why)

  # Each rejection's reason, oldest first, from the cards' own comments.
  defp rejection_reasons(%Card{id: id}) do
    from(c in Slipdock.Boards.Comment,
      where: c.card_id == ^id and like(c.body, "**Rejected** by%"),
      order_by: [asc: c.id],
      select: c.body
    )
    |> Repo.all()
    |> Enum.map(fn body ->
      body
      |> String.split("\n\n", parts: 2)
      |> Enum.at(1, "(no reason given)")
      |> String.split("\n\nChecks:", parts: 2)
      |> hd()
      |> String.replace(~r/\s+/, " ")
      |> String.slice(0, 400)
    end)
  end

  @doc """
  A wait closing (`Slipdock.Boards.answer_wait/3`): a rejection-limit wait
  (#1779) answered *Accept as is* accepts the card for whoever answered (on
  a pull request board, queueing the merge); any other answer, or a skip,
  sends it back for rework as rejected, its evidence cleared. Other waits
  are left alone.
  """
  def wait_closed(%Slipdock.Boards.Wait{purpose: @limit_purpose} = wait, actor) do
    card = Repo.get!(Card, wait.card_id)
    user = wait.closed_by_id && Repo.get(Slipdock.Accounts.User, wait.closed_by_id)

    if card.verify_state == "rejected" do
      if wait.choice == 2,
        do: accept_as_is(card, actor, user),
        else: rework_as_rejected(card, actor, user)
    end

    :ok
  end

  def wait_closed(_wait, _actor), do: :ok

  defp accept_as_is(card, actor, user) do
    note = "Accepted as is by #{who(actor, user)} after #{card.verify_rejections} rejections."

    apply_decision(
      card,
      "accept",
      %{reason: note, commit: card.evidence_commit || "", checks: nil},
      actor,
      user
    )
  end

  defp rework_as_rejected(card, actor, user) do
    {:ok, _} = Slipdock.Boards.update_card(card, no_evidence(), actor: actor, by: user)
    Slipdock.Automations.feed_board(card.board_id)
  end

  defp accept_and_complete(card, note, commit, checks, actor, user) do
    changes = [
      verify_checks: checks,
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
      comment(card, "**Accepted** by #{who(actor, user)}.", with_parts(note, checks), user)
      done = card |> board() |> Repo.preload(:columns) |> Map.get(:columns) |> done_list()

      if done && done.id != card.column_id,
        do: Slipdock.Boards.move_card(card.id, done.id, nil, actor: actor)

      card = Repo.get!(Card, card.id)
      maybe_audit(card)
      {:ok, card}
    end
    |> api_error()
  end

  # Back to the top of the ready list for rework (#1659), after a rejection
  # or a failed merge (#1657): the handoff points at the reason, the
  # builder's own assignment comes off and the board's feed runs.
  defp send_back(card, next_step, actor, user) do
    # The reason is on the comment and the verification block (and in a
    # claimed job's prompt and get_card): the handoff only points there.
    Slipdock.Boards.leave_handoff(card, user, %{next_step: next_step, via: handoff_via(actor)})

    # The builder's own assignment comes off (a person's stays), so a rule
    # that sends only unassigned cards sends it again.
    card = unassign_agents(Repo.get!(Card, card.id), actor, user)

    # Back to the top of the ready list, to be taken up again.
    columns = card |> board() |> Repo.preload(:columns) |> Map.get(:columns)

    case Slipdock.Flow.ready_list(columns) do
      %Column{id: id} = ready when id != card.column_id ->
        Slipdock.Boards.move_card_to_index(card, ready, :top, actor: actor)

      _ ->
        :ok
    end

    # A rejection is new information: the card isn't cooling, so the
    # board's feed can send it next.
    Slipdock.Automations.feed_board(card.board_id)

    {:ok, Repo.get!(Card, card.id)}
  end

  ## Merging (#1657) ------------------------------------------------------------

  @merge_kind "merge"

  @doc "The job kind that merges an accepted card's pull request (#1656, #1657)."
  def merge_kind, do: @merge_kind

  # Accepted on a board that ships by pull request: the card waits, merging,
  # while a runner merges its pull request; the merge finishing completes it.
  defp accept_to_merge(card, note, commit, checks, actor, user) do
    changes = [
      verify_checks: checks,
      verify_state: "merging",
      verify_by: actor_map(actor),
      verify_note: blank_to_nil(note),
      verify_commit: blank_to_nil(commit),
      verify_at: now()
    ]

    with {:ok, card} <-
           Slipdock.Boards.update_card(card, %{"flags" => card.flags -- ["review"]},
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      comment(
        card,
        "**Accepted** by #{who(actor, user)}; merging #{card.evidence_pr || "its pull request"}.",
        with_parts(note, checks),
        user
      )

      queue_merge(card, user, decider: decider_runner(actor))
      {:ok, Repo.get!(Card, card.id)}
    end
    |> api_error()
  end

  @doc """
  Queues the merge job for a card being merged (#1657), with no setting, to
  the pool `merge_pool/2` picks (`opts` go to it). With none, nothing is
  queued and the card says what to do. `{:ok, job}` or `:none`.
  """
  def queue_merge(%Card{} = card, user \\ nil, opts \\ []) do
    case merge_pool(card, opts) do
      nil ->
        Slipdock.Boards.add_comment(card, no_merger_text(card), by: user)
        :none

      pool ->
        case Slipdock.Runners.queue(card, %{
               pool: pool,
               kind: @merge_kind,
               prompt: merge_prompt(card),
               exclude_runner_id: opts[:exclude]
             }) do
          {:ok, job} ->
            {:ok, job}

          {:error, reason} ->
            Slipdock.Boards.add_comment(
              card,
              "**Merge job not queued** for pool `#{pool}`: #{reason}. " <>
                merge_by_hand_text(card),
              by: user
            )

            :none
        end
    end
  end

  @doc """
  The pool a card's merge job goes to (see `queue_merge/3`), or nil. Of the
  runners on the tree that take merge jobs, the first that applies (#1754):

    * one idle now (`Slipdock.Runners.idle?/1`), the builder's pool first:
      the merge goes at once, rather than waiting for a pass to end;
    * the runner that decided the card (`decider:`), about to finish its
      verify job;
    * the pool of the runner that built the card, else the most recently
      seen pool.

  `exclude:` leaves out a runner that couldn't merge here.
  """
  def merge_pool(%Card{} = card, opts \\ []) do
    import Ecto.Query
    alias Slipdock.Runners.Runner

    root = Board.root_id(board(card))

    capable =
      from(r in Runner,
        where: r.board_id == ^root and fragment("'merge' = ANY(?)", r.kinds),
        order_by: [desc_nulls_last: r.last_seen_at, asc: r.id]
      )
      |> Repo.all()
      |> Enum.reject(&(&1.id == opts[:exclude]))

    builder_pool =
      case builder_runner_id(card) do
        id when is_integer(id) -> Repo.one(from(r in Runner, where: r.id == ^id, select: r.pool))
        _ -> nil
      end

    pools = Enum.map(capable, & &1.pool)
    idle = for r <- capable, Slipdock.Runners.idle?(r), do: r.pool
    decider = Enum.find(capable, &(&1.id == opts[:decider]))

    cond do
      builder_pool && builder_pool in idle -> builder_pool
      idle != [] -> hd(idle)
      decider -> decider.pool
      builder_pool && builder_pool in pools -> builder_pool
      true -> List.first(pools)
    end
  end

  # The runner whose job made a decision, if one did (#1666): it is about
  # to finish that job, so it can take the merge next (#1754).
  defp decider_runner(actor) do
    import Ecto.Query

    case actor_map(actor) do
      %{"job_id" => id} when is_integer(id) ->
        Repo.one(from(j in Slipdock.Runners.Job, where: j.id == ^id, select: j.runner_id))

      _ ->
        nil
    end
  end

  @doc """
  Where a card being merged stands (#1657): `:queued` or `:running` while a
  merge job is open on it, `:none` when nothing will merge it (no runner
  can), nil when it isn't merging.
  """
  def merge_status(%Card{verify_state: "merging", id: id}) do
    import Ecto.Query

    case Repo.one(
           from(j in Slipdock.Runners.Job,
             where:
               j.card_id == ^id and j.kind == @merge_kind and
                 j.status in ^Slipdock.Runners.Job.open_statuses(),
             order_by: [desc: j.id],
             limit: 1,
             select: j.status
           )
         ) do
      nil -> :none
      "queued" -> :queued
      _ -> :running
    end
  end

  def merge_status(_card), do: nil

  defp merge_prompt(card) do
    "Merge the pull request of card ##{card.id}: #{card.evidence_pr} at the accepted commit " <>
      "#{card.verify_commit || card.evidence_commit}. The runner's built-in merge kind does this."
  end

  defp no_merger_text(card) do
    "**No runner can merge this.** None of this board's runners takes merge jobs: a runner " <>
      "says it does on each claim once its script is current (reinstall or update " <>
      "`slipdock-runner` / `slipdock-runner.ps1`; `MERGE=0` turns it off). " <>
      merge_by_hand_text(card)
  end

  defp merge_by_hand_text(card) do
    "Or merge #{card.evidence_pr || "the pull request"} yourself and press **Merged it myself** " <>
      "on the card (`slipdock verify #{card.id} merged`)."
  end

  @doc """
  A merge job has ended (#1657), called by `Slipdock.Runners` for kind
  merge. Done: the card completes, with the merge commit as `merge_sha`,
  and moves to the done list. A runner that couldn't merge here (not the
  pull request's repository, no git or gh, gh signed out) hands it on to
  another runner (#1754): the card's work isn't at fault. Anything else: it
  goes back to the top of the ready list as rejected, the merge's reason as
  the rejection's, so the builder rebases and submits it again. A card no
  longer merging is left alone.
  """
  def merge_finished(%Slipdock.Runners.Job{kind: @merge_kind} = job, runner_name) do
    case Repo.get(Card, job.card_id) do
      %Card{verify_state: "merging", completed: false} = card ->
        actor = Slipdock.Actor.runner(nil, job.id, runner_name)

        cond do
          job.status == "done" ->
            complete_merged(
              card,
              job.merged_sha,
              actor,
              nil,
              "**Merged** by runner #{runner_name}"
            )

          runner_refused?(job) ->
            hand_on(card, job, runner_name)

          true ->
            merge_failed(card, job, actor)
        end

      _ ->
        :ok
    end
  end

  def merge_finished(_job, _runner_name), do: :ok

  # What a runner script says, before touching anything, when the runner
  # itself can't merge (`job_merge` / `Job-Merge`, exit 2): the card isn't
  # at fault, so another runner may merge it.
  @runner_refusals [
    "but this runner's repository is",
    "has no origin remote",
    "git is not installed",
    "gh (GitHub CLI) is not installed",
    "gh is not signed in"
  ]

  # How many runners an acceptance's merge is handed to before the card
  # waits for a person.
  @merge_hand_ons 2

  defp runner_refused?(%{status: "failed"} = job) do
    said = merge_reason(job)

    String.starts_with?(said, "merge: ") and
      Enum.any?(@runner_refusals, &String.contains?(said, &1))
  end

  defp runner_refused?(_job), do: false

  # A runner that can't merge here hands the merge on, leaving that runner
  # out (#1754). Past @merge_hand_ons, or with no other runner, the card
  # stays merging with nothing queued and says why.
  defp hand_on(card, job, runner_name) do
    import Ecto.Query

    said = merge_reason(job)

    refused =
      from(j in Slipdock.Runners.Job,
        where:
          j.card_id == ^card.id and j.kind == @merge_kind and j.status == "failed" and
            j.inserted_at >= ^card.verify_at
      )
      |> Repo.all()
      |> Enum.count(&runner_refused?/1)

    pool = refused <= @merge_hand_ons && merge_pool(card, exclude: job.runner_id)
    queued = pool && queue_merge(card, nil, exclude: job.runner_id)

    case queued do
      {:ok, _job} ->
        Slipdock.Boards.add_comment(
          card,
          "**Merge handed on.** Runner #{runner_name} can't merge here, so pool `#{pool}` " <>
            "has it now.\n\n#{said}"
        )

      _ ->
        Slipdock.Boards.add_comment(
          card,
          "**Merge waiting.** Runner #{runner_name} can't merge here, and no other runner " <>
            "has taken it on. Fix the runner, or: " <> merge_by_hand_text(card) <> "\n\n#{said}"
        )
    end

    :ok
  end

  defp merge_failed(card, job, actor) do
    said = merge_reason(job)
    reason = "Merge failed (job ##{job.id}, #{job.status}): " <> said

    changes = [
      verify_state: "rejected",
      verify_note: reason,
      verify_at: now(),
      verify_rejections: (card.verify_rejections || 0) + 1
    ]

    with {:ok, card} <-
           Slipdock.Boards.update_card(card, no_evidence(),
             actor: actor,
             verify_changes: changes
           ) do
      comment(card, merge_failed_line(card, said), reason, nil)
      Slipdock.Findings.Signals.merge_failed(card, job, said)

      send_back(card, "Rework: the merge failed, reason under Verification", actor, nil)
    end
  end

  # What to do about a failed merge (#1666): a rebase only helps when the
  # branch conflicts with the default branch or its head moved; anything
  # else (gh signed out, the wrong repository, a closed pull request, a
  # failing check) is fixed where the reason says.
  defp merge_failed_line(card, said) do
    if rebase_fixes?(said),
      do:
        "**Merge failed.** It conflicts or its head moved: rebase `#{pr_branch(card)}` " <>
          "on the default branch and submit it again.",
      else:
        "**Merge failed.** The merge job's reason is below, and a rebase won't fix it: " <>
          "fix what it says, then submit the card again."
  end

  @doc """
  Whether a failed merge's reason (the merge job's own words) is one a
  rebase fixes (#1666): a conflict, or a head that moved after acceptance.
  """
  def rebase_fixes?(said) when is_binary(said) do
    Regex.match?(
      ~r/conflict|not mergeable|cannot be cleanly created|head branch was modified|it moved after|not the accepted commit|is not up to date|behind the base/i,
      said
    )
  end

  def rebase_fixes?(_), do: false

  # The runner's own words: its last `merge:` line, else the output's last line.
  defp merge_reason(job) do
    lines = (job.output || job.log_tail || "") |> String.split(~r/\R/, trim: true)

    (Enum.find(Enum.reverse(lines), &String.starts_with?(&1, "merge:")) || List.last(lines) ||
       "the merge job ended #{job.status}")
    |> String.slice(0, 1000)
  end

  # A person saying they merged it themselves (#1657): only on a card being
  # merged, and only a person.
  defp merged_by_hand(card, commit, actor, user) do
    cond do
      card.verify_state != "merging" ->
        {:error, :conflict, "card ##{card.id} isn't waiting for its merge"}

      gated?(actor) ->
        {:error, :forbidden, "only a person marks a card merged by hand"}

      commit != "" and not Regex.match?(~r/\A[0-9a-fA-F]{7,64}\z/, commit) ->
        {:error, :unprocessable_entity, "the merge commit must be a commit id"}

      true ->
        cancel_merge_jobs(card)

        complete_merged(
          card,
          blank_to_nil(commit),
          actor,
          user,
          "**Merged by hand** by #{who(actor, user)}"
        )
    end
  end

  defp complete_merged(card, sha, actor, user, line) do
    sha = sha && String.downcase(sha)

    with {:ok, card} <-
           Slipdock.Boards.update_card(card, %{"completed" => true},
             actor: actor,
             by: user,
             verify_changes: [verify_state: "accepted", merge_sha: sha]
           ) do
      comment(card, line <> if(sha, do: " as `#{sha}`.", else: "."), nil, user)
      done = card |> board() |> Repo.preload(:columns) |> Map.get(:columns) |> done_list()

      if done && done.id != card.column_id,
        do: Slipdock.Boards.move_card(card.id, done.id, nil, actor: actor)

      # Merged: an audit now can't hold anything up (#1780).
      card = Repo.get!(Card, card.id)
      maybe_audit(card)
      {:ok, card}
    end
    |> api_error()
  end

  defp cancel_merge_jobs(%Card{id: card_id}) do
    import Ecto.Query

    from(j in Slipdock.Runners.Job,
      where:
        j.card_id == ^card_id and j.kind == @merge_kind and
          j.status in ^Slipdock.Runners.Job.open_statuses()
    )
    |> Repo.all()
    |> Enum.each(&Slipdock.Runners.cancel_job/1)
  end

  defp unassign_agents(%Card{agent_assignee_ids: [_ | _] = ids} = card, actor, user) do
    on = Slipdock.Boards.assignee_ids(card)

    case Enum.filter(ids, &(&1 in on)) do
      [] ->
        card

      gone ->
        case Slipdock.Boards.update_card(card, %{"remove_assignee_ids" => gone},
               actor: actor,
               by: user
             ) do
          {:ok, card} -> card
          _ -> card
        end
    end
  end

  defp unassign_agents(card, _actor, _user), do: card

  @doc """
  The reason a rejected card was sent back with, and who rejected it, for
  the agent taking it up again (#1659): nil unless `card` is rejected.
  """
  def rejection(%Card{verify_state: "rejected", verify_note: note} = card)
      when is_binary(note) and note != "" do
    %{
      reason: note,
      by: who(card.verify_by),
      at: card.verify_at,
      rejections: card.verify_rejections || 0
    }
  end

  def rejection(_card), do: nil

  ## Audits (#1780) -------------------------------------------------------------

  @doc """
  How often `card`'s tree audits accepted work: its root board's
  `verify_audit`, 1 in N (0: never).
  """
  def audit_every(%Card{} = card) do
    board = board(card)
    root = if board.root_id, do: Repo.get(Board, board.root_id) || board, else: board
    root.verify_audit || 0
  end

  @doc """
  Whether card `card_id` is in the sample for 1 in `n`: a hash of its id,
  so about one card in `n` is, and the same card always answers the same.
  """
  def audit_sampled?(card_id, n) when is_integer(n) and n > 0,
    do: :erlang.phash2({:verify_audit, card_id}, n) == 0

  def audit_sampled?(_card_id, _n), do: false

  # A card an agent accepted (not a person), on a board with audits and a
  # verify pool, in the sample: queued for the verify pool as an audit,
  # never to the runner that built it or the one that verified it.
  defp maybe_audit(%Card{} = card) do
    board = board(card)
    n = audit_every(card)

    if board.verify_work and present?(board.verify_pool) and agent_decided?(card) and
         audit_sampled?(card.id, n) do
      builder = builder_runner_id(card)
      verifier = decider_runner(card.verify_by)

      Slipdock.Runners.queue(card, %{
        pool: board.verify_pool,
        kind: verify_kind(),
        audit: true,
        prompt: audit_prompt(card, board),
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

  @doc """
  What an audit job's agent is told (#1780): the verify prompt's checks, with
  every rule judged (`should` too), the original verdict shown, and a
  decision that only says whether it agrees.
  """
  def audit_prompt(%Card{} = card, %Board{} = board) do
    url = "#{Slipdock.Automations.Runner.base_url()}/boards/#{board.id}/cards/#{card.id}"
    handbook = Slipdock.Handbook.find(board)
    judging = judge_steps(card, board, handbook, audit: true)
    decide = length(judging) + 3

    """
    Audit card ##{card.id} “#{card.title}” on #{board.name}: #{url}

    Another agent did the work, and a verifier accepted it. You are checking the checker: judge the work afresh, as the verifier should have, then say whether you agree with its verdict. You change nothing: not the code, not the card. Your decision is a comment, and a disagreement raises an alert for the board's owner; the acceptance stands either way.

    The verdict you are auditing: accepted by #{who(card.verify_by)}#{if card.verify_at, do: " at #{card.verify_at}", else: ""}.
    #{original_verdict(card)}

    #{card_block(card, board, judging)}
    #{decide}. Say once whether you agree, and report it as a step first (`deciding: agree` or `deciding: disagree`):
       - `slipdock verify #{card.id} agree --reason "what you checked" --check ask=ok --check bar:1=ok …`
       - `slipdock verify #{card.id} disagree --reason "where the verdict is wrong, specifically" --check bar:2=fail:"why" …`
    Give your own verdict in parts, one `--check` each (MCP `verify_card` `checks`): `ask=ok|misses`, `bar:<n>=ok|fail`, `suite=<passed>:<failed>`#{if handbook, do: ", `rule:<id>=ok|broken|n/a`, `handbook_line=ok|disputed`", else: ""}. Disagree when any part fails that the verdict passed (a missed `should` rule included), or when it failed a part that holds.
    """
  end

  defp original_verdict(%Card{} = card) do
    note = if blank?(card.verify_note), do: "(no reason given)", else: card.verify_note

    parts =
      card.verify_checks
      |> Slipdock.Verified.Checks.lines()
      |> Enum.map_join("\n", fn
        {label, result, nil} -> "- #{label}: #{result}"
        {label, result, why} -> "- #{label}: #{result} — #{why}"
      end)

    if parts == "",
      do: "Its reason: #{note}\n(It gave no parts.)",
      else: "Its reason: #{note}\nIts parts:\n#{parts}"
  end

  # An audit's say (#1780): a comment, and for a disagreement an alert for
  # the board's owner. Nothing on the card changes. It comes from an audit
  # job on the card, or a person; never from whoever accepted it.
  defp audit_decision(card, decision, params, reason, actor, user) do
    with :ok <- may_audit(card, actor),
         {:ok, checks} <- checks_param(params) do
      checks =
        checks |> Slipdock.Verified.Checks.with_severity(handbook_rules(card)) |> empty_nil()

      if decision == "disagree" and reason == "",
        do: {:error, :unprocessable_entity, "a disagreement needs its reason"},
        else: record_audit(card, decision, reason, checks, actor, user)
    end
  end

  defp empty_nil(checks) when checks == %{}, do: nil
  defp empty_nil(checks), do: checks

  defp may_audit(card, actor) do
    cond do
      card.verify_state != "accepted" ->
        {:error, :conflict,
         "card ##{card.id} hasn't been accepted: only accepted work is audited"}

      same_actor?(card.verify_by, actor) ->
        {:error, :forbidden, "you accepted card ##{card.id}: a different agent audits it"}

      gated?(actor) and not in_audit_job?(card, actor) ->
        {:error, :forbidden,
         "an agent audits card ##{card.id} only from its audit job (a person may at any time)"}

      true ->
        :ok
    end
  end

  defp in_audit_job?(%Card{id: card_id}, actor) do
    case actor_map(actor) do
      %{"job_id" => id} when is_integer(id) ->
        match?(
          %Slipdock.Runners.Job{card_id: ^card_id, audit: true},
          Repo.get(Slipdock.Runners.Job, id)
        )

      _ ->
        false
    end
  end

  defp record_audit(card, decision, reason, checks, actor, user) do
    by = who(actor, user)
    agrees = decision == "agree"

    line =
      if agrees,
        do: "**Audit: agrees** with the acceptance, by #{by}.",
        else: "**Audit: disagrees** with the acceptance, by #{by}."

    comment(card, line, with_parts(blank_to_nil(reason), checks), user)

    unless agrees do
      Slipdock.Findings.Signals.audit_disagreed(card, reason, actor)
      root = card |> board() |> Slipdock.Handbook.root()

      Slipdock.Automations.raise_alert(%{
        "board_id" => root.id,
        "card_id" => card.id,
        "severity" => "warning",
        "title" => "An audit disagrees with the acceptance of ##{card.id}",
        "body" =>
          "#{by} audited “#{card.title}”, accepted by #{who(card.verify_by)}: " <>
            String.slice(reason, 0, 500)
      })
    end

    {:ok, Repo.get!(Card, card.id)}
  end

  ## Verify jobs ---------------------------------------------------------------

  @verify_kind "verify"

  @doc "The job kind a pending card is queued as (#1634)."
  def verify_kind, do: @verify_kind

  @doc """
  The job kinds that finish a card's work rather than add to it: verifying
  and merging. Lanes and the WIP limit hold work jobs only (#1807): these
  edit nobody's files and put no more work in progress.
  """
  def finishing_kinds, do: [@verify_kind, @merge_kind]

  @doc """
  Queues a verify job again for a card still pending verification that has
  none open (the health monitor's `verify_missing`): to its board's verify
  pool, never to the runner that built it. `{:ok, job}` or `{:error, reason}`.
  """
  def requeue_verify(%Card{verify_state: "pending"} = card) do
    board = board(card)

    if board.verify_work and board.verify_pool do
      Slipdock.Runners.queue(card, %{
        pool: board.verify_pool,
        kind: @verify_kind,
        prompt: verify_prompt(card, board),
        exclude_runner_id: builder_runner_id(card)
      })
    else
      {:error, "the board has no verify pool"}
    end
  end

  def requeue_verify(%Card{}), do: {:error, "the card isn't pending verification"}

  defp queue_verify_job(%Card{} = card, user) do
    board = board(card)

    if board.verify_work and board.verify_pool do
      builder = builder_runner_id(card)

      case Slipdock.Runners.queue(card, %{
             pool: board.verify_pool,
             kind: @verify_kind,
             prompt: verify_prompt(card, board),
             exclude_runner_id: builder
           }) do
        {:ok, job} ->
          say_if_no_one_can_take(card, job, board, builder, user)

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

  # The runner that built the card (#1625): the one running the job the
  # submission came from, else the last one to take a job on the card.
  defp builder_runner_id(%Card{} = card) do
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
      Slipdock.Boards.add_comment(
        card,
        "**Verify job ##{job.id} waits:** #{why}. Add a runner to the pool, or verify it by hand.",
        by: user
      )
    end

    :ok
  end

  @doc """
  What a verify job's agent is told (#1634): the card, what it asks, its bar
  and evidence, and how to decide. Rendered when the job is queued.

  The verifier judges, in order (#1777): the ask (does the bar cover what
  the card asks for?), the bar, and on a board with a handbook the rules for
  the diff's paths and the closing `Handbook:` line. A rejection cites the
  check it fails: a bar item, the ask, a rule id or the Handbook line.
  """
  def verify_prompt(%Card{} = card, %Board{} = board) do
    url = "#{Slipdock.Automations.Runner.base_url()}/boards/#{board.id}/cards/#{card.id}"
    commit = card.evidence_commit
    at = if commit, do: " --evidence-commit #{commit}", else: ""
    handbook = Slipdock.Handbook.find(board)
    judging = judge_steps(card, board, handbook)
    decide = length(judging) + 3

    """
    Verify card ##{card.id} “#{card.title}” on #{board.name} before it counts as done: #{url}

    Another agent did the work and submitted it. You are the second agent: check the work, don't redo it, and don't change the code or the card beyond your decision.

    #{card_block(card, board, judging)}
    #{decide}. Decide once, and report the decision as a step first (`deciding: accept` or `deciding: reject`):
       - `slipdock verify #{card.id} accept#{at} --reason "what you checked, each check in turn" --check ask=ok --check bar:1=ok …`
       - `slipdock verify #{card.id} reject#{at} --reason "<the check it fails>: what falls short, specifically" --check bar:2=fail:"why" …`
    Give the verdict in parts, one `--check` each (MCP `verify_card` `checks`): `ask=ok|misses`, `bar:<n>=ok|fail`, `suite=<passed>:<failed>`#{if handbook, do: ", `rule:<id>=ok|broken|n/a`, `handbook_line=ok|disputed`", else: ""}, each with `:<why>` after it if it needs one. A rejection names at least one failing part; an acceptance can't carry one, but for a missed `should` rule.
    A rejection cites what it fails: #{cite_list(handbook)}. It goes back to whoever takes the card next, so say exactly what to fix.
    """
  end

  # What the card asks, its bar and evidence, and the steps to its checks:
  # the same for a verify job and an audit.
  defp card_block(card, board, judging) do
    commit = card.evidence_commit

    """
    What the card asks (its description):
    #{if blank?(card.description), do: "(no description: the title is the ask)", else: ask_text(card.description)}

    The bar (what done means):
    #{if blank?(card.bar), do: "(none written: check it against the card's description)", else: card.bar}

    The evidence it gave:
    #{if evidence?(card), do: card |> evidence_text() |> String.replace_prefix("**Evidence.**\n\n", ""), else: "(none)"}
    Commit: #{commit || "(none given)"}

    Say where you are at each step, so the job shows it while you work: `slipdock job-progress --step "…"` (the job is the one in $SLIPDOCK_JOB_ID; or MCP `job_progress` with `step`). Give a step, never a note or `--message`: a note becomes a comment on the card, and the card stays quiet until you decide.

    1. Read the card and its comments: `slipdock card #{card.id}`.
    #{check_step(card, board)}
    #{judging |> Enum.with_index(3) |> Enum.map_join("\n", fn {text, n} -> "#{n}. #{text}" end)}\
    """
  end

  # The checks after the checkout, in order: the ask and the bar always; the
  # rules and the Handbook line only on a board with a handbook.
  defp judge_steps(card, board, handbook, opts \\ []) do
    base = [
      "The ask. Does the bar cover everything the description (and any request in the comments) asks for? A bar that leaves part of the ask out is a rejection (`the ask: the bar misses …`), even when the work meets the bar. Step: `judging the ask`",
      "The bar. Each item, against the change and the tests it names. A part not met is a rejection naming the item (`bar 2: …`). Step: `judging against the bar`"
    ]

    if handbook,
      do: [hd(base), bar_with_proposals(handbook) | handbook_steps(card, board, handbook, opts)],
      else: base
  end

  # On a board with a handbook a rule is a person's call, so a bar item that
  # asks for a rule change is met by an open proposal, never a direct edit
  # (#1882).
  defp bar_with_proposals(handbook) do
    code = handbook.board.code || to_string(handbook.board.id)

    """
    The bar. Each item, against the change and the tests it names. A part not met is a rejection naming the item (`bar 2: …`).
       #{rule_proposal_sentence()} List them with `slipdock garden #{code} --check proposal --json` and judge the proposal's content, not the live Rules list: name its id in the accept reason (`bar 3: met by proposal #5`).
       #{rule_rejection_sentence()} Step: `judging against the bar`\
    """
  end

  @doc """
  What a builder is told to do with the bar at pickup, before building
  (#1883): read each part against the guide and, when one needs a person,
  ask rather than meet it some other way and leave the conflict to the
  verifier. Said in a claimed job's prompt after the bar; the guide and the
  loop and work skills say the same.
  """
  def bar_pickup_check,
    do:
      "Before building, check each part of the bar against the guide: if one can't be met as written because it needs a person (a handbook rule added, reworded or dropped, a merge, a deploy to prod, applying a proposal), stop and ask. Open a wait (`slipdock wait <card> …`, update_card `wait`) naming the part and what you could do instead, so a person rewords the bar or confirms the alternative. Don't build to your own reading of it and leave the conflict to the verifier."

  @doc "What the verify and audit prompts say meets a bar item asking for a rule change (#1882)."
  def rule_proposal_sentence,
    do:
      "A bar item that adds, rewords or drops a handbook rule is met by a matching open rule proposal: a garden proposal with an `edit_section` step on that page's `## Rules` that says what the bar asks, since a rule is a person's call and an agent files a proposal rather than editing it."

  @doc "What the verify and audit prompts say a rejection never asks for (#1882)."
  def rule_rejection_sentence,
    do:
      "A rejection never asks the builder to edit `## Rules` directly: when the proposal is missing or says the wrong thing, ask for it to be filed or corrected."

  defp handbook_steps(card, board, handbook, opts) do
    code = handbook.board.code || to_string(handbook.board.id)
    sha = card.evidence_commit || "<commit>"

    base =
      if Board.ships_by_pr?(board) and not blank?(card.evidence_pr),
        do: "origin/$(gh pr view #{card.evidence_pr} --json baseRefName -q .baseRefName)",
        else: "origin/<default branch>"

    [
      """
      The rules. In the clean tree, list the rules for the paths the change touches:
         `git diff --name-only $(git merge-base #{base} #{sha}) #{sha} | slipdock handbook #{code} --paths-from -`
         #{rules_judging(opts[:audit])} Step: `judging the rules`\
      """,
      """
      The Handbook line. Find the `Handbook:` line, in the evidence or the builder's closing comment, and hold it against the diff with the docs gate: user-visible behaviour updates the Specification; structure or boundaries, Architecture or the Data model; a choice between alternatives, a new page in `Handbook/Decisions`; something reusable, Shared modules or Components; a UI pattern, UX & UI; how to test, build or deploy, Testing & tooling or Operations. No line, a line saying `no change` on a diff that needed one, or a line naming pages the work didn't edit (`slipdock page history <page>`), is a rejection (`Handbook line: …`). Step: `judging the Handbook line`\
      """
    ]
  end

  defp rules_judging(true),
    do:
      "Judge every rule it lists, `should` rules as well as `must`: a rule whose check is a test is kept when that test passes; a `judgement` rule, by reading the change. Name each one you find broken by its id (`ARCH-3: …`)."

  defp rules_judging(_),
    do:
      "Judge every `must` rule it lists: a rule whose check is a test is kept when that test passes; a `judgement` rule, by reading the change. A broken `must` is a rejection citing its id (`ARCH-3: …`). List any `should` rule missed in the accept reason, each as a finding in a `Findings:` block there (`- rule: ARCH-6 missed: <how>`), so the board keeps it."

  defp cite_list(nil), do: "the bar item (`bar 2: …`) or the ask (`the ask: …`)"

  defp cite_list(_handbook),
    do:
      "a bar item (`bar 2: …`), the ask (`the ask: …`), a rule id (`ARCH-3: …`) or the Handbook line (`Handbook line: …`)"

  # The ask as the prompt shows it: the description, cut short if long.
  @ask_cap 4000
  defp ask_text(text) do
    text = String.trim(text)

    if String.length(text) > @ask_cap,
      do: String.slice(text, 0, @ask_cap) <> "\n… (cut short: read the rest on the card)",
      else: text
  end

  # Step 2 of the verify prompt. On a pull request board the PR's CI has run
  # the suite at the submitted commit, so the verifier reads the change and
  # checks CI rather than running the suite again (#1808).
  defp check_step(%Card{evidence_commit: commit} = card, board) do
    tree =
      if commit,
        do:
          "Check out #{commit} in a clean tree (`git worktree add /tmp/verify-#{card.id} #{commit}`), so nothing uncommitted counts",
        else: "Find the work in the project's repository, in a clean tree"

    pr = card.evidence_pr

    if Board.ships_by_pr?(board) and not blank?(pr) do
      head = commit || "the commit you check"

      """
      2. #{tree}, and read the change itself (its diff from the default branch) and the tests it names. Don't run the suite: the pull request's CI runs it at this commit.
         - `gh pr view #{pr} --json headRefOid,statusCheckRollup`: the head must be #{head}. If the pull request has moved on since it was submitted, reject it to be submitted again at its head.
         - Every check must have passed. While any is still running, wait (`gh pr checks #{pr} --watch`). A failed check is a rejection: name it.
         - If the pull request has no checks at all, run the suite in the clean tree instead.
         Steps to report:
         - `checked out #{commit || "<commit>"}`
         - `CI: <n> checks passed at #{commit || "<commit>"}` (or `waiting for CI`, `CI failed: <check>`)\
      """
    else
      """
      2. #{tree}, run the suite there, and read the change itself and the tests it names. Steps to report:
         - `checked out #{commit || "<commit>"}`
         - `tests running: <which>`
         - `tests passed: <n>, failed: <n>` (or `tests failed: …`)\
      """
    end
  end

  # Whoever decides first decides: the other verify jobs on the card stop
  # (an audit, queued by an acceptance, isn't one of them: #1780).
  defp cancel_verify_jobs(%Card{id: card_id}, actor) do
    import Ecto.Query
    mine = actor_map(actor)["job_id"]

    from(j in Slipdock.Runners.Job,
      where:
        j.card_id == ^card_id and j.kind == @verify_kind and not j.audit and
          j.status in ^Slipdock.Runners.Job.open_statuses()
    )
    |> Repo.all()
    |> Enum.reject(&(&1.id == mine))
    |> Enum.each(&Slipdock.Runners.cancel_job/1)
  end

  defp api_error({:error, %Ecto.Changeset{} = cs}), do: {:error, cs}
  defp api_error(other), do: other

  # The decision's comment keeps its verdict in parts (#1778), so a later
  # decision replacing `verify_checks` loses nothing.
  defp with_parts(note, nil), do: note
  defp with_parts(note, %{"from_reason" => true}), do: note

  defp with_parts(note, checks) do
    parts =
      checks
      |> Slipdock.Verified.Checks.lines()
      |> Enum.map_join("\n", fn
        {label, result, nil} -> "- #{label}: #{result}"
        {label, result, why} -> "- #{label}: #{result} — #{why}"
      end)

    [note, "Checks:\n\n" <> parts]
    |> Enum.reject(&Enum.member?([nil, ""], &1))
    |> Enum.join("\n\n")
  end

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

  @doc """
  Who an actor stored on a card (`verify_by`, `verify_submitter`) was, in
  words: an agent by its token's label, a person by their name.
  """
  def who(nil), do: "somebody"

  def who(actor) do
    case actor_map(actor) do
      %{"kind" => "agent"} ->
        who(actor, nil)

      %{"user_id" => id} when is_integer(id) ->
        Slipdock.Accounts.User.display_name(Repo.get(Slipdock.Accounts.User, id))

      _ ->
        "somebody"
    end
  end

  @doc """
  The person behind an actor stored on a card, when it was a person whose
  account still exists: nil for an agent, a deleted account or nobody. The
  card panel uses it to show their email and offer a note or an assignment.
  """
  def person(nil), do: nil

  def person(actor) do
    case actor_map(actor) do
      %{"kind" => "agent"} -> nil
      %{"user_id" => id} when is_integer(id) -> Repo.get(Slipdock.Accounts.User, id)
      _ -> nil
    end
  end

  defp who(actor, user) do
    a = actor_map(actor)

    cond do
      a["via"] == "runner" and a["agent"] -> "runner #{a["agent"]}"
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
