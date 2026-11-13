defmodule Slipdock.Verified.Decisions do
  @moduledoc """
  Deciding a card submitted for verification: accepting, rejecting and
  holding it for a person, a card over its rejection limit, the waits those
  open, the server's own acceptance of a card no verifier checks, and what
  follows a card being saved.
  """

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Verified.Circling

  alias Slipdock.Verified.{
    Actors,
    Audits,
    Epics,
    Evidence,
    Jobs,
    Merging,
    Outcome,
    Rejections,
    Shipping,
    Util
  }

  @nothing_to_merge "an epic whose subcards merged their own pull requests: nothing to merge"
  @no_code_accepted "a card that changes no code: nothing to merge"

  @doc """
  After `before` has been saved as `updated`: a card completed (or submitted
  for verification) with evidence on a board that asks for it gets the
  evidence as a comment, by `user` — once: not again when it is accepted.
  """
  def saved(%Card{} = before, %Card{} = updated, user) do
    unverified? = submitted(before, updated, user)

    # Accepted by a person completing it: no job need check it now.
    if before.verify_state == "pending" and updated.verify_state == "accepted",
      do: Jobs.cancel_verify_jobs(updated, nil)

    # Accepted, or merging on a board that ships by pull request: its
    # rejections have been dealt with (#2119).
    if accepted?(updated) and not accepted?(before),
      do: Slipdock.Findings.Signals.accepted(updated)

    # The epic's last spike answered: planning can resume (#2350).
    Slipdock.Spikes.answered(before, updated)

    # An audit's rework done: the alerts that named it come down (#2691).
    if finished_now?(before, updated), do: Audits.clear_audit_alerts(updated)

    evidence_comment(before, updated, user)
    if unverified?, do: accept_unverified(updated, user)

    :ok
  end

  defp accepted?(%Card{verify_state: state}), do: Enum.member?(~w(accepted merging), state)

  defp finished_now?(before, updated),
    do:
      (updated.completed and not before.completed) or
        (accepted?(updated) and not accepted?(before))

  # The evidence as a comment, once, when the card is completed or submitted.
  defp evidence_comment(before, updated, user) do
    finished? =
      (not before.completed and updated.completed and before.verify_state != "pending") or
        (before.verify_state != "pending" and updated.verify_state == "pending")

    if finished? and Evidence.evidence?(updated) and Util.board(updated).evidence_required,
      do: Slipdock.Boards.Comments.add_comment(updated, Evidence.evidence_text(updated), by: user)
  end

  # A card just gone pending: queued for a verifier, or (a `docs` card,
  # #1953) left for the server to accept once its evidence is on the card,
  # when this answers true.
  defp submitted(%Card{verify_state: "pending"}, _updated, _user), do: false

  defp submitted(_before, %Card{verify_state: "pending"} = updated, user) do
    unverified? = not_verified?(updated)
    if not unverified?, do: Jobs.queue_verify_job(updated, user)

    # Shipped by push: it no longer holds up the cards that depend on it.
    if Shipping.released?(updated),
      do: Slipdock.Boards.Dependencies.unblock_dependents(updated, by: user)

    unverified?
  end

  defp submitted(_before, _updated, _user), do: false

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
    reason = params |> Map.get("reason") |> Util.trim()
    Audits.audit_decision(card, decision, params, reason, in_runner_job(actor, card), user)
  end

  def decide(%Card{verify_state: "held"} = card, decision, params, actor, user)
      when decision in ~w(accept reject) do
    held_decision(card, decision, params |> Map.get("reason") |> Util.trim(), actor, user)
  end

  def decide(%Card{} = card, decision, params, actor, user) do
    actor = in_runner_job(actor, card)
    reason = params |> Map.get("reason") |> Util.trim()
    commit = params |> Map.get("commit") |> Util.trim()

    cond do
      decision == "merged" ->
        Merging.merged_by_hand(card, commit, actor, user)

      refusal = refusal(card, decision, reason, commit, actor) ->
        refusal

      true ->
        decide_pending(card, decision, params, %{reason: reason, commit: commit}, actor, user)
    end
  end

  # Why `actor` can't accept or reject `card` as asked, in the API's shape,
  # or nil when it can.
  defp refusal(card, decision, reason, commit, actor) do
    cond do
      not Enum.member?(~w(accept reject), decision) ->
        {:error, :unprocessable_entity,
         "decision must be accept, reject or merged (agree or disagree for an audit)"}

      card.verify_state != "pending" ->
        {:error, :conflict, "card ##{card.id} isn't waiting for verification"}

      Actors.same_actor?(card.verify_submitter, actor) ->
        {:error, :forbidden,
         "you submitted card ##{card.id}: a different agent, or a person, verifies it"}

      decision == "reject" and reason == "" ->
        {:error, :unprocessable_entity, "a rejection needs its reason"}

      other_commit?(commit, card.evidence_commit) ->
        {:error, :unprocessable_entity,
         "the evidence is for commit #{card.evidence_commit}: verify the work at that commit"}

      true ->
        nil
    end
  end

  # Whether the verifier names a commit that isn't the evidence's.
  defp other_commit?(commit, evidence_commit) do
    commit != "" and not Enum.member?([nil, ""], evidence_commit) and
      not commit_matches?(commit, evidence_commit)
  end

  defp decide_pending(card, decision, params, %{reason: reason, commit: commit}, actor, user) do
    with {:ok, checks} <- verdict(card, decision, params, reason, actor),
         {:ok, _} = decided <-
           apply_decision(
             card,
             decision,
             %{reason: reason, commit: commit, checks: checks},
             actor,
             user
           ) do
      Jobs.cancel_verify_jobs(card, actor)
      Slipdock.Findings.Signals.pre_existing(card, checks, actor)
      Slipdock.Findings.Signals.pre_existing_mutants(card, checks, actor)
      decided
    end
  end

  # The decision's verdict in parts (#1778), from `params["checks"]`, or for
  # a rejection given none, the checks its reason cites (`bar 2: …`). A
  # rejection names at least one failing part (a person's, given no parts at
  # all, may stand on its reason); an acceptance carries none but a missed
  # `should` rule. nil when there are no parts to keep.
  defp verdict(card, decision, params, reason, actor) do
    alias Slipdock.Verified.Checks

    with {:ok, given} <- Audits.checks_param(params),
         from_reason = given == %{} and decision == "reject",
         checks = if(from_reason, do: Checks.from_reason(reason), else: given),
         {:ok, checks} <- carry_previous(card, checks) do
      checks = Checks.with_severity(checks, Audits.handbook_rules(card))
      # A person's rejection, given no parts at all, may stand on its reason.
      must_fail = given != %{} or Actors.gated?(actor)

      with :ok <- verdict_holds(decision, checks, must_fail) do
        {:ok, checks |> stored_checks(from_reason) |> judged_at(decision, params, card)}
      end
    end
  end

  # A resubmission's verdict (#1944): what the last verdict passed and this
  # one didn't judge is carried, marked with the commit it passed at.
  defp carry_previous(card, checks) do
    previous = Rejections.previous_verdict(card)

    case Slipdock.Verified.Checks.carry(
           checks,
           previous && previous.checks,
           previous && previous.sha
         ) do
      {:ok, _} = ok -> ok
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  # The commit the verdict judged: the one the verifier named, else the
  # evidence's. The next verdict carries from it.
  defp judged_at(nil, _decision, _params, _card), do: nil

  defp judged_at(checks, decision, params, card) do
    case Util.blank_to_nil(Util.trim(Map.get(params, "commit"))) ||
           Util.blank_to_nil(Util.trim(card.evidence_commit)) do
      nil -> checks
      sha -> Map.merge(checks, %{"judged_at" => sha, "decision" => decision})
    end
  end

  defp verdict_holds("reject", checks, true) do
    if Slipdock.Verified.Checks.failing(checks) == [],
      do:
        {:error, :unprocessable_entity,
         "a rejection names what fails: give a failing check (`--check bar:2=fail:why`, " <>
           "`rule:UX-4=broken`, `ask=misses`, `handbook_line=disputed`, " <>
           "`mutant:survived=lib/foo.ex:42:<mutation>`), or start the reason " <>
           "with the one it fails (`bar 2: …`, `the ask: …`, `UX-4: …`, `Handbook line: …`)" <>
           pre_existing_note(checks)},
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
           " (a broken `must` rule, a bar item, the ask, the suite, the Handbook line, an important " <>
           "defect or a surviving mutant is a rejection)"}
    end
  end

  defp verdict_holds(_decision, _checks, _must_fail), do: :ok

  # A rejection naming only pre-existing rule hits (#1945) is told why.
  defp pre_existing_note(checks) do
    if Slipdock.Verified.Checks.pre_existing(checks) == [] and
         Slipdock.Verified.Checks.pre_existing_mutants(checks) == [],
       do: "",
       else:
         ". A rule broken, or a mutant surviving, only in code the change didn't touch " <>
           "(`pre-existing`) is never a rejection: accept, and it is kept as a finding"
  end

  # nil when there are no parts; parts read from the reason are marked, as
  # the comment already says them.
  defp stored_checks(checks, _from_reason) when checks == %{}, do: nil
  defp stored_checks(checks, true), do: Map.put(checks, "from_reason", true)
  defp stored_checks(checks, false), do: checks

  # A decision made in a runner job on this card (#1666) is the runner's:
  # the CLI or MCP token is the same one the builder and interactive
  # sessions use, so its label can't say who decided. The job must be on
  # this card and have a runner, so a header naming some other job credits
  # nothing.
  defp in_runner_job(actor, %Card{id: card_id}) do
    a = Actors.actor_map(actor) || %{}

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
    cond do
      not Board.ships_by_pr?(Util.board(card)) ->
        accept_and_complete(card, note, commit, checks, actor, user)

      Evidence.no_code?(card) ->
        # Nothing was committed, so there is nothing to merge (#1938).
        accept_and_complete(card, note, commit, checks, actor, user, @no_code_accepted)

      Epics.nothing_to_merge?(card) ->
        # An epic whose subcards merged their own pull requests (#1917).
        accept_and_complete(card, note, commit, checks, actor, user, @nothing_to_merge)

      true ->
        accept_or_hold(card, note, commit, checks, actor, user)
    end
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
      verify_by: Actors.actor_map(actor),
      verify_note: reason,
      verify_commit: Util.blank_to_nil(commit),
      verify_at: Util.now(),
      verify_rejections: (card.verify_rejections || 0) + 1
    ]

    count = (card.verify_rejections || 0) + 1
    limit = Rejections.rejection_limit(card)
    # Over the limit (#1779), a person decides: the evidence stays for an
    # acceptance as is, and a wait holds the card out of the feed.
    over = limit > 0 and count > limit
    attrs = if over, do: %{}, else: Evidence.no_evidence()

    with {:ok, card} <-
           Slipdock.Boards.Cards.update_card(
             card,
             Map.put(attrs, "flags", rejected_flags(card.flags, count)),
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      by = Actors.who(actor, user)
      # The rejected work's log, and the verifier's, keep the failure time (#1872).
      Slipdock.Runners.TranscriptRetention.card_failed(card)
      Outcome.comment(card, "**Rejected** by #{by}.", Outcome.with_parts(reason, checks), user)
      Slipdock.Findings.Signals.rejected(card, reason, checks, actor)
      Circling.after_rejection(card, count, Rejections.rejection_comments(card), user)
      if over, do: ask_a_person(card, count, limit, actor, user)
      Outcome.send_back(card, "Rework: rejected by #{by}, reason under Verification", actor, user)
    end
    |> Outcome.api_error()
  end

  # A rejection takes the `review` flag off, except from a card going round
  # in circles (#2047): from the second on, it stays until it is accepted.
  defp rejected_flags(flags, count) do
    if count >= Circling.threshold(),
      do: Enum.uniq(flags ++ ["review"]),
      else: flags -- ["review"]
  end

  ## Repeated rejections (#1779) ----------------------------------------------

  @limit_purpose "verify_limit"
  # The human tier's wait (#1952), below.
  @held_purpose "before_merge"
  @merge_choice "Merge"
  @send_back_choice "Send back"
  @rework_choice "Rework as rejected"
  @accept_choice "Accept as is"

  # The rejection over the limit: the reasons so far as a comment, then a
  # wait on the board's owner to rework the card as rejected or accept it.
  defp ask_a_person(card, count, limit, actor, user) do
    rejections = Rejections.rejection_comments(card)

    reasons =
      rejections
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{reason, failed}, n} ->
        "#{n}. #{reason}" <>
          if(failed == [], do: "", else: " (failed: #{Enum.join(failed, ", ")})")
      end)

    Outcome.comment(
      card,
      "**Rejected #{count} times**, past the board's limit of #{limit}: a person decides now.",
      "The reasons so far:\n\n" <> reasons <> "\n\n" <> approach_line(rejections),
      user
    )

    # A release question (#1949): on the first person the tree routes
    # `release` to, else on the owner (`Slipdock.WaitRoutes`).
    case Slipdock.Boards.Waits.open_wait(card, actor, %{
           needs: limit_question(card, count, limit, rejections),
           choices: [@rework_choice, @accept_choice],
           question: "release",
           purpose: @limit_purpose
         }) do
      {:ok, _} ->
        :ok

      {:error, why} ->
        Outcome.comment(
          card,
          "**No wait opened** for a person to decide: #{inspect_error(why)}",
          nil,
          user
        )
    end
  end

  defp inspect_error(why) when is_binary(why), do: why
  defp inspect_error(why), do: inspect(why)

  # Past the rejection limit (#1945): the round cap's question. The parts
  # that failed each time, and that the approach, not the fix, may be wrong.
  defp approach_line(rejections) do
    again =
      rejections
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.frequencies()
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))

    lead =
      if again == [],
        do: "Each round failed on something else.",
        else: "#{Enum.join(again, ", ")} failed more than once."

    lead <>
      " The approach may be wrong, not the fix: before another round of fixes, " <>
      "decide whether the card needs a different approach, a reworded bar, or accepting as is."
  end

  @limit_needs_cap 990
  defp limit_question(card, count, limit, rejections) do
    rounds =
      rejections
      |> Enum.with_index(1)
      |> Enum.map_join("; ", fn {{_, failed}, n} ->
        "#{n}. " <> if(failed == [], do: "(no part named)", else: Enum.join(failed, ", "))
      end)

    head = "Card ##{card.id} was rejected #{count} times (the board allows #{limit}). "

    tail =
      " The approach may be wrong, not the fix: rework it as rejected (rewording the bar or " <>
        "the card first if the approach should change), or accept it as is? The reasons are " <>
        "in the comments; you can edit the bar before you answer."

    room = @limit_needs_cap - String.length(head) - String.length(tail) - 30

    rounds =
      if String.length(rounds) > room, do: String.slice(rounds, 0, room) <> "…", else: rounds

    head <> "Failed each time: " <> rounds <> "." <> tail
  end

  @doc """
  A wait closing (`Slipdock.Boards.Waits.answer_wait/3`): a rejection-limit wait
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

  def wait_closed(%Slipdock.Boards.Wait{purpose: @held_purpose} = wait, actor),
    do: held_wait_closed(wait, actor)

  def wait_closed(_wait, _actor), do: :ok

  defp accept_as_is(card, actor, user) do
    note =
      "Accepted as is by #{Actors.who(actor, user)} after #{card.verify_rejections} rejections."

    apply_decision(
      card,
      "accept",
      %{reason: note, commit: card.evidence_commit || "", checks: nil},
      actor,
      user
    )
  end

  defp rework_as_rejected(card, actor, user) do
    {:ok, _} =
      Slipdock.Boards.Cards.update_card(card, Evidence.no_evidence(), actor: actor, by: user)

    Slipdock.Automations.feed_board(card.board_id)
  end

  defp accept_and_complete(card, note, commit, checks, actor, user, why \\ nil) do
    changes = [
      verify_checks: checks,
      verify_state: "accepted",
      verify_by: Actors.actor_map(actor),
      verify_note: Util.blank_to_nil(note),
      verify_commit: Util.blank_to_nil(commit),
      verify_at: Util.now()
    ]

    with {:ok, card} <-
           Slipdock.Boards.Cards.update_card(
             card,
             %{"completed" => true, "flags" => card.flags -- ["review"]},
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      line = "**Accepted** by #{Actors.who(actor, user)}" <> if(why, do: "; #{why}.", else: ".")
      Outcome.comment(card, line, Outcome.with_parts(note, checks), user)

      done =
        card |> Util.board() |> Repo.preload(:columns) |> Map.get(:columns) |> Outcome.done_list()

      if done && done.id != card.column_id,
        do: Slipdock.Boards.Cards.move_card(card.id, done.id, nil, actor: actor)

      card = Repo.get!(Card, card.id)
      Jobs.maybe_audit(card)
      # Where work ships by push, accepted is merged (#2835).
      Slipdock.Releases.card_merged(card)
      {:ok, card}
    end
    |> Outcome.api_error()
  end

  ## The human tier (#1952) -----------------------------------------------------

  @doc "The purpose of the wait a held card's acceptance opens (#1952)."
  def held_purpose, do: @held_purpose

  @doc "The `purpose` of the wait a card over its rejection limit opens."
  def limit_purpose, do: @limit_purpose

  @doc """
  Whether an agent's acceptance of `card` waits for a person before its
  pull request merges (#1952): an agent decided, and the card's human tier
  (`Slipdock.Profiles.tier/1`) is `before_merge`. A person's acceptance is
  a person's look already.
  """
  def hold_for_a_person?(%Card{} = card, actor),
    do:
      (Actors.gated?(actor) or Actors.server?(actor)) and
        Slipdock.Profiles.tier(card) == "before_merge"

  ## The verifier's spend (#1953) ----------------------------------------------

  @unverified_profiles ~w(docs)
  @doc """
  Whether a card just submitted for verification goes unverified (#1953):
  its board has profiles on and its profile (set, else inferred) is one of
  `unverified_profiles/0`. No verify job is queued; the server accepts it
  itself (`accept_unverified/2`). The bar is still required and locked.
  """
  def not_verified?(%Card{} = card),
    do:
      Util.board(card).profiles == true and
        Enum.member?(@unverified_profiles, Slipdock.Profiles.profile_of(card))

  @doc "The profiles whose cards no verify job checks: `docs`."
  def unverified_profiles, do: @unverified_profiles

  # The server's acceptance of a card no verifier checks: the suite is CI's
  # result as the evidence gives it, and a failing one sends it back.
  defp accept_unverified(%Card{} = card, user) do
    card = Repo.get!(Card, card.id)
    profile = Slipdock.Profiles.profile_of(card)
    suite = suite_part(card.evidence_suite)
    checks = Map.merge(%{"not_verified" => profile}, suite)

    {decision, reason} =
      if Slipdock.Verified.Checks.failing(suite) == [],
        do: {"accept", "profile #{profile}: not verified (no verify job runs for it)"},
        else:
          {"reject",
           "the suite: #{suite["suite"]["failed"]} failed. A #{profile} card is accepted " <>
             "unverified only on a passing suite: fix it and complete it again"}

    with {:error, _, message} <-
           apply_decision(
             card,
             decision,
             %{reason: reason, commit: card.evidence_commit || "", checks: checks},
             Actors.server_actor(),
             user
           )
           |> unverified_result() do
      Outcome.comment(
        card,
        "**Not accepted** (profile #{profile}, not verified): #{message}. A person accepts it " <>
          "with `slipdock verify #{card.id} accept`.",
        nil,
        user
      )
    end
  end

  defp unverified_result({:ok, _}), do: :ok
  defp unverified_result({:error, %Ecto.Changeset{} = cs}), do: {:error, 422, inspect(cs.errors)}
  defp unverified_result({:error, status, message}), do: {:error, status, message}
  defp unverified_result(other), do: {:error, 500, inspect(other)}

  # The evidence's suite (`{result, passed, failed}`) as a verdict's part.
  defp suite_part(%{} = suite) do
    passed = suite["passed"] || suite[:passed]
    failed = suite["failed"] || suite[:failed]
    result = to_string(suite["result"] || suite[:result])

    cond do
      is_integer(passed) and is_integer(failed) ->
        %{"suite" => %{"passed" => passed, "failed" => failed}}

      result == "failed" ->
        %{"suite" => %{"passed" => 0, "failed" => 1}}

      true ->
        %{}
    end
  end

  defp suite_part(_suite), do: %{}

  # Accepted on a board that ships by pull request: merging, or held for a
  # person first when its tier says so.
  defp accept_or_hold(card, note, commit, checks, actor, user) do
    if hold_for_a_person?(card, actor),
      do: hold(card, note, commit, checks, actor, user),
      else: accept_to_merge(card, note, commit, checks, actor, user)
  end

  # Accepted, held (#1952): no merge job yet, the `review` flag kept (it
  # behaves as a card awaiting verification), and a wait routed `release`
  # asking a person to merge it or send it back.
  defp hold(card, note, commit, checks, actor, user) do
    changes = [
      verify_checks: checks,
      verify_state: "held",
      verify_by: Actors.actor_map(actor),
      verify_note: Util.blank_to_nil(note),
      verify_commit: Util.blank_to_nil(commit),
      verify_at: Util.now()
    ]

    with {:ok, card} <-
           Slipdock.Boards.Cards.update_card(card, %{},
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      profile = Slipdock.Profiles.profile_of(card)

      Outcome.comment(
        card,
        "**Accepted** by #{Actors.who(actor, user)}; held for a person before merging: " <>
          "its profile is `#{profile}`, whose human tier is `before_merge`.",
        Outcome.with_parts(note, checks),
        user
      )

      ask_to_merge(card, profile, actor, user)
      {:ok, Repo.get!(Card, card.id)}
    end
    |> Outcome.api_error()
  end

  defp ask_to_merge(card, profile, actor, user) do
    needs =
      "Card ##{card.id} (profile #{profile}) was accepted by #{Actors.who(actor, user)}. Its human " <>
        "tier is before_merge, so a person decides before " <>
        "#{card.evidence_pr || "its pull request"} merges: merge it, or send it back " <>
        "(say why: the reason goes back to the builder)?"

    case Slipdock.Boards.Waits.open_wait(card, actor, %{
           needs: String.slice(needs, 0, 990),
           choices: [@merge_choice, @send_back_choice],
           question: "release",
           purpose: @held_purpose
         }) do
      {:ok, _} ->
        :ok

      {:error, why} ->
        Outcome.comment(
          card,
          "**No wait opened** for a person to decide: #{inspect_error(why)}. A person merges " <>
            "it with `slipdock verify #{card.id} accept`, or sends it back with `reject`.",
          nil,
          user
        )
    end
  end

  @doc """
  Whether `actor` may answer or skip `wait` (#1952): a held card's wait is
  a person's to answer, never an agent's. `:ok` or `{:error, message}`.
  """
  def may_close_wait(%Slipdock.Boards.Wait{purpose: @held_purpose, card_id: id}, actor) do
    if Actors.gated?(actor),
      do:
        {:error,
         "a person decides whether card ##{id} merges (its human tier is before_merge): " <>
           "an agent can't answer this wait"},
      else: :ok
  end

  def may_close_wait(_wait, _actor), do: :ok

  # A held card's wait answered (#1952): Merge queues the merge; Send back,
  # any other answer or a skip sends it back rejected, the answer the reason.
  defp held_wait_closed(wait, actor) do
    card = Repo.get!(Card, wait.card_id)
    user = wait.closed_by_id && Repo.get(Slipdock.Accounts.User, wait.closed_by_id)

    if card.verify_state == "held" and not card.completed do
      if wait.choice == 1,
        do: approve_merge(card, actor, user),
        else: send_back_held(card, wait.answer, actor, user)
    end

    :ok
  end

  # A person's decision on a held card with `slipdock verify`, REST, MCP or
  # the panel: accept merges, reject sends it back. Its open wait, if any,
  # is withdrawn, as the decision answers it.
  defp held_decision(card, decision, reason, actor, user) do
    cond do
      Actors.gated?(actor) ->
        {:error, :forbidden,
         "card ##{card.id} is held for a person: its human tier is before_merge, " <>
           "so a person merges it or sends it back"}

      decision == "reject" and reason == "" ->
        {:error, :unprocessable_entity, "sending it back needs its reason"}

      true ->
        withdraw_held_wait(card, actor)
        card = Repo.get!(Card, card.id)

        if decision == "accept",
          do: approve_merge(card, actor, user),
          else: send_back_held(card, reason, actor, user)
    end
  end

  defp withdraw_held_wait(card, actor) do
    case Slipdock.Boards.Waits.current_wait(card) do
      %{purpose: @held_purpose} ->
        Slipdock.Boards.Waits.withdraw_wait(card, actor,
          note: "Decided on the card, so the wait is closed."
        )

      _ ->
        :ok
    end
  end

  # Merge: the card is merging and its merge job queued, as an acceptance
  # without the tier does.
  defp approve_merge(card, actor, user) do
    with {:ok, card} <-
           Slipdock.Boards.Cards.update_card(card, %{"flags" => card.flags -- ["review"]},
             actor: actor,
             by: user,
             verify_changes: [verify_state: "merging"]
           ) do
      Outcome.comment(
        card,
        "**Merge approved** by #{Actors.who(actor, user)}; merging " <>
          "#{card.evidence_pr || "its pull request"}.",
        nil,
        user
      )

      Merging.queue_merge(card, user)
      {:ok, Repo.get!(Card, card.id)}
    end
    |> Outcome.api_error()
  end

  # Send back: rejected, the person's reason the failing part (the ask, as
  # the person judged it), and back to the ready list as any rejection.
  defp send_back_held(card, reason, actor, user) do
    reason =
      case Util.blank_to_nil(reason) do
        nil -> "sent back before merging by #{Actors.who(actor, user)}, with no reason given"
        why -> why
      end

    {:ok, checks} = Slipdock.Verified.Checks.parse(["ask=misses:" <> one_line(reason)])

    apply_decision(
      card,
      "reject",
      %{reason: "Sent back before merging: " <> reason, commit: "", checks: checks},
      actor,
      user
    )
  end

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.slice(0, 500)

  # Accepted on a board that ships by pull request: the card waits, merging,
  # while a runner merges its pull request; the merge finishing completes it.
  defp accept_to_merge(card, note, commit, checks, actor, user) do
    changes = [
      verify_checks: checks,
      verify_state: "merging",
      verify_by: Actors.actor_map(actor),
      verify_note: Util.blank_to_nil(note),
      verify_commit: Util.blank_to_nil(commit),
      verify_at: Util.now()
    ]

    with {:ok, card} <-
           Slipdock.Boards.Cards.update_card(card, %{"flags" => card.flags -- ["review"]},
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      Outcome.comment(
        card,
        "**Accepted** by #{Actors.who(actor, user)}; merging #{card.evidence_pr || "its pull request"}.",
        Outcome.with_parts(note, checks),
        user
      )

      Merging.queue_merge(card, user, decider: Jobs.decider_runner(actor))
      {:ok, Repo.get!(Card, card.id)}
    end
    |> Outcome.api_error()
  end

  defp commit_matches?(a, b) do
    a = String.downcase(a)
    b = String.downcase(b)
    String.starts_with?(a, b) or String.starts_with?(b, a)
  end
end
