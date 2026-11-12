[Slipdock — the manual](../manual.md)

## Batched releases

Merging and releasing are separate. A board tree's **release mode** says
how merged work reaches production: `on_merge`, where each merge deploys
(the default), or `batched`, where merges wait for a release. With it goes
an **age cap** in hours: how long the oldest waiting merge may wait before
it triggers a release (blank is off).

Both belong to the tree, so they are set on its root board: the Agentic
Building page's *Releases* section, `slipdock set-board <board>
--release-mode batched --release-age-cap 24` (`on-merge`, and `off` for
the cap, put them back), `PATCH /api/boards/:board {"release_mode":
"batched", "release_age_cap_hours": 24}` or MCP `update_board`. A
sub-board shows its root's, read-only, and refuses its own with a message
naming the root. Every board's JSON reads the tree's back
(`release_mode`, `release_age_cap_hours`), `list_boards` gives a batched
tree's as `release`, and a portable export carries them.

**Why batch.** One card, one release costs a post-merge suite, an image
build and a deploy for every card, which on a private repository is paid
CI minutes each time. Batching the merges instead would hold
[lanes](lanes.md) longer and bring conflicts back, so merging stays as it
is ([Shipping by pull request](verified-work.md#shipping-by-pull-request)):
a card is verified, accepted and merged straight away, and only the
release waits.

**A card is done when it merges.** Batched changes nothing about when a
card is done. A card still completes when it merges, and what depends on
it unblocks then: an agent's work on it is over, and it never waits for
the release or fires one. Releasing is the board's: a trigger below, and
*Release now* is how a person ships. What batched adds is the card's **release
state**, worked out when the card is read:

- *Merged 1a2b3c4, awaiting release · since 12 Nov 10:04*: it has merged
  and no succeeded deploy names it yet;
- *Released to production · 12 Nov 14:32*: a succeeded
  [deploy](delivery-metrics-deploys-and-dora.md) names it.

It is on the card's panel, the *Release* line of `slipdock card`, and
`release` in the card's JSON and `get_card` (`state` `awaiting` or
`released`, `sha`, `merged_at`, and once released `environment`,
`deployment_id` and `at`, with the line above as `text`). A board that
releases on merge, and a card that hasn't merged, have none.

**What starts a release.** On a batched board a release is asked for, and
three things ask:

- a card of priority `critical` merges;
- **Release now**: the button on the board's release banner and on the
  Agentic Building page, `slipdock release <board>`, `POST
  /api/boards/:board/release` or MCP `release_now`. It is the board
  owner's, as pausing is;
- the age cap: the oldest card awaiting release has waited
  `release_age_cap_hours`.

Releases run one at a time. A trigger that arrives while one is running
queues a single follow-up, and further triggers join that follow-up
rather than queueing more. The answer says which happened (`how`:
`started`, `queued` or `joined`). A critical release takes whatever else
has merged since the last one: each of those cards passed its own checks,
and the release tests the combined tip.

**Who fires it.** A request queues a [runner](runners.md) job of kind
`release`, with no card, for the pool that merges. Its prompt is the
board's **release command**: one line, set on the root board (the Agentic
Building page, `slipdock set-board <board> --release-command "…"`,
`release_command` over the API and MCP), by default `gh workflow run
release.yml --ref {default_branch}`, where the runner puts the
repository's default branch in. The runner daemon runs that `gh workflow
run` form itself; any other command runs only if the machine's own
`local.json` lists it, word for word, under `release_commands`, and is
refused otherwise, since the daemon never runs what the server sends (see
[Machines](machines.md)). Lanes and WIP limits never hold a release
job, and it goes only to a runner that says it takes `release`. The
server holds no credentials for your repository.

**Your release workflow.** On a batched board the release workflow is
what the release command starts, so it has to run on `workflow_dispatch`,
and a push to the default branch should deploy nothing. Slipdock's own
`release.yml` is the worked example (#2837): with the repository variable
`RELEASE_MODE` set to `batched`, a push to `main` runs none of its jobs and
takes no place in its one-at-a-time queue; a dispatch of `main` runs the
suite once on the tip, builds the image and deploys it, and a failed one
is recorded as a push's would be. Unset the variable to go back to a
release with each merge.

**How it ends.** The request is `released` when a succeeded deploy of the
tree is recorded, `failed` when the job or the deploy fails, and
`timed_out` when nothing is heard for 3 hours; then the follow-up starts.
On a board with delivery metrics off no deploy is ever recorded, so the
finished job is the release, and the cards it covered show *Released*
with its time. After a failed or timed-out release the age cap asks for
nothing more until a person, or a critical merge, has released.

**A red release holds releases.** When a release's suite, build or deploy
fails (a failed deploy recorded on the tree, `slipdock deploy failed
--stage S`), the tree's releases are held. The release banner says why,
with the stage and the failing run, and Slipdock files one card of
priority `critical` on top of the root board's ready list, naming the
batch's cards and linking the run. While held, *Release now* is refused
and says why, the age cap asks for nothing, a queued follow-up is dropped,
and a critical card that isn't the fix card asks for nothing (the board's
activity says so). When the fix card merges the hold lifts and its
critical trigger releases. A second red release keeps the first hold and
files no second card. The board's owner can lift the hold by hand: *Lift
hold* on the banner or the Agentic Building page, `slipdock release
<board> --lift-hold`, `DELETE /api/boards/:board/release/hold` or MCP
`release_now` with `lift_hold: true`; that releases nothing. A release job
that failed to fire, a backfilled deploy and a board that releases on
merge hold nothing.

`slipdock releases <board>` (`GET /api/boards/:board/release`,
`release_now` with `check: true`) shows the release running, the one
queued, the last that ended and the cards awaiting release. The status is
the whole tree's, so asking it of a sub-board needs read on the root board
too. Every step is a line in the root board's activity, naming who or what
asked and the cards covered.

**Merged, not shipped.** On a board with
[delivery metrics](delivery-metrics-deploys-and-dora.md) on, a merged card
no succeeded deploy names raises a warning alert and shows *Not shipped*
after the board's *Not shipped after* minutes (20). On a board that
releases on merge those minutes count from the merge. On a batched board
they count from the card's release, not its merge: from the start of the
latest release that covered it, whatever became of that release. So a card that is only
awaiting release is never *not shipped*, however long it waits (the age
cap is what bounds that wait), and one whose release started and brought
no deploy is: *Merged 1a634c6 · not shipped 45m after its release
started*, with `release_requested_at` beside `merged_at` in the card's
`not_shipped`. The alert says when the release started, and clears when a
succeeded deploy names the card.

---

← [Verified work](verified-work.md) · [Contents](../manual.md) · [Lanes](lanes.md) →
