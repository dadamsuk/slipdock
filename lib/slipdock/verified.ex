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
      it in `evidence_pr`, which a board asking for evidence requires. A
      card that changes no code names why in `evidence_no_code` instead
      (#1938), and accepting it merges nothing.
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

  This module is the door: every function is called here, and the code
  behind each is in a module under `Slipdock.Verified`, by what it does.
  `Gate` holds the checks on a write, `Decisions` the accept, reject and
  hold of a submitted card, `Merging` the merge of an accepted one,
  `Audits` the audits and their rework, `Prompts` and `DocsPlaces` what a
  verify or audit job is told, `Jobs` the queueing of those jobs,
  `Shipping` what a builder is told, and `Evidence`, `Epics`, `Rejections`
  and `Actors` what the others read off a card.
  """

  alias Slipdock.Verified.{
    Actors,
    Audits,
    Decisions,
    DocsPlaces,
    Epics,
    Evidence,
    Gate,
    Jobs,
    Merging,
    Prompts,
    Rejections,
    Shipping
  }

  ## Who did it (`Slipdock.Verified.Actors`)

  @doc "Whether the checks apply to a change made by `actor`."
  defdelegate gated?(actor), to: Actors

  @doc """
  The actor the server accepts an unverified card as (#1953): not a person,
  so a `before_merge` tier still holds it, and not an agent, so no audit
  samples it.
  """
  defdelegate server_actor(), to: Actors

  @doc """
  Whether two actors (`Slipdock.Actor` maps, as stored or as built) are the
  same one: the same kind, person, token label and runner job. Two runner
  jobs, two tokens, or a person and an agent are different.
  """
  defdelegate same_actor?(a, b), to: Actors

  @doc """
  Who an actor stored on a card (`verify_by`, `verify_submitter`) was, in
  words: an agent by its token's label, a person by their name.
  """
  defdelegate who(actor), to: Actors

  @doc """
  The person behind an actor stored on a card, when it was a person whose
  account still exists: nil for an agent, a deleted account or nobody. The
  card panel uses it to show their email and offer a note or an assignment.
  """
  defdelegate person(actor), to: Actors

  ## The checks on a write (`Slipdock.Verified.Gate`)

  @doc "Whether `board` has any of the switches on, and which."
  defdelegate switches(board), to: Gate

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
  defdelegate check_update(card, attrs, actor), to: Gate

  @doc """
  The message an agent gets setting `card`'s profile to `new` (nil or ""
  clears it), or nil when it may. On a board with profiles on, once the card
  has been started or a person set its profile, an agent may keep the
  profile or raise it to a stricter one (`Slipdock.Profiles.rank/1`), never
  lower or clear it: the profile decides how the work is checked and who
  must look before it merges. A person can do either.
  """
  defdelegate profile_message(card, new, actor), to: Gate

  @doc """
  `:ok`, or `{:error, message}` when `actor` may not move `card` into `to`:
  an agent taking a completed card out of a done list (on any board),
  starting work on a card with no bar on a board that asks for one,
  completing one by a move while its sub-board has open cards (on any
  board), or with no evidence on a board that asks for it.
  """
  defdelegate check_move(card, to, actor), to: Gate

  @doc """
  After `card` has moved into `to`: the bar locks when work starts, if it is
  written and the board asks for one.
  """
  defdelegate moved(card, to), to: Gate

  @doc """
  The checks of a move into `column`, for a card being created there (#1815):
  `changeset` (a new card's) with a `bar` error when `actor` (an agent) may
  not start work on it, because the list is a doing list, the board asks for
  a bar and the card has none; else with the bar locked, as a move into the
  list would lock it.

  Created finished (#1918), in a done list or with `completed` set, the card
  meets what an agent completing it would: on a board that verifies work it
  is refused (a submission needs a card to submit; a board that ships by
  pull request always verifies), and on one that asks for evidence it needs
  some. A changeset already invalid, or for any other list, comes back as
  it was.
  """
  defdelegate check_create(changeset, column, actor), to: Gate

  @doc """
  The message an agent gets reopening `card`, or nil when it may. On every
  board, an agent can't untick a completed card or move it out of a done
  list into one that isn't: nothing an agent does needs it (a rejection
  comes before Done, a retry only puts back a card left in progress, and a
  recurring card is copied), and a script that does it undoes finished work.
  Reopening is a person's call.
  """
  defdelegate reopen_message(card, actor), to: Gate

  @doc """
  The message an agent gets moving a completed `card` out of a done list
  into `to`, which isn't one, or nil when it may.
  """
  defdelegate reopen_move_message(card, to, actor), to: Gate

  @doc """
  The message an agent gets moving a card into a done list with no evidence
  on a board that asks for it, or nil when it may.
  """
  defdelegate check_done_move(card, to, actor), to: Gate

  @doc """
  The raise an agent's completion of `card` with `attrs` makes to its
  profile (#2017): `%{profile: raised, from: before, why: reason}`, or nil.
  Only on a board with profiles on, when the completion carries the actual
  change (`changed_lines`, the lines it adds and removes, and
  `changed_files`, the paths it touches), read by
  `Slipdock.Profiles.recheck/4` against the card's profile: the one the
  write sets, else the card's, else the one its paths and tags infer.
  Never lower. A person, a rule or the assistant completing it raises
  nothing.
  """
  defdelegate profile_raise(card, attrs, actor), to: Gate

  @doc "The activity line for a raise from `profile_raise/3`."
  defdelegate raise_text(raise), to: Gate

  @doc """
  After a write changed `card`'s assignees from `before` to `now`, by
  `actor`: keeps `agent_assignee_ids`, the people an agent put on it. An
  agent's additions join it; whoever is taken off leaves it; a person (or
  the assistant, or a rule) adding someone makes that one theirs. A
  rejection takes off whoever is still on the list (`decide/5`).
  """
  defdelegate assigned(card, before, now, actor), to: Gate

  ## Evidence (`Slipdock.Verified.Evidence`)

  @doc """
  Whether `card`'s evidence says it changes no code (#1938): it gives a
  reason in `evidence_no_code` and names no pull request. A sweep, a
  handbook reconcile or any read-and-file card has no branch and no pull
  request, so on a board that ships by pull request it completes without
  one, and accepting it merges nothing.
  """
  defdelegate no_code?(card), to: Evidence

  @doc "Whether `evidence` is a bare `-` once trimmed (#2091)."
  defdelegate dash?(evidence), to: Evidence

  @doc "Whether `card` carries any evidence (or would, with `attrs`)."
  defdelegate evidence?(card), to: Evidence
  defdelegate evidence?(card, attrs), to: Evidence

  @doc """
  A card's evidence as Markdown (#1632, #1623): what was checked, then the
  commit and branch, the suite's result and the test files.
  """
  defdelegate evidence_text(card), to: Evidence

  @doc "A suite's result in words: `passed (38 passed, 0 failed)`."
  defdelegate suite_text(suite), to: Evidence

  ## Subcards and epics (`Slipdock.Verified.Epics`)

  @doc """
  The cards still open on `card`'s sub-board, as `{id, title}` in id order:
  not completed, not archived and not submitted for verification (pending,
  or accepted and merging or held for a person, #1952, which is the
  verifier's or the person's to finish). A subcard
  that is complete counts as done whatever its own sub-board holds. An
  archived sub-board, or none, has none.
  """
  defdelegate open_subcards(card), to: Epics

  @doc """
  Whether `card` is an epic (#1917): its sub-board, not archived, holds a
  card that isn't archived. On a board that ships by pull request each
  subcard ships its own pull request, so an epic needs none of its own.
  """
  defdelegate epic?(card), to: Epics

  @doc """
  Whether accepting `card` on a board that ships by pull request has
  nothing to merge (#1917): it is an epic, and it names no pull request, or
  one a subcard of it already merged (an accepted, completed subcard with
  the same `evidence_pr`). Such an epic completes on acceptance, as on a
  push board; an epic naming a pull request of its own still merges it.
  """
  defdelegate nothing_to_merge?(card), to: Epics

  ## Shipping by push or pull request (`Slipdock.Verified.Shipping`)

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
  defdelegate released?(card), to: Shipping
  defdelegate released?(card, board), to: Shipping

  @doc "The branch a card's work goes on when its board ships by pull request (#1655)."
  defdelegate pr_branch(card), to: Shipping

  @doc """
  What the builder of `card` is told when its board ships by pull request
  (#1655), or nil when it ships by push: never push the default branch,
  push `card-<id>` and open (or update) the pull request, and name it when
  completing. Said in a claimed job's prompt and in the card's JSON, so a
  runner or an older skill needs nothing else to know.

  A spike (`Slipdock.Profiles.spike?/1`, #2351) gets `spike_note/1`
  instead, on any board: its code is never merged.

  A card tagged `security` (see `neutral?/1`, #1794) gets a neutral pull
  request instead: the repository may be public, and a PR describes the
  hole for anyone to read before the fix deploys. Its title is
  `neutral_pr_title/1`, never the card's; its body is only the card id,
  never `--fill` from the commits; and the builder is told to keep the
  commits, title and body to a neutral description of the change.
  """
  defdelegate ship_instructions(card), to: Shipping

  @doc """
  The ship instructions' line on a board with profiles on (#2017): give the
  change with the completion, so the profile is checked against it. Empty
  (no line) with profiles off.
  """
  defdelegate profiles_note(card), to: Shipping

  @doc """
  What the builder of a spike is told (#2351), on any board: a spike
  answers a question by building, and its code is never merged. Build the
  prototype on `card-<id>` and push it, never a pull request or the default
  branch; write the answer page and pin it to the epic; complete with
  `--no-code` naming the page and the branch.
  """
  defdelegate spike_note(card), to: Shipping

  @doc """
  Where the builder finds the project's pre-push checks (#1878): the
  handbook's Before you push section when the board's handbook has one,
  then the project's own docs, then formatting and a compile that fails on
  warnings.
  """
  defdelegate pre_push_checks(card), to: Shipping

  @doc """
  What the builder on a pull request board is told about a card that
  changes no code (#1938): no branch, no pull request, never a token one;
  complete it with the reason instead, and accepting it merges nothing.
  """
  defdelegate no_code_note(card), to: Shipping

  @doc """
  What the builder of an epic on a pull request board is told (#1917):
  its subcards ship their own pull requests, so once they are all accepted
  and merged the epic completes without `--pr`, and accepting it merges
  nothing. A pull request of its own is only for work done on the epic
  itself.
  """
  defdelegate epic_note(card), to: Shipping

  @doc """
  Whether `card`'s pull request is to be neutral (#1794): it is tagged
  `security`. Its tags are loaded if they aren't.
  """
  defdelegate neutral?(card), to: Shipping

  @doc "The pull request title a security card gets (#1794): its id and nothing else."
  defdelegate neutral_pr_title(card), to: Shipping

  ## Deciding a submitted card (`Slipdock.Verified.Decisions`)

  @doc """
  After `before` has been saved as `updated`: a card completed (or submitted
  for verification) with evidence on a board that asks for it gets the
  evidence as a comment, by `user` — once: not again when it is accepted.
  """
  defdelegate saved(before, updated, user), to: Decisions

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
  defdelegate decide(card, decision, params, actor, user), to: Decisions

  @doc """
  A wait closing (`Slipdock.Boards.Waits.answer_wait/3`): a rejection-limit wait
  (#1779) answered *Accept as is* accepts the card for whoever answered (on
  a pull request board, queueing the merge); any other answer, or a skip,
  sends it back for rework as rejected, its evidence cleared. Other waits
  are left alone.
  """
  defdelegate wait_closed(wait, actor), to: Decisions

  @doc "The purpose of the wait a held card's acceptance opens (#1952)."
  defdelegate held_purpose(), to: Decisions

  @doc "The `purpose` of the wait a card over its rejection limit opens."
  defdelegate limit_purpose(), to: Decisions

  @doc """
  Whether an agent's acceptance of `card` waits for a person before its
  pull request merges (#1952): an agent decided, and the card's human tier
  (`Slipdock.Profiles.tier/1`) is `before_merge`. A person's acceptance is
  a person's look already.
  """
  defdelegate hold_for_a_person?(card, actor), to: Decisions

  @doc """
  Whether a card just submitted for verification goes unverified (#1953):
  its board has profiles on and its profile (set, else inferred) is one of
  `unverified_profiles/0`. No verify job is queued; the server accepts it
  itself (`accept_unverified/2`). The bar is still required and locked.
  """
  defdelegate not_verified?(card), to: Decisions

  @doc "The profiles whose cards no verify job checks: `docs`."
  defdelegate unverified_profiles(), to: Decisions

  @doc """
  Whether `actor` may answer or skip `wait` (#1952): a held card's wait is
  a person's to answer, never an agent's. `:ok` or `{:error, message}`.
  """
  defdelegate may_close_wait(wait, actor), to: Decisions

  ## Rejections (`Slipdock.Verified.Rejections`)

  @doc """
  The verdict a pending card's submission follows (#1944): the last
  decision's parts and the commit they judged, `%{checks, sha, reason,
  rejections, accepted}`, when the card was decided before (a rejection, or
  an acceptance whose merge failed) and that verdict named its commit. nil
  for a first submission, or a verdict kept without its commit.
  """
  defdelegate previous_verdict(card), to: Rejections

  @doc """
  How many rejections a card on `card`'s tree may have before the next goes
  to a person (#1779): its root board's `verify_rejection_limit`. 0 is no
  limit.
  """
  defdelegate rejection_limit(card), to: Rejections

  @doc """
  The reason a rejected card was sent back with, and who rejected it, for
  the agent taking it up again (#1659): nil unless `card` is rejected.
  """
  defdelegate rejection(card), to: Rejections

  ## Merging (`Slipdock.Verified.Merging`)

  @doc "The job kind that merges an accepted card's pull request (#1656, #1657)."
  defdelegate merge_kind(), to: Merging

  @doc """
  Queues the merge job for a card being merged (#1657), with no setting, to
  the pool `merge_pool/2` picks (`opts` go to it). With none, nothing is
  queued and the card says what to do. `{:ok, job}` or `:none`.
  """
  defdelegate queue_merge(card), to: Merging
  defdelegate queue_merge(card, user), to: Merging
  defdelegate queue_merge(card, user, opts), to: Merging

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
  defdelegate merge_pool(card), to: Merging
  defdelegate merge_pool(card, opts), to: Merging

  @doc """
  Where a card being merged stands (#1657): `:queued` or `:running` while a
  merge job is open on it, nil when it isn't merging. With none open, its
  last merge job since the acceptance says why (#2646): `:already_merged`
  when that job found the pull request merged at another head (#2637),
  `:waiting` when its runner couldn't merge here and no other runner took
  it on (#1754), and `:none` when nothing will merge it (no runner can).
  """
  defdelegate merge_status(card), to: Merging

  @doc """
  A merge job has ended (#1657), called by `Slipdock.Runners` for kind
  merge. Done: the card completes, with the merge commit as `merge_sha`,
  and moves to the done list (a pull request the runner found already
  merged at the accepted commit too, #2637). A runner that couldn't merge
  here (not the pull request's repository, no git or gh, gh signed out)
  hands it on to another runner (#1754): the card's work isn't at fault.
  One the runner found already merged at another head (or, from an older
  runner, merged at a head it didn't say) stays merging for a person, with
  a comment, and isn't a rejection (#2637). Anything else: it
  goes back to the top of the ready list as rejected, the merge's reason as
  the rejection's, so the builder rebases and submits it again. A card no
  longer merging is left alone.
  """
  defdelegate merge_finished(job, runner_name), to: Merging

  @doc """
  Whether a merge job failed because the pull request was already merged
  (#2637): at another head (the daemon's words), or at a head the runner
  didn't say (older runners: `is MERGED, not open`). Only the runner's own
  `merge:` line counts. Such a job leaves its card merging for a person
  (`merged_elsewhere`), so queuing the merge again would fail the same way:
  the health monitor's `merge_missing` flags it rather than requeuing, and
  `merge_failing` doesn't count it as a failing merge (#2759).
  """
  defdelegate already_merged?(job), to: Merging

  @doc """
  Whether a failed merge's reason (the merge job's own words) is one a
  rebase fixes (#1666): a conflict, or a head that moved after acceptance.
  """
  defdelegate rebase_fixes?(said), to: Merging

  @doc """
  The job kinds that finish a card's work rather than add to it: verifying
  and merging. Lanes and the WIP limit hold work jobs only (#1807): these
  edit nobody's files and put no more work in progress.
  """
  defdelegate finishing_kinds(), to: Merging

  ## Audits (`Slipdock.Verified.Audits`)

  @doc """
  How often `card`'s tree audits accepted work: its root board's
  `verify_audit`, 1 in N (0: never).
  """
  defdelegate audit_every(card), to: Audits

  @doc """
  Whether card `card_id` is in the sample for 1 in `n`: a hash of its id,
  so about one card in `n` is, and the same card always answers the same.
  """
  defdelegate audit_sampled?(card_id, n), to: Audits

  @doc """
  The open rework card an audit filed for `card` (#2632): open, not
  archived, caused by `card`, and filed by an audit (its description starts
  with what `file_rework/6` writes). Nil when there is none.
  """
  defdelegate open_rework(card), to: Audits

  @doc """
  Whether a disagreement's parts (#2632) make its rework urgent: a mutant
  that survived, or a `must` rule broken (a rule the handbook doesn't know
  counts as one).
  """
  defdelegate urgent_disagreement?(checks), to: Audits

  @doc "A rework card's title (#2632): the audit's reason, after the card it reworks."
  defdelegate rework_title(card, reason), to: Audits

  @doc """
  Takes down the audit alerts that name `rework` (#2691), once it is
  accepted or completed: the alert each disagreement raised about the card
  it reworks, whether it filed the rework or commented on it (`Rework
  filed: #R` / `Rework already open: #R` in its body). An alert for another
  rework of the same card, one whose rework couldn't be filed, a rule's
  alert, and any card that isn't an audit's rework are left alone. One the owner dismissed
  already goes too, unseen. Returns how many went.
  """
  defdelegate clear_audit_alerts(card), to: Audits

  @doc """
  The tree's recent audit misses (#2695): the last `limit` audit
  disagreements (`source: audit` findings on `card`'s root board) of the
  last `days` days, newest first, each `%{card_id, title, failed, at}`. The
  title is the rework card's (an older one's, or with none, what
  `rework_title/2` makes of the reason); `failed` the parts it failed, or
  nil when they weren't kept. A rework since accepted keeps its miss here:
  the miss is the lesson, not the open work.

  The window and the order go by when the disagreement happened (`at`),
  never by `updated_at`, which triage moves: when the finding was recorded,
  or the newer audit job a repeat on the same card counted in. A dismissed
  or promoted miss still counts; a merged one doesn't, as the finding it was
  merged into carries its lesson.
  """
  defdelegate recent_audit_misses(card), to: Audits
  defdelegate recent_audit_misses(card, limit), to: Audits
  defdelegate recent_audit_misses(card, limit, days), to: Audits

  ## Verify jobs (`Slipdock.Verified.Jobs`)

  @doc "The job kind a pending card is queued as (#1634)."
  defdelegate verify_kind(), to: Jobs

  @doc """
  Queues a verify job again for a card still pending verification that has
  none open (the health monitor's `verify_missing`): to its board's verify
  pool, never to the runner that built it. `{:ok, job}` or `{:error, reason}`.
  """
  defdelegate requeue_verify(card), to: Jobs

  ## The verify and audit prompts (`Slipdock.Verified.Prompts`)

  @doc """
  What an audit job's agent is told (#1780): the verify prompt's checks, with
  every rule judged (`should` too), the original verdict shown, and a
  decision that only says whether it agrees.
  """
  defdelegate audit_prompt(card, board), to: Prompts

  @doc """
  What a verify job's agent is told (#1634): the card, what it asks, its bar
  and evidence, and how to decide. Rendered when the job is queued, and
  never over the runners' prompt cap (`fit_prompt/4`; `max:` sets another
  cap, for a test).

  The verifier judges, in order (#1777): the ask (does the bar cover what
  the card asks for?), the bar, and on a board with a handbook the rules for
  the diff's paths and the closing `Handbook:` line. A rejection cites the
  check it fails: a bar item, the ask, a rule id or the Handbook line.
  """
  defdelegate verify_prompt(card, board), to: Prompts
  defdelegate verify_prompt(card, board, opts), to: Prompts

  @doc false
  defdelegate prompt_cuts(kind), to: Prompts

  @doc """
  A prompt that fits under `max` (the runners' `max_prompt`, #2705).
  `render` takes a map of cuts, `%{part => bytes to take off it}`, and
  gives the prompt. The whole prompt is rendered first; while it is over
  `max`, the next part in `order` loses what is over, with a pointer to the
  card in its place, and the prompt is rendered again. A prompt over `max`
  with every part cut is cut short itself, so a verify or audit job is never
  refused for its size.
  """
  defdelegate fit_prompt(card, order, render), to: Prompts
  defdelegate fit_prompt(card, order, render, max), to: Prompts

  @doc false
  defdelegate cut(text, remove, card), to: Prompts

  @doc """
  Whether a verifier of `card` also reviews its diff for defects (#1953):
  profiles are on for `board` and the card's profile (set, else inferred)
  is `schema` or `security`.
  """
  defdelegate defect_review?(card, board), to: Prompts

  @doc "The profiles whose verifier reviews the diff for defects."
  defdelegate defect_profiles(), to: Prompts

  @doc "The defect-review step of a `schema` or `security` card's verify prompt (#1953)."
  defdelegate defect_review_step(profile), to: Prompts

  @doc """
  Whether a verifier of `card` also mutates the change (#2354): profiles are
  on for `board`, the card's profile (set, else inferred) is `fix`,
  `feature`, `schema` or `security`, and the completion changes code (never
  a `--no-code` one). `docs` and `spike` cards get no mutation step.
  """
  defdelegate mutation_review?(card, board), to: Prompts

  @doc "The profiles whose verifier mutates the change."
  defdelegate mutation_profiles(), to: Prompts

  @doc """
  The mutation step of a verify prompt (#2354): break the change's most
  consequential lines one at a time, run only the card's tests, restore, and
  give each mutant as a part. On a `fix` card one mutation undoes the fix.
  """
  defdelegate mutation_step(card), to: Prompts
  defdelegate mutation_step(card, opts), to: Prompts

  @doc """
  The mutants a builder names in its evidence (#2635): the `mutant:...=`
  lines of `card.evidence` (a leading `- ` or `* ` bullet allowed), parsed
  as a verifier's parts are. A line that doesn't parse is left out, so a
  builder's typo never breaks the verify prompt.
  """
  defdelegate builder_mutants(card), to: Prompts

  @doc """
  What a verifier does with a bar item a later decision or rule made moot
  (#2096): the builder reads it the obvious way and says so on the card,
  rather than waiting on a person, and the verifier judges that reading.
  Noted, it is accepted on its merits; read another way without a note, it
  is a rejection.
  """
  defdelegate moot_bar_sentence(), to: Prompts

  @doc """
  What a builder is told to do with the bar at pickup, before building
  (#1883): read each part against the guide and, when one needs a person,
  ask rather than meet it some other way and leave the conflict to the
  verifier. Said in a claimed job's prompt after the bar; the guide and the
  loop and work skills say the same.
  """
  defdelegate bar_pickup_check(), to: Prompts

  @doc "What the verify and audit prompts say meets a bar item asking for a rule change (#1882)."
  defdelegate rule_proposal_sentence(), to: Prompts

  @doc "What the verify and audit prompts say a rejection never asks for (#1882)."
  defdelegate rule_rejection_sentence(), to: Prompts

  @doc """
  What the verify and audit prompts say once a rule is found broken (#2046):
  look for every other instance of the same break and name them all in one
  rejection, each with its file and line, since every round of rejection
  and rework costs the card the same whatever the fix's size.
  """
  defdelegate every_instance_sentence(), to: Prompts

  @doc """
  What the verify and audit prompts say about a rule broken only in code
  the change didn't touch (#1945): report it as `pre-existing`, never
  reject for it.
  """
  defdelegate pre_existing_sentence(), to: Prompts

  ## The docs places (`Slipdock.Verified.DocsPlaces`)

  @doc "The rule whose places the docs-places step enumerates (#2694)."
  defdelegate docs_places_rule(), to: DocsPlaces

  @doc "The seven docs places (#2694): `{name, the files to grep}` each."
  defdelegate docs_places(), to: DocsPlaces

  @doc """
  Whether `card` falls in the docs-places rule's scope (#2694), on `handbook`
  (as `Slipdock.Handbook.find/1` gives it): `:in` when its lane paths meet
  the scope of the handbook's `SPEC-10`, `:out` when they don't or the
  handbook has no such rule (or there is no handbook), and `:unknown` when
  the card has no paths, so the step is given for the diff to decide.
  """
  defdelegate docs_places_scope(card, handbook), to: DocsPlaces

  @doc """
  The docs-places step of a verify or audit prompt (#2694), for a card in
  SPEC-10's scope: enumerate the places, don't judge them. The names the
  change introduces or alters, from the diff, grepped across each of the
  seven places, and each place reported as updated, deferred to a card
  whose bar names it, n/a with why, or missing. `scope` is `:in`, or
  `:unknown` for a card with no paths (the diff's rules decide).
  """
  defdelegate docs_places_step(base, sha), to: DocsPlaces
  defdelegate docs_places_step(base, sha, scope), to: DocsPlaces
  defdelegate docs_places_step(base, sha, scope, opts), to: DocsPlaces

  @doc """
  What a builder is told about the docs places (#2694), in a claimed job's
  prompt for a card in SPEC-10's scope: the same enumeration the verifier
  runs, and a place left out goes on the deferral card's bar by name, or the
  deferral doesn't count.
  """
  defdelegate docs_places_builder(), to: DocsPlaces
end
