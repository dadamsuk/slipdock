[Slipdock — the manual](../manual.md)

## Roadmapping

**List categories.** A list's settings give it a meaning: *to do*, *in
progress*, *done* or *dropped*. Dropping a card into a done list completes
it; moving it back into a to-do or in-progress list reopens it. Cards in a
dropped list count for nothing in roll-ups and show a *Dropped* health.
Templates carry categories, and the built-in templates mark their *Done*
lists.

**Horizons.** A list can stand for a date range (from, to, and the
precision to schedule at), so *Now · Next · Later* becomes *Q4 2026 · Q1
2027 · H2 2027*. A card dropped into a horizon list that isn't already
inside the range is given the range's end as its due date at that
precision; the list header shows the range, and a count of cards whose due
date has drifted outside it.

**Date precision.** A card's dates can be *day* (exact), *week*, *month*,
*quarter*, *half-year* or *year*. At anything but day the dates snap to
whole buckets (a quarter card runs 1 Jan – 31 Mar), the timeline draws a
soft-edged bar, and dragging moves it by whole buckets. On the card it is under
**More** in the sidebar while it is *day*, and its own row once it isn't.

**Milestones** are named dates on the root board (board settings), drawn
as a dashed line with a diamond on the timeline and as a chip on the
calendar of every board in the tree; the narrative view lists the ones
passed and coming up.

**Dependency lines.** The timeline connects each blocker's bar to the bars
it blocks; a connector turns red and dashed when the blocked card starts
before its blocker is done. The *Dependencies* filter has a *Dates
conflict* option for exactly those cards.

**Colour by.** Timeline and swimlane display options include *Colour by*:
cover colour (the default), list, priority, health, reported health,
assignee or first tag, with a legend in the toolbar.

**Status updates.** A card's health is computed from dates, blockers and
subcards; its owner can also *report* one — on track, at risk, off track —
with a note. The latest report is shown beside the computed health on
cards, in the table, outline and timeline, and the history is kept on the
card. Reports are logged, so they appear in the narrative.

**Step statuses.** On a card agents work, the server reports the step it is at
itself, as an *On track* update by *Slipdock*: *Writing code* when a runner
takes its build job (*Reworking after verify failed* after a rejection),
*Waiting for human* when a wait opens (*(rejection limit)* or *(held before
merge)* for the server's own), *Verifying* when it is submitted to a verify
pool (*Waiting for human to accept* with none), *Verify failed; queued for
rework*, *Accepted; merging*, *Merged*, *Done*, *Reopened* and *Shipped to
production*. The same step twice in a row is posted once. They are routine,
so they are quiet: no activity line, nothing in the narrative, nothing to
anyone following the card. A report a person writes is logged and shown as
before.

**Published views.** From the Views menu the board's owner can give a saved
view a public link (`/p/<token>`): anyone with it sees the board through
that view, live and read-only, without an account. Unpublish to withdraw
it. Timeline and calendar readers can page through dates; narrative readers
can change the range.

**CSV.** The table's *CSV* button downloads the visible columns for the
current filters, sort and grouping.

---

← [Roll-ups, the outline and My work](roll-ups-the-outline-and-my-work.md) · [Contents](../manual.md) · [Custom fields, scoring and votes](custom-fields-scoring-and-votes.md) →
