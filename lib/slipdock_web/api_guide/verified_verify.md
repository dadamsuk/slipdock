**A second agent verifies.** Completing a card *submits* it: it stays
open in its list with `verify_state: "pending"` and the `review` flag,
and isn't done until someone else decides. Moving it into a done list
yourself is refused, and so is creating a card already done (in a done
list, or completed): create it in another list and complete it. Don't take a pending card as your next work unless
you are the verifier. To verify one you did not submit: check out the
evidence's commit and judge, in order, the ask (does the bar cover what
the card asks for?), the bar, and on a board with a handbook the rules
for the diff's paths (`slipdock handbook B --paths-from -`) and the
closing `Handbook:` line against the docs gate. On a bug, the ask is
the reported symptom: the check is would the reporter now see it fixed,
not does the work meet the bar. The builder reproduces the reported
symptom on the reporter's scenario and posts the repro as its own
comment; a clean repro that doesn't show it opens a wait saying what was
seen and asking for a screenshot or steps (which screen, which control),
never conditions built until something fails. A bug card whose card or
evidence says the reported symptom or its cause was never seen is a
rejection (`the ask: …`), however good the tests. A bar item that adds,
rewords or drops a handbook rule is met by a matching open rule proposal
(an `edit_section` step on that page's `## Rules`; `slipdock garden B
--check proposal`): judge the proposal's content, not the live rules,
and name its id when accepting. A rejection never asks the builder to
edit `## Rules` directly, only to file or correct the proposal. Then
`verify_card` (`slipdock verify ID accept|reject --reason -
--evidence-commit SHA`, the reason on stdin as lines, the same shape as
evidence, its parts in `--check`; `POST /api/cards/:id/verify {"decision":
"accept"|"reject", "reason": "…", "commit": "…"}`). Accepting completes
it and moves it to the done list. Rejecting needs the reason, citing the check it fails (`bar 2: …`,
`the ask: …`, a rule id such as `ARCH-3: …`, or `Handbook line: …`) and
giving the verdict in parts as `checks` (`ask=ok|misses`, `bar:2=fail:why`,
`rule:UX-4=pre-existing:lib/x.ex:42` for a rule broken only in lines
the diff didn't change, never a rejection and kept as a `rule` finding,
`suite=412:0`, `rule:UX-4=broken`, `handbook_line=ok|disputed`,
`mutant:killed|survived|pre-existing=<file>:<line>:<mutation>[:note]`,
`mutants=n/a:<why>`; kept as
`verify_checks`, and refused without a failing part, or on an accept
with a broken `must` rule). A rejection names every instance found:
once a rule is found broken, the verifier looks for every other
instance of the same break the card could have missed (the same list,
the same string, the same door) and names them all in one rejection,
each as its own `rule:<id>=broken:<file>:<line>` check under the one
rule, and says in the reason that it looked; a rule broken in several
places is one failing part, its instances listed under it in the
rejection's comment. `SPEC-10` is checked by enumeration, not judged:
for a card whose paths fall in its scope the prompt adds a docs-places
step. List the names the change introduces or alters from the diff
(commands, flags, MCP tools, API fields, settings, page and section
names), grep them across the <%= @docs_places_count %> places (<%= @docs_places %>)
and give each place one result: updated, deferred to #N (only when card #N's
bar names that place), n/a with why, or missing. One missing is
`rule:SPEC-10=broken:<file>:<name>`. The builder does the same before
submitting: a place its lane can't reach goes on the deferral card's
bar by name, or the deferral doesn't count. A card resubmitted after a rejection is
judged on what changed: its verify prompt carries the last verdict and
the commit it judged, the verifier judges the parts that failed and any
part the commits since touch, and a part that passed then and isn't
judged again (`bar:1=carried`, or left out) is kept carried, marked
with that commit (`carried_from`, or `verify_checks.carried` for the
ask and the Handbook line); a part that failed can't be carried, and an
audit carries nothing. A rejection goes
on the card as a comment and in `get_card`'s `rejection` (a claimed
job's prompt carries it too; the handoff only points there), the
evidence is cleared, the builder's own assignment comes off, its
`verify_rejections` counts one more, and it goes back to the top of
the ready list, next for the runners, so whoever takes it next fixes
what the reason says and completes it again. The second rejection, or
one for a rule id an earlier one named, keeps the card flagged
`review` until it is accepted, comments *Going round in circles* with
the rounds, alerts and emails the owner, and puts it first in their
waiting (`circling`): it is still sent for rework. Past the board's
`verify_rejection_limit` (2 by default, 0 never) the rejection opens a
wait on the board's owner instead (*Rework as rejected* or *Accept as
is*, listing the parts that failed each time and asking whether the
approach, not the fix, is wrong): the card is flagged `waiting`, and only a person answers. A
board's `verify_audit` (1 in N, 0 none) queues about one card in N an
agent accepted to the verify pool again as an audit (kind `verify`,
`audit: true`; never to its builder's or verifier's runner): judge it
afresh, `should` rules too, and answer `slipdock verify ID agree|disagree
--reason -` (`verify_card`), the reason on stdin as lines, its parts in
`--check`. The acceptance stands; agree only comments.
Disagree also files the rework: one card in the ready list, titled
`Audit of #ID: <reason>`, with the failed parts, the audit comment's
link, the accepted card's paths, `caused_by` it, and priority `high`
for a surviving mutant or a broken `must` rule. The owner's alert and
the `audit` finding name it, and the alert clears itself once that card
is accepted or completed; a second disagreement comments on that card
while it is open, its alert clearing with the same rework. The verify
prompt (never the audit's) lists the tree's last five audit misses of
30 days: check those first. The submitter can't
decide its own card (`403`): a different agent is a different token,
or a different runner job. A board with a `verify_pool` also queues
each submitted card for that runner pool as a job of kind `verify`,
whose prompt carries the card's ask, the bar, the evidence and those
checks, and asks
its agent to report each step with `job-progress --step` (no note, so
the card stays quiet until the decision). The
runner that built the card never takes it. Whoever decides first
decides, and the other verify jobs on the card stop.
