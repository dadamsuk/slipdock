[Slipdock — the manual](../manual.md)

## Roll-ups, the outline and My work

A board, its cards' sub-boards and their sub-boards form a tree, and the
tree is meant to be read at different resolutions: a quarterly roadmap at
the top, a team's delivery plan a level down, individual tasks at the
leaves. Rather than keeping three lists in sync by hand, the leaves are the
source of truth and everything above them is derived.

Every card carries a **roll-up** of what lies beneath it: leaves done out of
leaves in all (through every level, not just the next); its **effective
dates** — its own start and due, or, when it has none, the earliest start and
latest due of its subcards; whether anything beneath is blocked or overdue;
and a **health** of *done*, *blocked*, *at risk* or *on track*. When a card has
a due date of its own and its subcards run past it, the card shows the
**slip** (`+5d`): the gap between the plan and what the work implies. Rolled-up
dates are drawn dashed with a stack icon wherever they appear, and the card
modal spells out the subcards' range under the date fields.

**An epic's comments tell its story.** When something happens to a subcard,
the server posts a line on the epic (the top-level card above it, however deep
the subcard sits): what happened, to which subcard, and the epic's done count.
The lines are the server's, with no author, and read like this:

```
**Started** · #1794 Triage list · by runner build-1, job #641 · 1/3 done
**Submitted** for verification · #1794 Triage list · PR #121 · `07b96ef` · 1/3 done
**Accepted and merged** · #1794 Triage list · PR #121 · `aedf656` · 2/3 done
```

- **Started** when a subcard moves into a doing list, with who moved it and
  which runner job.
- **Submitted** for verification, with its pull request and commit;
  **Rejected** with the first line of the reason (a failed merge too).
- **Accepted** and **Merged** with the pull request and short commit; a merge
  within a minute of its acceptance rewrites that line as one **Accepted and
  merged**. **Done** on a board that doesn't verify.
- **Build failed** when a comment on the subcard reports a red build (it opens
  with `Build failed`).
- **Waiting on a person** when a wait opens on it, **Answered** (or **Wait
  skipped**) when it closes.
- **Shipped** when a deploy the board records names subcards of the epic.

The epic's own submission, rejection, acceptance and merge (its wrap-up pull
request) post the same lines as "the epic itself". A card under no epic posts
nothing. On a busy epic, consecutive lines within 10 seconds share one comment
rather than one each; a comment from anybody else in between starts a new one.
An agent working the epic leaves these to the server and comments only what
the server can't know: its decisions, surprises, dead ends and changes of plan.

The epic's **% complete** follows its subcards (done ÷ all, rounded down) on
every change, whatever an agent set it to. Set it by hand and it stays as you
set it; clear it and it follows its subcards again.

The **Outline** view shows a board as a collapsible tree — each card with its
subcards indented beneath it, with list, progress bar, schedule and health per
row. The **levels** control limits the depth: one level is the roadmap, all
levels the task list; rows on deeper boards link into those boards, and the
*more* button on a cut-off row opens the board beneath it. Filters, search and
sort work as in the other views; a card that fails a filter is kept, muted,
when something beneath it matches. The **+** beside a card's title (shown on
hover, always on a touch screen) opens a row under it for adding subcards; a
card with none yet gets its subcards board, from the *Simple* template, with
the first one. A long outline is paged at 250 rows (a collapsed card counts
as one), with Previous, Next and the page count under the list. A card stays
on one page with all of its subcards where they fit, so a page ends between
top-level cards; only a card with more than a page beneath it is split, and
the next page starts with the cards above again, marked *continued*. The same levels control on the
**Timeline** nests subcards under a card's bar (see above). On swimlanes and
tables, the *Due (rolled up)* axis groups cards by their effective due date,
and the table has *Assignee* and *Health* columns.

Cards can be **assigned** to a user from the card modal, or by dragging on an
*Assignee* swimlane axis. **My work** (`/work`, in the account menu) lists
every card assigned to you on any board at any depth, grouped by due date
(overdue, today, next 7 days, later), each with its path — root
board › parent cards — and a link straight to it. Open cards with no due
date aren't listed: the header says how many there are (`2 have no due date
and aren't listed`), and when they are all you have, the page says *Nothing
with a due date* rather than *Nothing assigned to you*. A completed card,
dated or not, is under *Show completed*. The page alone leaves them out:
the API (`/api/work`), `slipdock work`, the MCP tools and the AI chat about
your work still see every assigned card, so a plan made there misses none. Above them, **Waiting on
you** lists what needs you, oldest first ([waits](waiting-on-a-person-waits.md)).

---

← [Sprints](sprints.md) · [Contents](../manual.md) · [Roadmapping](roadmapping.md) →
