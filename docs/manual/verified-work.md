[Slipdock — the manual](../manual.md)

## Verified work

How this fits with runners, lanes, CI and the handbook, one card from being
written to the deploy, with who acts at each stage and where it waits for a
person, is the help page **How work flows** (`/help/agents/flow`).

A board can check what an agent says it finished. Each check is a switch
under **Verified work** on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page, off by default; with all of
them off the board behaves as it always has. The checks apply to agents (MCP,
a runner job, the API with a token, the CLI under an agent): a person
completes cards as usual, and the in-app assistant and automations are not
checked either. A card's subcards start with their parent board's switches,
and the switches travel with a board's export.

Two checks have no switch and hold on every board, because each guards
against a contradiction rather than asking more of an agent:

- **No epic done over open subcards.** An agent completing (or submitting)
  a card while its sub-board has open cards is refused, and the refusal
  names them (`#12 Foo, #13 Bar are still open`). One awaiting verification
  counts as finished.
- **Done stays done.** An agent can't reopen a completed card: unticking it
  (`slipdock undone`) or moving it out of the done list (`slipdock move`,
  MCP `move_card`), on its own board or to a list on another board that
  isn't a done list (`slipdock move ID COL --board B`), is refused (`422`),
  and the card stays done. Nothing in a pass needs it — a rejection comes
  before Done, a retry only puts back a card left in progress, a recurring
  card is copied — and a script that does it undoes finished work. A person reopens a done card; moving it
  from one done list to another (another board's included), or editing it,
  is still an agent's to do.

### The bar

**A bar before work starts** (`slipdock set-board B --bar-required`,
`PATCH /api/boards/:board {"bar_required": true}`) asks for each card's
**bar**: what done means for it, written before work starts. It is the
**Bar** field on the card (shown on a board with the switch on, or on any
card that has one), `slipdock edit 12 --bar "…"`, `PATCH /api/cards/:id
{"bar": "…"}` or MCP `update_card`'s `bar`, up to 4000 characters.

- An agent moving a card with no bar into an in-progress list is refused
  (`422`), and the card stays where it was. So is an agent creating one
  straight into an in-progress list with no bar (`slipdock add --column`,
  `POST /api/boards/:board/cards`, MCP `create_card`): no card is made.
- The bar **locks** the first time the card enters an in-progress list with
  one written (`bar_locked_at` on the card, a *locked* badge on the field),
  by a move or by being created there.
  After that an agent changing it is refused; a person still can.
- A person changing a locked bar is a line in the board's activity
  (*changed the locked bar of …*), as setting or clearing one is.
- A runner job's prompt, as `claim_job`, `slipdock claim-job` and the shell
  runners receive it, ends with the card's bar when it has one, whether or
  not the board asks for one.
- Moving the card back to a ready list leaves the bar locked: work started
  once, and the bar is what it was measured against.
- Turn the switch off and a locked bar is anybody's to change again.
- A written bar is shown as Markdown (#3001), usually a numbered list of its
  parts. Click it, or **Edit**, to change it; **Done** or Escape shows it
  again. An empty bar shows its box straight away.
- **Checked at pickup.** The job's prompt (and the guide and the skills)
  tells the builder to read each part of the bar before building, and to
  ask with a wait when one needs a person (a handbook rule added, reworded
  or dropped, a merge, a deploy to prod, applying a proposal), rather than
  meet it some other way and leave the conflict to the verifier. The card
  waits until you reword the bar or confirm the alternative.
- **Write a bar that can be met.** A rule change is phrased as "proposed as
  a garden proposal (rule id, wording)", never "W-x has rule Y": a rule is
  yours to apply, and an agent only proposes it. Likewise "pull request
  open, its CI green" rather than "merged".

### Evidence

**Evidence on completion** (`slipdock set-board B --evidence-required`,
`PATCH /api/boards/:board {"evidence_required": true}`) asks an agent
completing a card for what it checked — the tests it ran and their result,
what it looked at — and, when there is one, the commit it checked at:
`slipdock done 12 --evidence-commit abc1234 --evidence -` (the evidence on
stdin), MCP `complete_card`'s `evidence` and `commit`, or `PATCH
/api/cards/:id {"completed": true, "evidence": "…", "evidence_commit":
"abc1234"}`.

**Evidence and a reason are lines, not a paragraph.** A first line that
stands alone, a blank line, then one short line per point; the parts go in
their fields (the evidence's `--evidence-commit`, `--branch`, `--tests`,
`--suite` and `--pr`, a verdict's `--check`), not repeated in the text.
The card panel shows the evidence, its *No code* reason and a verdict's
reason as Markdown (#3001), so a list reads as a list. Comments keep a
single line break, so the shape survives as written, but words on the
command line lose their breaks: send it on stdin with a quoted
heredoc, `--evidence -` or `--reason -`:

```sh
slipdock done 12 --evidence-commit abc1234 --suite passed:38:0 --evidence - <<'EOF'
Built and tested; CI green.

- the export keeps archived cards (`Export.run/1`)
- Handbook: updated W-3 §Exports
EOF
```

- Evidence can also come in parts the server checks the shape of (not the
  truth): `--branch main`, `--tests test/a_test.exs,test/b_test.exs` (the
  test files added or changed) and `--suite passed:38:0` (the suite's
  result, then how many passed and failed). Over MCP these are
  `complete_card`'s `branch`, `tests` and `suite` (`{"result": "passed",
  "passed": 38, "failed": 0}`). Over the API they are `evidence_branch`,
  `evidence_tests` and `evidence_suite`. Any one of them counts as
  evidence.
- Completing with none of it (in the same write or already on the card),
  moving the card into a done list without it, or creating a card already
  done without it (`slipdock add --column Done`, or `"completed": true` on
  `POST /api/boards/:board/cards`), is refused (`422`, naming the fields
  that would do). MCP `create_card` takes no evidence, so an agent creates
  the card in another list and completes it.
- Evidence that is a bare `-` (once trimmed) is refused for agents, on any
  board (`422`, saying the evidence was a bare dash): it is what a client
  that doesn't read stdin sends for `--evidence -`, so whatever was piped in
  never arrived. Pass the text itself, or pipe it with `--evidence -` from a
  CLI that reads stdin. Evidence that merely starts with a dash (`- Handbook:
  …`) goes through.
- A card's description or bar that is a bare `-` is refused the same way
  (`422`, on a create or an update, naming the field): it is what a client
  that doesn't read stdin sends for `--desc -` or `--bar -` (a `slipdock`
  from before those read stdin), and the card would be left with a dash for
  a body. Pass the text itself, or pipe it (`slipdock add … --desc - <<'EOF'`)
  from a CLI that reads stdin. A person's own write is never refused, and
  text that merely starts with a dash (a Markdown list) goes through.
- An agent's verdict whose reason is a bare `-` is refused the same way
  (`422`), on accept, reject, agree and disagree: the reason piped to
  `--reason -` never arrived, and the card stays as it was rather than
  carrying a dash for a reason. A person is never refused.
- The evidence shows on the card (**Evidence**, with the commit, branch,
  suite and test files) and in
  `slipdock card`, and is posted as a comment when the card completes.
- Reopening the card clears it, so the next completion brings its own; the
  comment stays.

### A second agent verifies

**A second agent verifies** (`slipdock set-board B --verify-work`,
`PATCH /api/boards/:board {"verify_work": true}`) makes an agent's
completion a **submission**. The card stays open in its list, flagged
*needs review*, with `verify_state: "pending"`, and it isn't done until
someone else decides. An agent can't skip the submission by creating a card
already done (in a done list, or completed): that is refused (`422`, MCP
tool error), and the card is made in another list and completed instead. The card shows **Awaiting verification**, who
submitted it, and **Accept** and **Reject** for anyone who can edit it.

- **Accept** (`slipdock accept 12`, or `slipdock verify 12 accept`; MCP `verify_card`;
  `POST /api/cards/:id/verify {"decision": "accept"}`) completes the card
  and moves it to the done list. An optional reason is kept as a note, and
  `--evidence-commit` / `commit` records the commit it was checked at. When
  the card has evidence for a commit, a different commit is refused.
- **Reject** (`slipdock reject 12 --reason -`, the reason on stdin as
  lines) needs the reason.
  The reason is posted as a comment and shown in the card's verification
  block while it is rejected; the handoff only points there (*Rework:
  rejected by …, reason under Verification*). An agent taking the card up
  again gets the reason in its job's prompt and in `get_card`
  (`rejection`). The evidence is cleared, the assignment the building agent
  made comes off (one a person made stays), and the card goes back to the
  top of the ready list. The feed's cool-down doesn't hold it, so a runner
  rule sends it next, and completing it submits it again. The card counts
  its rejections (*rejected 2×*, `verify_rejections`).
- **The verdict in parts.** A verifier gives what it found for each check
  as well as the reason, and the reason is lines, its parts left to
  `--check`:

  ```sh
  slipdock verify 12 reject --check ask=ok --check bar:1=ok \
    --check bar:2=fail:"no footer" --reason - <<'EOF'
  bar 2: the page has no footer

  - `Layout.page/1` renders the header only
  - no test looks for the footer
  EOF
  ```

  (repeat `--check`, or `--checks-file F`, one per line), MCP
  `verify_card` `checks`, or `"checks": [...]` on the REST call. The parts
  are `ask=ok|misses`, `bar:<n>=ok|fail`, `suite=<passed>:<failed>`,
  `rule:<id>=ok|broken|n/a|pre-existing` and `handbook_line=ok|disputed`, each with
  `:<why>` if it needs one. **A rejection names every instance found**:
  once the verifier finds a rule broken, it looks for every other instance
  of the same break the card could have missed (the same list, the same
  string, the same door) and gives them all in one rejection, one
  `rule:<id>=broken:<file>:<line>` line per instance (`--check
  rule:SPEC-10=broken:README.md:40 --check
  rule:SPEC-10=broken:docs/manual.md:12`, then `:why` if it needs one),
  never the first now and the next in another round. A rule broken in
  several places is one failing part, and its instances are listed under
  the rule on the card, in `slipdock card` and in the rejection's comment.
  A rejection has to name a failing part (an
  agent's reason that starts `bar 2:`, `the ask:`, a rule id or `Handbook
  line:` counts). An acceptance with any failing part is refused, except a
  missed `should` rule. The parts are kept on the card (`verify_checks`),
  listed under its verification block and in `slipdock card`, and written
  into the decision's comment. A later decision replaces them.
- **Rule hits on code the change didn't touch are reported, not
  rejected.** A rule broken only in lines the diff didn't change isn't the
  builder's: the verifier gives it as `--check
  rule:UX-4=pre-existing:lib/card.ex:42` (the file and line where it is
  broken, then `:why` if it needs one). It is never a rejection: a
  rejection naming only such parts is refused, and an acceptance may carry
  them. Each is kept as a `rule` finding on the card (source
  `verification`), once per part, and shown under Verification with its
  own mark (an archive box on the card, `○` in `slipdock card`), apart from
  the parts that passed and failed.
- **The prompt always fits.** A verify or audit job's prompt is never
  refused for its size. When the card's evidence, its last verdict's parts
  and reason, its description, its bar and the board's audit misses would
  take it over the runners' 20,000-byte cap, they are cut short in that
  order, each with a pointer to the card, where the whole text is.
- **A resubmission is judged on what changed.** When a rejected card is
  submitted again, its verify job's prompt carries the last verdict and
  the commit it judged. The verifier judges the parts that failed and any
  part the commits since touch, and carries the rest: a part that passed
  then and isn't judged again (`--check bar:1=carried`, or left out) is
  kept, shown as *carried from abc1234* on the card and in `slipdock card`.
  A part that failed can't be carried, and an acceptance is still refused
  when a part it judges fails. The verifier is told not to raise a passed
  or fixed part again, to flag a class of problem once (under the one
  rule, a `rule:<id>=broken:<file>:<line>` line for every instance it
  finds, all in this rejection), and to say what changed since the last
  rejection. So the builder's new evidence names the
  rejected commit and what changed since. An audit judges every part and
  carries nothing.
- **A card going round in circles is yours to look at.** A card's second
  rejection, or a rejection for a rule id an earlier one named (`UX-4`
  failing again), fires on the spot, not on the gardener's schedule: the
  card stays flagged **review** until it is accepted (a rejection otherwise
  takes the flag off), a *Going round in circles* comment lists how many
  rounds it has had and the parts each failed, a warning alert goes up on
  the board, and you (and the people `release` questions go to) are
  emailed. It comes first in My work's *Waiting on you* and in `slipdock
  work`, whatever its age, and counts in `slipdock whoami`'s waiting. The
  runners still take it for rework: the flag asks you to look at whether
  the card needs a different approach or a reworded bar. Taking the flag
  off says you've seen it. A failed merge counts towards the two (not one
  that finds the pull request already merged); only a verifier's rejection
  fires it.
- **Too many rejections go to a person.** **Rejections before a person
  decides** (`slipdock set-board B --verify-rejection-limit 2`, `PATCH
  /api/boards/:board {"verify_rejection_limit": 2}`; 2 by default, 0 never)
  is how often a card may be rejected. The rejection after that still goes
  back to the top of the ready list, but its evidence is kept, a comment
  lists every rejection's reason, and a wait opens on the board's owner
  with two choices. The comment and the wait list the parts that failed in
  each rejection and say the approach may be wrong, not the fix, so it is
  read as a decision rather than another retry. The card is flagged `waiting`, so no runner rule sends
  it. You can edit its bar before you answer. *Rework as rejected* (or any
  other answer, or skipping) clears the evidence and lets the runners take
  it again. *Accept as is* accepts it in your name, and on a pull request
  board merges it.
- **Audits check the checker.** **Audit 1 in N accepted cards**
  (`slipdock set-board B --verify-audit 10`, `PATCH /api/boards/:board
  {"verify_audit": 10}`; 0, the default, audits none) picks about one card
  in N that an agent accepted, by a hash of its id, and queues it to the
  verify pool again: a `verify` job marked `audit` (`"audit": true` in the
  job's JSON). Neither the runner that built it nor the one that verified
  it takes the audit. On a pull request board the audit is queued once the
  pull request has merged. Its prompt shows the original verdict, reason and
  parts, and asks for every rule to be judged, `should` rules too. An audit
  changes nothing on the card: its agent answers `slipdock verify 12 agree` or
  `disagree --reason -` (the reason on stdin as lines, its first line the
  one the rework card is titled from, with `--check` parts, as a verifier
  does), which
  posts a comment. The acceptance stands either way: the work has shipped,
  so a disagreement files the rework itself. It makes one card in the
  accepted card's board's ready list, titled *Audit of #12: …* from the
  audit's reason. Its description is the reason, the parts that failed and a link to the audit's comment; its
  paths are the accepted card's; it names the accepted card as its cause,
  so it counts as an incident of it; and its priority is *high* when a
  mutant survived or a `must` rule is broken, *medium* otherwise. The
  alert raised for the board's owner and the `audit` finding name that
  card, and the alert clears itself once that rework card is accepted or
  completed (on a pull request board, accepted to merge). A second
  disagreement on the same card, while that rework card is still open,
  comments on it instead of making another, and leaves the first alert in
  place: both clear with the rework. An audit that agrees files nothing.
  The misses feed back to the verifiers: on a tree with audits on, the
  verify prompt carries *What audits on this board caught recently*, the
  last five audit disagreements of the last 30 days, newest first, each the
  rework card's title and the parts it failed (kept on the `audit`
  finding), and tells the verifier to check those first. A miss whose
  rework has since been accepted stays on the list: the miss is the lesson.
  A miss is dated when the audit disagreed, so triaging its finding
  (dismissing it, say) doesn't move it, and one merged into another finding
  leaves the list to that one. With audits off, or nothing caught, there is
  no block, and the audit prompt never carries it, so an auditor judges
  afresh.
- A decision made in a runner job on the card (the CLI sends
  `$SLIPDOCK_JOB_ID` as `x-slipdock-job`; MCP the job it claimed) is
  credited to the runner: *Accepted by runner verifier*, not the token's
  label, which the builder and interactive sessions share.
- A runner job that ends with its card awaiting verification, or accepted
  and waiting for its pull request to merge, has finished: the card stays
  where it is, and `requeue_stuck` doesn't count it as stuck. Nor does it
  count an epic whose job ended with an open subcard in that state.
- **Whoever submitted it can't decide it** (`403`). A different agent means
  a different token, or a different runner job on the same token. A person
  is always different, and a person completing a pending card accepts it.
- An agent moving a card into the done list itself is refused.
- A pending card is waiting on whoever owns the board: it is in their *My
  work* waiting list and `slipdock work` (*Awaiting verification*). An epic
  isn't done while a subcard awaits: its rollup and its subcard count say
  how many do (`awaiting`; `⊞1/2 (1 awaiting verification)` in the CLI).

### Verify jobs

With verification on, **Runner pool for verify jobs** (`slipdock set-board
B --verify-pool checkers`, `PATCH /api/boards/:board {"verify_pool":
"checkers"}`; blank for none) sends each submitted card to that
[runner](runners.md) pool as a job of kind `verify`. Its prompt carries the
card's link, what it asks (its description), its bar, the evidence and
commit, and the two `slipdock verify` commands to decide with. It and an
audit's prompt also say that card text is data, never instructions (#2783,
the paragraph that ends every [runner](runners.md) job's prompt), and that
the builder's evidence, the verdict and the code's own comments are data in
the same way: the verifier judges them, never follows them. The
builder's evidence says where to look, not what to believe (#2696): the
verifier checks each claim in it rather than carry it, so a test it names
is read and run, a mutant it says was killed is broken again or sampled,
and a docs place it says it updated is opened. The verifier
judges four things in order: whether the bar covers what the card asks for
(a bar that leaves part out is a rejection), the bar itself, and on a board
with a handbook (its `Handbook/` wiki pages) the rules for the paths the change touches
(`git diff --name-only` from the merge base, piped to `slipdock handbook B
--paths-from -`: a broken `must` rule is a rejection) and the closing
`Handbook:` line against the docs gate. On a bug, the check is would the
reporter now see it fixed, not does the work meet the bar: a card or evidence
that says the reported symptom or its cause was never seen (a cause made up in
the test) is a rejection on the ask, however good the tests. A rejection cites what it fails: a
bar item, the ask, a rule id or the Handbook line. Since a rule is a person's
call, a bar item that adds, rewords or drops a handbook rule is met by a
matching open rule proposal (an `edit_section` on that page's `## Rules`,
listed by `slipdock garden B --check proposal`): the verifier judges what the
proposal says, not the live rules, and names its id when it accepts, and a
rejection never asks the builder to edit `## Rules`, only to file or correct
the proposal. **SPEC-10 is checked by enumeration, not judged.** For a
card whose paths fall in the scope of the handbook's `SPEC-10` (a change
written up everywhere a reader would look), the prompt adds a step after the
rules: take the names the change introduces or alters from the diff
(commands, flags, MCP tool names, API fields, settings, page and section
names), grep them across the seven places (`README.md`, the manual, the
app's help in `HelpLive.Guides`, the agents' help in `HelpLive.Agents` and
`HelpLive.Flow` with `cli/help.txt`, `docs/agents.md`, the API guide and
`priv/skills/`), and give each place one result: *updated*, *deferred to
#N* (only when card #N's bar names that place), *n/a* with why, or
*missing*. One missing is `--check rule:SPEC-10=broken:<file>:<name>`; a
deferral to a card whose bar doesn't name the place counts as missing. The
builder's claimed prompt gives it the same enumeration, and tells it to
list each place its lane can't reach on the deferral card's bar. A card
outside the scope, or a handbook with no `SPEC-10`, gets neither. An audit
judges it the same way. On a card that gets the
[mutation step](profiles.md) (a `fix`, `feature`, `schema` or `security`
card, with profiles on) the verifier breaks 3 to 5 of the most
consequential lines the diff added or changed and, on top of those, every
guard or branch the diff adds (a new condition, clause, pattern match or
early return), once each and named with its line; a survivor on any of
them is a rejection. The mutants the builder names in its evidence are a
map: one it says was killed is carried only when the verifier broke it
again or a test the builder names plainly covers that line. An audit
asks for the same guard mutants and carries none. It also asks the agent to say where it is at each
step with `slipdock job-progress --step "…"` (checked out the commit, tests
running, tests passed or failed with counts, judging against the bar, the
decision), and never with a note: the steps show against the job on the
Runners panel, in `slipdock job` and `slipdock jobs`, and in the job's JSON,
and the card gets no comment until the decision. The agent that runs it is in a different runner job
from the one that did the work, so it counts as a second agent even on the
same runner token.

On a board that [ships by pull request](#shipping-by-pull-request), the
prompt doesn't ask for the suite again: the pull request's CI has run it at
that commit. The agent reads the change and the tests the card names,
checks that the pull request's head is the submitted commit and that every
check passed (waiting for any still running, rejecting on a failed one, by
name), and reports *CI: 41 checks passed at abc1234* in place of the test
steps. A pull request with no checks has the suite run as before. A
verifier on such a board needs git, `gh`, its agent and the CLI, but not
the project's toolchain.

- **The runner that built the card never takes its verify job**: the
  runner of the job the submission came from, or else the last runner to
  take a job on the card. When it is the only runner in the pool, or the
  pool has none yet, the job waits and the card says why in a comment. Add
  a runner to the pool, or verify it by hand.
- Whoever decides first decides: the other verify jobs still open on the
  card are cancelled, and a person completing the card cancels them too.
- Each new submission (after a rejection, say) queues a fresh job.
- A job the queue won't take (it is full, or over its rate) is said on the
  card as a comment, and the card waits for someone to verify it by hand.
- A machine's runner takes `verify` jobs with the same agent as its own
  kind, on the server's prompt alone: it adds no standing instructions to a
  `verify` job, since its agent checks the work rather than doing it.

### Shipping by pull request

With verification on, **Ship accepted work by** (`slipdock set-board B
--ship-via pull-request`, `PATCH /api/boards/:board {"ship_via":
"pull_request"}`, MCP `update_board` `ship_via`) chooses how an agent's
work reaches the default branch, and so the deploy:

- **Push** (the default): the agent pushes the default branch, as before.
  Nothing else on this page changes.
- **Pull request**: the agent never pushes the default branch. It pushes a
  `card-<id>` branch, opens a pull request, and completes the card with the
  pull request's URL and its head commit (`slipdock done 12 --pr URL
  --evidence-commit SHA`, `complete_card` `pr` and `commit`, `evidence_pr`
  and `evidence_commit` over the API). The card's **Evidence** links it. On
  a board that also asks for evidence, an agent's completion without the
  pull request is refused (`422`), and so is one naming a pull request
  without its commit, a resubmission after a rejection included: the merge
  is made at that commit.

**Epics have no pull request of their own.** Each subcard of an epic
ships and merges its own pull request, so by the time the epic is
finished there is nothing left of it to merge. An agent completes an epic
(a card whose sub-board holds cards) without `--pr`, the evidence on stdin
as lines:

```sh
slipdock done 12 --evidence - <<'EOF'
Subcards merged; main green.

- #13: PR 41
- #14: PR 42
- the last merged build: run 9001, passed
EOF
```

Accepting it completes it at once, with no merge job, and so does accepting one that names a pull
request one of its subcards already merged. The verifier checks that every
subcard is accepted and merged and that the default branch's latest build
passed, rather than running the suite. An epic that did work of its own,
after its subcards, names that pull request with `--pr`, and the
acceptance merges it as for any card.

**A card that changes no code has no pull request either.** A sweep, a
handbook reconcile or any card that only reads and files has nothing to
commit, so no branch and no pull request, and a token one would be noise.
The agent completes it with the reason instead, and what it did on stdin as
lines (`complete_card` `no_code`, `evidence_no_code` over the API):

```sh
slipdock done 12 --no-code "a read-only sweep: filed #40 and #41" --evidence - <<'EOF'
Swept the board for stale cards.

- filed #40: the export's docs
- filed #41: the importer's timeout
EOF
```

The card's **Evidence** shows the reason. Naming a pull request as well is refused (`422`), and without
either the completion is refused as before. The verifier checks the claim
against what the card asked for (a card that asks for code can't be done
without any) and looks at what it did instead, without checking out a
commit or running the suite; accepting it completes it at once, with no
merge job.

The builder needs no setup to know. On such a board a claimed job's
prompt ends with what to do (branch `card-<id>`, push it, `gh pr create`
once, watch the pull request's checks, `done --pr`), and so does the card:
`slipdock card` shows **Ships by pull request**, and the card's JSON
(`get_card`, `GET /api/cards/:id`) has `shipping` (`via`, `branch`,
`instructions`). A rejected card's next attempt pushes the same branch, so
the same pull request updates rather than a second one opening.

**Security fixes don't announce themselves.** A public repository's pull
requests can be read before the fix deploys, so a card tagged `security`
is told to open a neutral one: the title `Maintenance (#<id>)` instead of
the card's title, `--body "Card #<id>."` instead of `--fill` (which copies
the commit messages), and commit messages, title and body that say what
changed in general terms ("Tighten access checks in board events"), with no
exploit and no list of affected endpoints. The detail stays on the card, on
a private board, until the fix is deployed; the closing comment may link it
after that. `shipping` has `neutral: true` and `slipdock card` shows
*security: a neutral PR*. Merges are already neutral (`Merge PR <n>: card
#<id>`).

The pull request's CI is the one full test run. Before pushing, the builder
runs the tests it added or changed and the project's own pre-push checks,
not the whole suite, and it completes the card once the checks pass, giving
CI's result as the suite. Where the pre-push checks are, in order: the
`## Before you push` section of the board's [handbook](tools.md) Testing &
tooling page, when it has one (the prompt names the `slipdock page section`
command that reads it); else what the project's `CLAUDE.md`, contributing
guide or handbook lists elsewhere, ideally one command that runs what CI checks (Slipdock's own is
`mix pre_push`); and a project that lists none gets formatting and a compile
that fails on warnings. The builder watches the checks with `gh pr checks <branch> --watch
--fail-fast`, so a failed check is seen when it fails rather than when the
slowest one ends. The verifier
doesn't run the suite again either (see [Verify jobs](#verify-jobs)). With
no checks on the pull request, both run it themselves.

Pull request needs **A second agent verifies**: setting it without
verification is refused, and turning verification off ships by push again.
A card's subcards take the board's choice, and an export carries it. The
guide tells agents on such a board what to do (*Shipping by pull request*),
and says so on the board's line.

**Accepting merges.** On a board that ships by pull request, accepting a
card (the card's **Accept**, `slipdock verify 12 accept`, MCP
`verify_card`, a verifier agent) doesn't complete it. The card shows
**Accepted, merging**, stays in progress, and a `merge` job is queued for a
runner, with nothing to set up. It goes to a runner that can merge and is
idle now (seen lately, holding no job), the pool of the runner that built
the card first, so it doesn't wait for a pass to end. With none idle it
goes to the runner that accepted the card, which is about to finish its
verify job, else to the builder's pool, else to any pool on the board with
a runner that merges. When the merge succeeds the card completes, moves to Done and
shows the merge commit (`merge_sha`), and a deploy's commits name it as
usual. A pull request somebody already merged at the accepted commit is
that merge: the runner reports its merge commit and the card completes the
same way. One already merged at another head isn't a rejection either: the
card stays merging, says which head was merged (**Merge failed: already
merged**), and waits for a person to check it and press **Merged it
myself**. When it fails the card goes back to the top of the ready list as
rejected, the merge job's own reason as the rejection. Only a conflict or a
head that moved suggests rebasing `card-<id>` and submitting it again; any
other reason (a closed pull request, a failing check) says to fix what it
says, since a rebase wouldn't help. A runner that can't merge here at all
(its repository isn't the pull request's, it has no `git` or `gh`, or `gh`
is signed out) isn't the card's fault: the merge is handed on to another
runner that merges, never to that one again, and the card says so
(**Merge handed on**). After two hand-ons, or with no other runner, the card
stays merging with nothing queued and says why (**Merge waiting**). If no runner can merge, nothing is queued and the card
says so: give the pool a machine's runner that merges, or merge the pull request yourself and
press **Merged it myself** (`slipdock verify 12 merged [--evidence-commit
SHA]`, `verify_card` `merged`; a person only).

**Runners merge.** A machine's runners have a built-in `merge` job kind,
so a runner needs nothing set to merge (`no_merge: true` in the machine's
own file turns it off). It runs in the runner's directory, its repository,
with `git` and a signed-in `gh` (GitHub CLI). The server sends only data:
the card's pull request and the commit that was accepted (the verifier's
commit, else the builder's). The runner then checks, before merging anything:

- the pull request is in the repository's own `origin`;
- it is still open;
- its head is the accepted commit (`gh pr merge --match-head-commit`), so
  nothing pushed after the acceptance gets merged.

It merges with a merge commit (`Merge PR N: card #ID`, so a deploy's card
references don't read the pull request's number as a card) and reports
the merge commit back. Anything else (a moved head, a closed pull request, a
conflict or a failing required check, another repository, no `gh` or `gh`
not signed in) fails the job with the reason; a refused `gh pr merge`
gives `gh`'s own words, so a conflict reads differently from a failing
check. `MERGE=0` (`$Merge = $false`
on Windows) in the config turns it off, and a config's own `job_merge`
(`Job-Merge`) replaces it. Every claim says which kinds the runner takes
(`X-Runner-Kinds`), and a merge job goes only to a runner that takes
`merge`, so older runners are never handed one. A merge job never gets a
worktree, since its card's branch is the pull request's.

**Merging isn't always releasing.** On a board set to release in batches
a merged card is done but waits for a release: see
[Batched releases](batched-releases.md).

---

← [Where it was left (handoffs)](where-it-was-left-handoffs.md) · [Contents](../manual.md) · [Batched releases](batched-releases.md) →
