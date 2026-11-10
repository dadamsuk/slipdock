[Slipdock — the manual](../manual.md)

## The health monitor

Work on a board with runners gets stuck in ways only a person notices, and
usually late: a job queued for a pool with no runner online, an answer held
behind a queued job that is itself held by the card waiting for the answer, a
merge that never ran. The health monitor is server code on the scheduler's
clock, not an agent: every few minutes (`config :slipdock, :health,
interval_minutes: 5`) it looks every board tree with runners or automation
rules over, one run at a time across the servers.

Each kind of stuck is a **detector**. What one finds is an **incident**, with a
fingerprint of what it is about and the state that made it stuck, like a
tidy-up suggestion: the same state never has two incidents, a changed state is
a new one, and an incident **clears** by itself when a later run no longer finds
it.

1. **Fix.** Where a detector has a safe fix, it is tried, up to its
   `max_attempts` (2 unless the board says otherwise). Each attempt is a comment
   on the card and a line in the incident's log. Fixes touch only orchestration
   state — jobs, the queue, flags, comments — and never delete, merge or close
   anything by force.
2. **Flag.** With no fix, or once the fixes run out, it is flagged for a person:
   the card gets the **stuck** flag (a lifebuoy) and a comment saying what was
   found and what was tried; with no card involved, the board gets an alert.
3. **Tell someone.** Rules with the trigger *the health monitor flags something
   stuck* (`health_flagged`, optionally for one `detector`) hear about it. The
   preset **The health monitor needs a person** (Automations → gallery, under
   Connect) is that rule with an alert or an email; its email says what was
   found and links the Health page. The **A card is flagged** preset takes
   *stuck* too.

**Dealing with it.** Take the `stuck` flag off once the card is dealt with: the
incident is marked **handled**, and the same state isn't flagged again — only a
changed one. A flag the monitor put on comes off by itself when the incident
clears.

**Where to look.** The board's **Health** page (`/boards/:id/health`, its
tile on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page) lists what is stuck now — *open*
while fixes are tried, *flagged* once it needs a person — and what was lately
fixed, cleared or handled, each with its log, and when the monitor last ran.
Anyone who can read the board can look; *Look it over now* needs write access.

```sh
slipdock health ops                      # stuck now, lately, the last run
slipdock health ops --run                # look the tree over first
slipdock health settings ops             # every detector, on or off, with its thresholds
slipdock health settings ops no_runner minutes=30 max_attempts=3
```

```
GET   /api/boards/:board/health                    incidents, recent, last_run, detectors
POST  /api/boards/:board/health                    run it now (write access)
PATCH /api/boards/:board/health/settings {detector, enabled?, max_attempts?, …}
```

Settings belong to the tree's root board, whichever board in it you name.

**The monitor's own pulse.** The monitor can't report its own death, nor the
scheduler's clock stopping, so `GET /healthz` reports both: when the scheduler
last ticked and when the monitor last ran (`scheduler` and `monitor`, each with
`last`, `age_seconds` and `stale_after_seconds`). It answers `503` with
`"status": "stale"` and the reason once either is older than a few of its
intervals (the scheduler 5 minutes, the monitor 15), except in the first ten
minutes after a start, so a deploy's health wait passes before the first tick.
Point an outside uptime check (any service that polls a URL and alerts on a
non-200) at `https://<your server>/healthz`, and you hear when the clock
stops. `slipdock health <board>` ends with the same pulse.

| Detector | Finds | Fix |
|---|---|---|
| `no_runner` | A queued job whose pool has had no runner online (seen within three leases) for 15 minutes (`minutes`). Names another online pool that takes that kind of job, if there is one. A paused pool is left to `long_pause`. | None: flagged. |
| `hung_job` | A running job still renewing its lease that has shown no sign of work for 45 minutes (`minutes`): no progress step, no note on its card or on any card beneath it (an epic's pass writes on its subcards), and no job on one of those subcards claimed, reporting or ending (the verify and merge jobs its submissions set off). | None by default (an agent may be thinking). With `cancel=true`, a job silent for `cancel_minutes` (120) is asked to stop. |
| `idle_feed` | A *list top* rule that has sent nothing for 15 minutes (`minutes`) while its list has a card it would send and a runner of its pool is online and idle. Not when the list is empty, the pool paused or the WIP limit full. | Runs the feed. Still idle, it is flagged on the next run with the reason the feed gave. |
| `long_pause` | A pool or a whole tree paused for over 12 hours (`hours`). | None: a board alert. |
| `deadlock` | A cycle in what waits on what: a queued job held by a lane, a WIP limit or the cards in progress; a held answer waiting for its rule's job; a card waiting for an answer or a blocker; a card waiting for its verify or merge job; a merge job waiting for a busy runner (one holding a job that hasn't asked for another since it claimed it: a runner that takes merges mid-pass isn't busy); the pass on an epic waiting for its subcards to merge. The incident names each edge. | Withdraws a work job in the cycle that was never handed out (its card keeps its place and goes next), then sends held answers and runs the feeds. Never touches a claimed or running job, a card's place or a dependency: a cycle of dependencies alone, or through a claimed job, is flagged on every card in it. |
| `verify_missing` | A card pending verification, on a board with a verify pool, with no verify job open for 10 minutes (`minutes`): one was cancelled, failed or never queued. | Queues it again to the verify pool, never to the card's builder, up to twice for the same submission; then flagged. A refusal that would come again (a pool that isn't a name, a prompt over the cap) is flagged at once, saying why. |
| `merge_missing` | An accepted card on a board that ships by pull request, shown as *merging*, with no merge job open for 10 minutes (`minutes`). | Queues the merge again, to the pool a merge would go to, up to twice; then flagged (at once when no runner takes merge jobs). |
| `merge_failing` | A card whose merge failed twice (`failures`), the latest merge among them. A merge that fails sends it back as rejected each time; the flag says it is looping. A merge job that finds the pull request already merged isn't a rejection: at the accepted commit it records a merge, and at another head the card stays merging, for a person to mark merged by hand. That job still ends failed, so `merge_missing` queues the merge again and a repeat is flagged here too, as still merging, not as looping. | None: flagged, with the merges' reasons. |
| `verify_slow` | A verify job claimed for over an hour (`minutes`, 60) with no progress step or note. `hung_job` leaves verify jobs to it. | None: flagged. |
| `orphan_in_progress` | A card in a doing list that an agent put there, with no job open on it and nothing done for 2 hours (`minutes`, 120), and not pending verification, merging or held, nor an epic with an open, unarchived subcard that is (waiting on a subcard's verifier or merge). The Tidy-up check *In progress, untouched* leaves these to it and keeps the cards people drive. | Moves it back to the top of its list (its last job's feed list, else the ready list) with a comment, once; orphaned again, it is flagged. |
| `unanswered_wait` | A question (a wait) open for over 2 days (`days`). | Emails the person it is on again (with nobody named, the board's owner), once. Still open after another 2 days, it is flagged. |
| `dead_blocker` | An open card blocked by one in a dropped list or, on a board with a feed, in a list no feed takes from and not in progress (a *Maybe Later*), so it can never start. An archived blocker no longer blocks. | None: the blocked card is flagged, naming the blocker. |
| `lane_hog` | A card in progress whose lane has kept another card's job waiting for over 4 hours (`hours`) while nothing happened on it. | None: the card holding the lane is flagged. |

---

← [The ledger](the-ledger.md) · [Contents](../manual.md) · [Right now](right-now.md) →
