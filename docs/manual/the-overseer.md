[Slipdock — the manual](../manual.md)

## The overseer

Slipdock records everything that happens to the work — every rejection,
wait, handoff, job step and pulse number — but the health monitor fixes
plumbing and the gardener tidies on a day clock. The **overseer** watches
the outcomes: work going round, a board held up only by you, a card slower
than it should be, runners idle beside work they could take, an epic that
can't move. It says "a person should look now" rarely: once per condition,
with why and what to do, and it clears the alert itself when the condition
ends. It flags; it never acts. Off until the root board's owner turns it on.

**The watch** is server code on the scheduler's clock, costing no tokens.
Every minute it runs five checks over the board tree:

| Check | Fires when |
|---|---|
| `looping` | a card is rejected a second time (or for a rule id it failed before) and still isn't accepted, or a card is on its third runner pass and still open |
| `waiting_idle` | something waits on a person (an open wait, a card flagged `review` or awaiting verification) and no runner job is open anywhere on the tree |
| `slow` | a card has been in a doing list longer than its board's P85 time to done for its profile (or for every card, with fewer than 8 of the profile done in 90 days); or a running job's heartbeat is live but its step hasn't changed in 30 minutes |
| `idle_capacity` | cards are free on a ready list while runners on the tree are online with no job for the *idle* minutes (15); or two or more queued jobs wait behind one card's lane (a file in every card's paths, such as `docs/agents.md`, serialises them) |
| `no_way_forward` | an epic is in progress and every open subcard is blocked |

A condition found for the first time **fires**: a warning alert on the root
board (the alerts bar, as an automation's alert is) and an email to the
board's owner, unless *Email me* is off. Seen again, it stays quiet. No
longer seen, it **clears**: its alert comes down for everyone. A card going
round in circles is already alerted and emailed on the rejection
([Verified work](verified-work.md)); the watch takes that alert over rather
than raising a second. Open conditions head the owner's *Waiting on you*
(reason `overseer`), before anything else, in My work, `slipdock work`,
`GET /api/work`, and first in `slipdock whoami`, `GET /api/me` and MCP
`whoami`. Cards on a *Getting Started* board are never in *Waiting on you*:
the tour's cards are instructions for a person, not work waiting on you.

**The pass** is a cheap, fast model on a schedule, on your own machine and
subscription, like a verifier: a runner job of kind `overseer`, sent to the
overseer's pool only to a runner that takes that kind (the runner config has
a `job_overseer` function; give it a small model, such as
`job_overseer() { SLIPDOCK_MODEL=haiku job_claude; }`). It reads only what its
prompt carries — the watch's conditions (open, and cleared in the last day),
the root board's pulse and the counts below — never a card, a comment or a
log, and answers with one line of JSON: `health`, a `digest` ("overnight: 4
merged, #2040 took 3 rounds, #2044 waiting on you since 23:40, nothing else
moving") and `look_now`, the conditions a person should open now. The digest
is kept as a status update on the overseer's card, a completed card titled
*Overseer* in the root board's done list, made when the overseer is turned
on, which its jobs hang off.

**When.** Each pass sets the next from what is in flight: every
**min** minutes (10) while anything is — a runner busy, a card in a doing
list, a job queued or running, a wait open, a condition open; 30 minutes
when nothing is in flight but cards wait on a ready list; **max** minutes
(120) when nothing is in flight and the ready lists are empty. A rejection,
a wait opened or a job ending since the last pass brings the next one
forward, though no sooner than 5 minutes after the last. The watch runs
every minute regardless.

**The morning digest of Housekeeping's work.** Once a day, at *Housekeeping
digest at* (07:00 unless you change it, in your own time zone), the overseer
writes one more status update on its card: what the Housekeeping list's
feeds worked since the last one. The cards are grouped by theme, one line a
group (a card's tag, else the handbook area its paths fall in, else
*other*). It names one by one only the cards that need you: rejected by
verification, escalated to Triage, given up on, or whose paths overlap a card
in progress under an epic. A day when nothing ran says so in a line. It
appears wherever the overseer's digests do, with no new notification. It
costs no tokens: the server writes it from what it already holds.

**Turning it on.** Automations → **Overseer** on the board (its owner):
*Watch this board*, the runner pool, the bounds and *Email me*, with the
last digest and the open conditions below. Or:

```sh
slipdock overseer ops                         # on or off, next pass, last digest, open conditions
slipdock overseer ops --on --pool default     # turn it on
slipdock overseer ops --min-minutes 10 --max-minutes 240 --idle-minutes 20 --no-email
slipdock overseer ops --digest-at 06:30          # when the Housekeeping digest is written
slipdock overseer ops --off
```

```
GET   /api/boards/:board/overseer          settings, conditions, cleared_last_day, last_digest, next_run_at
PATCH /api/boards/:board/overseer {enabled?, pool?, min_minutes?, max_minutes?, idle_minutes?, email?, digest_at?}
```

Over MCP, `get_board` with `overseer: true` reads it and `update_board` with
`overseer: {…}` sets it. Settings belong to the tree's root board, whichever
board in it you name; reading needs read access on the root as well as on
the board named (its conditions and digest name cards anywhere in the tree,
so a sub-board's reader who can't read the root gets a 403, and its panel
says so), changing it the owner.
Bounds are 5 to 1440 minutes, min no more than max.

---

← [Right now](right-now.md) · [Contents](../manual.md) · [Dependencies](dependencies.md) →
