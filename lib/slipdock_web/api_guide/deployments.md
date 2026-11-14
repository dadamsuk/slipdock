
## Deployments

A board can record its project's deploys and report how it delivers — the
DORA numbers: deployment frequency, lead time for changes, change failure
rate, time to restore and rework rate, and idea to production (a card first
in progress → the first deploy whose commits name it). Off on every board
until its owner turns **Delivery metrics** on (settings, PATCH
`delivery_metrics`, `slipdock set-board B --delivery-metrics`); while off,
deploys are refused and the report says so.

Deploys are a ledger, not cards. CI records them with the board's **deploy
token** (`sdd_…`, which records deploys and can do nothing else), usually by
wrapping the deploy command: `slipdock deploy run --env production --
./deploy.sh`. The token goes to `GET /api/deployments/last?environment=E`,
`POST /api/deployments` (with an optional `note`, a line up to 500
characters such as how the suite passed: `slipdock deploy run --note`) and
`PATCH /api/deployments/:id` and `POST /api/deployments/failed` only.
A release that fails before or during its deploy records it from a CI
job that runs on the failure: `slipdock deploy failed --env production
--stage build|test|merge|deploy|health --run-url <the run>` (`POST
/api/deployments/failed` with `environment`, `sha`, `stage`, `run_url`
and `commits`); the deploy job's own record of the attempt, when it made
one with the same run url, is the one marked. A card whose latest deploy
attempt failed carries `deploy_failed` (*Deploy failed at build ·
production · <run url> · 11 Nov 20:41*) until a succeeded deploy naming
it; a build, test or merge failure is no deploy to DORA. Commits name
cards as `#123` (or the board's `card_ref_pattern`); a card a succeeded
deploy names gets a **Shipped to production** line (`shipped` on
`get_card`, each with its `text`: *Shipped to production · 1a2b3c4 · 6
Nov 14:32*, the time in your time zone) and the step status *Shipped
to production*.

**Batched releases** (#2833). A board's `release_mode` is `on_merge`
(each merge deploys; the default) or `batched` (a merge waits for a
release), and `release_age_cap_hours` is how long the oldest waiting
merge may wait before it triggers one (`null` is off). Both are the
tree's, set on its root board only (`PATCH /api/boards/:board`,
`update_board`, `slipdock set-board B --release-mode batched
--release-age-cap 24`, the Agentic Building page) and read back on every
board of the tree. On a batched board a merged card still completes and
unblocks its dependents; its `release` (card JSON and `get_card`, the
*Release* line in `slipdock card`) is `awaiting` (*Merged 1a2b3c4,
awaiting release · since 12 Nov 10:04*) until a succeeded deploy names
it, then `released` with the environment and the time. A card is done
when it merges: an agent neither waits for its release nor fires one,
and *Release now* is how a person ships.

A release is asked for, one at a time per tree. Three things ask: a
card of priority `critical` merging; **Release now** (`POST
/api/boards/:board/release`, `slipdock release B`, MCP `release_now`,
the button on the board's release banner and the Agentic Building page:
the board owner's); and the age cap. The answer's `how` is `started`,
`queued` (one is running: this is the single follow-up) or `joined`
(a follow-up was queued already), with the `request` (`status`
`queued`, `running`, `released`, `failed` or `timed_out`; `triggers`,
each `trigger` `critical`, `manual` or `age_cap` with `by` and `at`;
`card_ids`; `job_id`; `run_url`; `note`) and the tree's `release`
status. `GET /api/boards/:board/release` (`slipdock releases B`,
`release_now` with `check: true`) reads that status alone: `mode`,
`running`, `queued`, `last` and the cards `awaiting`. It is the whole
tree's: asked of a sub-board, it needs read on the root board too
(`403`). A board that releases on merge answers `409`.

A request starts a runner job of kind `release`, with no card, for the
pool that merges: its prompt is the root board's `release_command`
(set like the other two; `set-board --release-command "…"`, `default`
to clear), one line, by default `gh workflow run release.yml --ref
{default_branch}`, the runner putting the repository's default branch
in. Lanes and WIP limits never hold it, and it goes only to runners
whose claims list `release` in `X-Runner-Kinds`. `release` jobs are
built into the runner daemon, as `merge` jobs are (`no_release: true`
in the machine's `local.json` turns the kind off): it runs `gh
workflow run <workflow> --ref <branch>` itself and logs `release: run
<url>`, the run it started. Any other command runs only when the
machine's `local.json` lists it under `release_commands`; the daemon
refuses the rest, so a custom command is set on the board and allowed
on the machine. The runners list's `missing_kinds` names `release` on
a batched tree for a runner that merges but hasn't said it releases.
The request ends
`released` when a deploy of the tree is recorded as succeeded (or when
the job is done, on a tree with delivery metrics off, where the cards
it covered then read `released` with no `environment`), `failed` when
the job or the deploy fails, and `timed_out` after 3 hours with
neither; then the follow-up starts. After a failed or timed-out
release the age cap asks for nothing until a person or a critical
merge has released. Each step is a line in the root board's activity.

**Merged, not shipped** (#2819). A pipeline that fails before its deploy
job records nothing, so the server notices by itself: a card done and
accepted with a `merge_sha` (ship by pull request) or the commit it was
accepted at (ship by push) that no succeeded deploy names once the
board's `not_shipped_minutes` have gone by (20; PATCH the board, or
`slipdock set-board B --not-shipped-minutes N`; 0 never) carries
`not_shipped` on `GET /api/cards/:id` and `get_card`: `text` (*Merged
1a634c6 · not shipped after 45m*), `sha`, `merged_at`, `seconds` and
`minutes`; `slipdock card` shows it as *Not shipped*. The root board gets
one warning alert (the watch check `not_shipped`) and its owner an
email. A succeeded deploy naming the card clears both. It runs whether
or not the overseer is on. Only cards merged after the board turned
delivery metrics on count; an epic, a card with no commit, a stand-in
and an archived card never do. On a tree with batched releases the
minutes count from the card's release, not its merge (#2839): from the
start of the latest release request that covered it, whatever became
of that release. A card only awaiting release carries no `not_shipped`
and raises nothing, however long it waits; one whose release started
and brought no deploy carries it with `release_requested_at`, `seconds`
counted from then, and the `text` *Merged 1a634c6 · not shipped 45m
after its release started*.

**A red release holds releases** (#2838). A failed deploy recorded on a
batched tree (a release's suite, build or deploy failing: `slipdock
deploy failed --stage S`) sets the root board's hold: the status's
`hold` (`reason`, `stage`, `run_url`, `sha`, `deployment_id`,
`card_ids`, the batch, `fix_card_id`, `held_at` and `text`; null while
releases run). Slipdock files one card of priority `critical` (origin
`release`) on top of the root's ready list, naming the batch's cards
and linking the failing run. Held, *Release now* is refused (`409`,
the refusal saying why with the run), the age cap asks for nothing, a
queued follow-up is dropped, and a critical card that isn't the fix
card asks for nothing (the board's activity says so). When the fix card
merges the hold lifts and its critical trigger releases. When it is
accepted with no code (`evidence_no_code`: the cause was outside the
repository) the hold lifts and nothing is released: the held batch goes
at the next trigger (*Release now*, a critical merge or the age cap).
A deploy that
succeeds to the held environment at the hold's `sha`, or with it among
its `commits` (the failed run rerun, or a later release), lifts it too
(#2996), with a line in the board's activity: the fix card is archived
if it is still in the ready list with no job, else commented on and left
open. A second red
release while held keeps the first hold and files no second card. The
owner lifts it by hand with `DELETE /api/boards/:board/release/hold`
(`slipdock release B --lift-hold`, MCP `release_now` `lift_hold: true`,
*Lift hold* on the board's release banner and the Agentic Building
page): `200` with the hold `lifted`, `409` when nothing is held; it
releases nothing. A release job that failed to fire, a backfilled
deploy and a board that releases on merge hold nothing.

Incidents are ordinary cards tagged `incident` (the board's `incident_tag`),
optionally linked to the deploy that caused them: `POST
/api/cards/:id/incident-of {"deployment": N}`, `slipdock incident-of`. A
deploy is a failed change when it failed, was rolled back, has an incident
linked, or was followed within the hotfix window (24h) by a deploy naming an
incident card.

Read the numbers with `get_board` `dora: true` (`environment`, `days`),
`GET /api/boards/:board/dora` or `slipdock dora B`. Set a board up with
`POST /api/boards/:board/deployments/setup {"ci": "github"}` (owner; turns
the switch on and returns a new token once, with the step to paste) or
`slipdock deploy setup B`. To wire a repository up yourself, this is the
brief:

<%= @setup_prompt %>
