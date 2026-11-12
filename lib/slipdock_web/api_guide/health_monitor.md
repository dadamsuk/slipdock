## Health monitor

Every few minutes the server looks each board tree with runners or rules
over for work stuck in ways only a person would otherwise notice (W-2310):
jobs nobody takes, deadlocks, verification and merges that stall, cards and
waits nobody is moving. Each finding is an **incident**. Where a safe fix
exists it is tried (a few times at most, each attempt a comment on the
card); otherwise, or once the fixes run out, it is **flagged**: the card
gets the `stuck` flag and a comment saying what was found and tried, or the
board gets an alert when no card is involved. Fixes touch only jobs, the
queue, flags and comments; nothing is deleted, merged or closed.

- **A card flagged `stuck`** needs a person. Don't work around it or take
  the flag off yourself: say on the card what you know, and leave it.
  Taking the flag off marks the incident handled, and the same state is
  not flagged again.
- **Hearing about it:** the `health_flagged` trigger (`detector` narrows
  it), or the preset *The health monitor needs a person*, with an email.
- **Reading it:** `GET /api/boards/:board/health` (open and flagged
  incidents, recent ones, the last run, each detector's settings);
  `POST` the same path runs it now (write access); `PATCH
  /api/boards/:board/health/settings {detector, enabled?, max_attempts?, …}`.
  The CLI's `slipdock health <board>`; the board's Health page, linked from
  Runners.

**Right now** (#2103): `GET /api/boards/:board/now` (or MCP `get_board`
`now: true`) says what is happening on the board's tree at this moment:
each runner (`online`, `session`) and the jobs it holds with their latest
`step`; every card in progress with its `board`, `list`, `parent` epic,
state line, `loop` and what `holds` it (`waiting`, `verifying`, `merging`,
`blocked`, `review`, `stuck` for the health monitor's flag, `over_usual`
for a card merely past its list's usual stay); the jobs `queued` and why
each is `held`;
and the `counts`. Read access to the board and its tree's root. The
board's Right now page (`/boards/:id/now`) shows the same, and so does
`slipdock now <board>` (`--json` for this JSON).

**The overseer** (#2068) watches outcomes rather than plumbing, once its
root board's owner turns it on. Every minute it checks the tree for work
going round (`looping`: a second rejection, or a third runner pass of
one card), a person as the only bottleneck (`waiting_idle`: a wait or
review open and no job open), `slow` cards (past the board's P85 time
to done for their profile) and jobs (a live heartbeat, the same step
for 30 minutes), `idle_capacity` (free ready cards and runners idle for
`idle_minutes`, or two or more jobs queued behind one card's lane) and
`no_way_forward` (an epic in progress with every open subcard blocked).
A sixth, `not_shipped` (a merged card no succeeded deploy names after
the board's `not_shipped_minutes`, counted from its release on a tree
with batched releases), runs on every tree with delivery
metrics on, whether or not the overseer is.
Each condition fires once, as a warning alert on the root board and an
email to the owner with why and what to do, heads the owner's waiting
(reason `overseer`, with its `condition`), and clears itself, alert and
all, when it ends. A runner job of kind `overseer` goes, at most one at
a time, only to a runner whose claims list `overseer` in
`X-Runner-Kinds`; its prompt carries the conditions, the pulse and the
activity counts and nothing else, and its answer, one line of JSON
`{"health", "digest", "look_now"}`, is kept as a status update on the
root board's *Overseer* card. Passes come every `min_minutes` (10)
while anything is in flight, 30 when only ready lists have cards, and
`max_minutes` (120) when nothing does; a rejection, a wait or a job
ending brings the next forward. `GET /api/boards/:board/overseer`
(read access on the board and on its tree's root, whose overseer a
sub-board answers with: a 403 otherwise) gives its settings, `conditions`, `cleared_last_day`,
`last_digest` and `next_run_at`; `PATCH` the same path `{enabled?,
pool?, min_minutes?, max_minutes?, idle_minutes?, email?, digest_at?}`
(the owner; bounds 5 to 1440 minutes, min no more than max). MCP:
`get_board` `overseer: true`, `update_board` `overseer: {…}`. CLI:
`slipdock overseer <board> [--on|--off] [--min-minutes N] [--max-minutes
N] [--digest-at HH:MM]`. Once a day at `digest_at` ("HH:MM" in the
owner's zone, 07:00) the overseer also writes the morning digest of
Housekeeping's work on its card (#2781). It groups what the
Housekeeping feeds worked by theme and names only cards rejected,
escalated to Triage, given up on, or overlapping an in-progress epic's
paths. `housekeeping_digest_at` says when it last ran.
