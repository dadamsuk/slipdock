# Choosing the card

Part of the `slipdock-loop` skill: read when the pass was not given its card:
it works a board's list, or takes a job from a pool's queue. A pass whose
invocation names the card (a runner's job does) skips all of this and starts
at `SKILL.md`'s step 3. Step numbers are `SKILL.md`'s.

## 1. Which board

In order: the board named in the invocation; then a board the user has
favourited (`slipdock favourites`); then, if exactly one board has eligible cards
in its ready list, that one. If several do and nothing has been named, **ask
once** — then stay on that board for every later pass rather than asking again.
Never take work from an archived board (`slipdock boards` hides them for a
reason), and never work the **Getting Started** board: it is the tour the
server builds for a new account, and its cards are instructions for a person
("drag this card to Done", "press Edit and add a line"). Carrying them out
teaches nobody anything and ticking them off is a lie about what happened. If
that is the only board with a ready list, stop and say so.

## 2. Resume before you claim

A pass can die mid-card. So before looking at the ready list, look at what is
already claimed:

```sh
slipdock cards <board> --column "In Progress" --assignee me --open
```

That only sees the top level, and a pass spends most of its time on an epic's
subcards. So also look inside every open card that has subcards (`sub_board` in
`slipdock cards <board> --open --json`), on whichever list the parent sits:

```sh
slipdock cards <sub-board-id> --column "In Progress" --assignee me --open
```

Anything there that is **not** flagged `blocked`, `waiting` or `review` is this
pass's card — read it (`slipdock card <id>`, comments and all) and carry on from
where its handoff (`Left off:`, at the top) and the comments say it got to. Only an empty result means pick something new.
This is what stops a loop starting four cards and finishing none.

If the resumed card's last comment is `Build started` (see step 7), the pass died
while watching CI: find that run again with `gh run view <run-id>` and carry on
from step 7's watch rather than redoing the work. (A subcard in that state
doesn't wait: close it, and check its build as section 5 (`subcards.md`) says.)

## 2a. Check CI before you pick

A build can go red after a pass has ended — a push made by hand, a flaky rerun,
a pass that died mid-watch. So when nothing is resumed, and the board's work
lands in a GitHub repo (the working directory's `origin`), look at the default
branch's latest build before taking anything from the ready list:

```sh
gh run list --branch <default-branch> --limit 1 \
  --json databaseId,status,conclusion,headSha,displayTitle,workflowName,url
```

If it is `completed` with conclusion `failure` (or `timed_out`), make sure the
board knows about it. First look for an open card that already mentions it:
`slipdock search "<run-id>" --board <board>`, or grep the run id and short sha
across `slipdock cards <board> --open --json`. An open card that already mentions
the run, or an open card whose commit it is, means the failure is already being
handled. Leave it. If the commit is a closed subcard's and its epic is still
open (a pass died partway through the epic), file the fix under that epic as
in section 5 (`subcards.md`) instead: the epic's own pass fixes it. Otherwise:

```sh
slipdock add <board> "CI failing on <branch>: <workflow> run <run-id>" \
  --column "To Do" --tag ci --desc - <<'EOF'
<commit sha + subject, failing job and step>

<the 20–40 most telling lines of gh run view <run-id> --log-failed>

<the run url>
EOF
slipdock move <new-id> "To Do" --top
```

`--desc -` reads the description from stdin, so a quoted heredoc keeps the
log's line breaks, backticks and `$` as written (`--bar -` does the same for
a bar; one `-` per command). A `slipdock` that doesn't read stdin there (one
from before #2678) sends the dash itself, and the server refuses a
description or bar that is a bare `-` rather than file a card with no body:
pass the text itself (`--desc "…"`), or reinstall the CLI.

Then carry on to step 3, which picks that card up because it is now on top.
Fixing the build is the card's whole brief. A newer run that is still
`in_progress` or `queued` means wait: don't file the older failure, because the
newer run may already fix it. If `gh` isn't authenticated, or there is no
remote, or no workflow, skip this step and say so once in the pass report.

## 2b. A job first, when you are given a pool

A board can queue cards for **runners** (an automation rule's `runner`
action), and a pass can be one of them: when the invocation names a pool
("pool default", "jobs from the loop pool"), take a job from that queue
before looking at the ready list. It is the same queue the runners on
people's machines take from, so the pass never races one of them for a card.

```sh
slipdock claim-job <board> --pool <pool>     # or the MCP tool claim_job
```

- **A job.** Its card is this pass's card, wherever it sits. Read it as in
  step 3 and claim it as in step 4, saying `Job #N` in the *Picked up*
  comment so a later pass can tell. While it is open, write the running log
  with `slipdock job-progress <job> --message - <<'EOF'` (the comment, as in
  **How a comment reads**, then `EOF`) instead of `slipdock comment`: it is the same comment on the card, and it renews the
  job's lease. A session holds the job for 20 minutes per report, so report
  before anything long (a full test run, a CI watch) and after it. If it
  ever answers `cancel`, somebody has stopped the job: stop work, say so on
  the card, hand the card back (see **Handing a card back**) and
  `slipdock finish-job <job> --status cancelled`. At the end of step 7, after
  the wrap-up comment, `slipdock finish-job <job> --status done --summary
  "<commit and CI result>"`; a card handed back instead ends its job
  `--status failed`, with the reason as the summary.
- **`nothing queued`.** Go on to the ready list (step 2a, then 3) only if the
  invocation says to fall back ("else the top of To Do"). Otherwise the pass
  is over: report `no job queued for <pool>` and stop.
- **`nothing queued to take: job #N waits while #M is in progress`.** A job
  is held back because a card is in progress on the board. If that card is
  yours, step 2 should already have resumed it; otherwise somebody is working
  it, so report that and stop rather than starting a second card beside it.
- **No job tools at all** — no `claim_job` MCP tool and no `slipdock`
  command to run `claim-job` with: don't take a card from the lists instead.
  That would leave the job queued and race the runners for its card. Stop,
  and say the Slipdock connector needs reconnecting (claude.ai → Settings →
  Connectors: a connector keeps the tool list it had when it was added) or the
  `slipdock` CLI installing.
- **`nothing queued to take: paused by …`** — a person has paused runner work
  on the board (or this pool), and said why. Take nothing, not even from the
  ready list whatever the invocation says about falling back: report the
  pause line and stop. Only a person resumes it.
- **`unknown command`, or a 404 from the server** (one older than runners):
  say so once in the pass report and carry on as though no pool had been
  named.

A resumed card (step 2) whose *Picked up* comment names a job is still that
job's: report and finish on it as above. If its lease ran out while the pass
was gone, the first `job-progress` or `finish-job` takes the job back,
unless another runner has claimed it since: then they answer that it was
not claimed with this token — note that on the card and carry on without
the job.

## 3. Pick the top card

```sh
slipdock cards <board> --column "To Do" --open --deps ready --no-assignee --json
```

If the answer starts with a `PAUSED` line (`paused` in the JSON), runner work
on the board is held by a person: take nothing, report the pause line and
stop. The same goes for a pass that fell back here from an empty job queue.

**Top first, then downwards** — the order the list is in, which is the `position`
field, not priority. The person stacked that list on purpose; priority is a
tie-breaker at most, and only between cards sharing a position. The filters do
the skipping for you: `--open` drops completed cards, `--deps ready` drops
anything waiting on an unfinished card, `--no-assignee` drops other people's
work. Also skip anything already flagged `blocked` or `waiting` (an open wait
on a person sets `waiting` itself), anything waiting for verification
(`verify_state: "pending"`, flagged `review`: see **Verified work**), anything a
previous pass in this session flagged `review` and handed back, and every
stand-in (`↪stand-in-for:#N`, `stand_in_for` in the JSON): it marks where a
card went into a sprint, and the work is that card, not the stand-in.
Never take a card from a **Triage** list (category `triage`, which the guide
marks `triage: for a person`), even when it is the only list with cards: a
code sweep files its design questions there for a person to triage (its
fixes go to Housekeeping when the board has one), and they move what is
worth doing into the ready list.
Nor from a **Scheduled** list (category `scheduled`, which the guide marks
`scheduled: worked by feed rules`): recurring agent work lands there, and its
feed rules send each card to a runner on its day. A pass asked what to do next
never takes from it, even when the ready list is empty; a card from it comes
to a pass only as a job.
A **Housekeeping** list (category `housekeeping`, which the guide marks
`housekeeping: worked by runners after the ready list`) holds the small fixes
and investigations generators file. Its feeds send a card only while the
ready list and Scheduled have nothing their pool could start. A pass asked
what to do next takes from it only when the ready list has nothing it could
start: the top of Housekeeping then, by the same rules as above.

With the card chosen, go on to read it: `SKILL.md`, step 3.
