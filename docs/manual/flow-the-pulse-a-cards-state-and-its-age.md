[Slipdock — the manual](../manual.md)

## Flow: the pulse, a card's state and its age

Every card move is recorded with where it came from, where it went, when,
and who made it — a person, an agent or an automation — and the board works
its flow numbers out from that record.

**The pulse.** Cards in progress, cards waiting on a person (and the oldest
wait), cards done in the last 7 days (and today), the typical (P50) and slow
(P85) time to done, moves in the last 24 hours forward and back, and each
list's in and out over 7 days with its usual stay. `slipdock pulse <board>`,
`GET /api/boards/:id/pulse` and MCP `get_board` with `pulse: true` answer it
on every board; **Show the board's pulse** in the board's settings
(`slipdock set-board <board> --show-pulse`) puts it in plain words over the
lists; click the line to open the board's Visualise view, or, with
[Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) on, its [Right now](right-now.md) page.
Off by default.

**A card's state.** A card with a job or a wait on it shows one line on its
front — *Building · runner-2 · 7m*, *Queued · dev · 3m*, *Held · paused by
David: bad deploy*, *Waiting on Dana · 41m*, *Failed · runner-2 · 2h ago* —
with its handoff's next step after it when there is one. A running job that
builds the card reads *Building*; one that verifies or merges it reads
*Running*. A card with
neither shows nothing. On a board tree with runner rules, a small mark says
whether an agent or a person holds it.

**Its age.** A chip says how long the card has been in its list, and turns
amber, with how far over, once that is past the list's usual stay (the time
85 in 100 cards spent there). Never on a done or dropped list, a card with an
open wait (the person is the hold-up), an epic with open subcards (it sits in
progress for as long as they take), or where there is too little history. The
open card wears the same chip on the line under its title, so what the tile
and [Right now](right-now.md) say about it is explained on the card.
It is off until you ask for it: show **Time in list** in your
[card views](card-views.md) (every board, one board or one list), and hide it
there to leave it off again. A list can keep it off its own cards whatever
your card views say: untick
*Show how long each card has been in this list* in its settings (that list
only; `slipdock set-column <board> <list> --no-show-age`, or
`show_age: false` on the list over the API).

The board's **Filter** menu has *Time in list* (only cards past their list's
usual stay) and, on runner boards, *Driver*: All, Agent or Human. The API, MCP and CLI carry the same
`state`, `held`, `driver`, `in_list_since`, `age`, `usual_stay`,
`over_usual` and `stuck` on each card, and filter on them:
`slipdock cards <board> --stuck --driver agent`,
`GET /api/boards/:id/cards?stuck=true&driver=agent`, MCP `list_cards` with
`stuck` and `driver`.

**Where it came from.** Every card made since #2778 records its *origin*:
a person, the sweep, findings triage, the health monitor, the overseer,
verification, a rule (or the clock), an import, or an agent and the runner
job it was in. It shows under the card's properties (*Origin agent (job
#41)*), in `slipdock card`, and as `origin` and `origin_job_id` from the
API and MCP; older cards have none. The board's **Filter** menu has
*Origin*, one at a time (*no origin* for older cards), and so do
`slipdock cards <board> --origin sweep`, `GET
/api/boards/:id/cards?origin=sweep` and MCP `list_cards`; a rule's
condition can read `origin` too. The server sets it from who made the
card: only an agent inside a runner job may name a generator, `sweep` or
`findings` (`slipdock add … --origin sweep`, MCP `create_card` `origin`),
and nobody can claim to be a person.

**Who made it, and who changed it last.** Under a card's properties (in
the sidebar, and on a phone under the title) *Created by X, 3 days ago*
and *Last changed by Y, 2 minutes ago*. The last change is any kind: an
edit, a move, a comment, a checklist item, an attachment or a flag. X and
Y are a person, a runner loop by its runner's name (*Dev server loop*), an
agent by its token's label, or an automation rule by its name. When nobody
was recorded, as on cards older than this, only the time shows: the name
is never guessed. `slipdock card` prints them on its *Created* and
*Updated* lines; `GET /api/cards/:id` and MCP `get_card` carry
`created_by`, `updated_by` (each `{kind, name, user_id}`, a runner's with
its `job_id` too, or null) and `updated_at`, the time of the last change.

**Its timeline.** Near the bottom of the card, the **Timeline** draws what
the card has been through on one time axis, from its first record to now:
a lane of the lists it has sat in, coloured by the list's category (to do,
in progress, done, dropped, and grey while archived); a lane of its waits on
a person; and a lane of its runner jobs. Hover a span for when, how long,
and who moved it. A stay recovered from the old activity log whose end the
history can't vouch for is faded and dashed. Once the card sits in a done
list, its time there no longer stretches the drawing: the time before it
got there fills most of the axis, the stay in done is a short fixed tail,
and the axis marks when it reached done. Only the drawing is folded; the
span's title, the list below and the API still give its real length.
Under the lanes, *stays in lists* lists the same stays as text. Over the API it is
`GET /api/cards/:id/timeline` (`stays`, `waits` and `jobs`, each with
`from`, `to`, `seconds` and `open`), over MCP `get_card` with
`timeline: true`, and on the command line `slipdock timeline <id>`.

### Its lead time and cost

A card a runner has worked, and an epic, has a **Lead time** line in its
panel, under its runner jobs: how long it took (from creation to its first
deploy, or to done, or to now while it is open), its three longest phases,
and what its jobs spent. That comes from their logs:

- the **model's time** and the **tools' time**, split the way a job's log
  summary splits them (each stretch between two lines goes to the tool call
  waiting for its answer, else to the model);
- **tokens**: input, output, cache read and cache write, summed once per
  message from the `usage` the Claude Code log carries. A log with no
  `usage` has no tokens. They are left out, never shown as 0. When some of
  them are cache reads (the same context read again on each model turn,
  billed at a fraction of the input rate), the line gives the **new** ones
  beside the total, as in `5.8M tokens (180.0k new)`: input, output and
  cache write. That is the figure to compare jobs by, since a long job's
  total is mostly its context read over and over.

There are no prices and no currency. Tokens and seconds are facts, and what
they cost is your own arithmetic. Each job's cost goes to the phase its run
is in: build, rework, verify (audits too) or merge. CI watched inside a build
job counts as building. Below the total, the line splits the cost by those
phases. On an epic it adds its subcards: their lead times added up, and what
was spent on them and on the epic's own jobs.

The cost is counted when it is read, and kept on the job. It is counted
again only when the log has grown. A log is counted before the retention
sweep deletes it, so the cost outlives the log. A job whose runner sent no
log has no cost.

The same is on `slipdock card` (`Lead time:` and, on an epic, `Subcards:`),
on `GET /api/cards/:id` and MCP `get_card` as `lead_time` (`seconds`, `ends`,
`phases`, `cost` with `total` and `phases`, each with `model_seconds`,
`tool_seconds`, `jobs` and `tokens` only when known, and `rollup` on an
epic; left out on a card no job was sent on that isn't an epic), on
[the ledger](the-ledger.md) line (`lead_time.cost`), and in the card
chat's `card_lead_time`.

---

← [Waiting on a person (waits)](waiting-on-a-person-waits.md) · [Contents](../manual.md) · [Visualise: flow, velocity, runners and delivery](visualise-flow-velocity-runners-and-delivery.md) →
