[Slipdock — the manual](../manual.md)

## Sprints

A sprint is made of things a board already has: a card for the sprint, its
dates for the sprint's dates, and its subcards for the sprint's work. What a
sprint board adds is the setting up.

**A sprint board.** Make a board from the **Sprint planning** template
(Planned · Active · Closed), or tick **Sprint board** in an existing board's
settings. Every card on it is a sprint.

**New sprint.** The button in a sprint board's header opens a short form,
already filled in: the next name ("Sprint 4", counting on from the highest
"Sprint N" on the board), a start the day after the last sprint ends (today
when there is none), a length — 14 days unless you change it — and an
optional goal, which becomes the card's description. Creating it makes the
card in the first to-do list, gives it its own board of subcards (the Simple
template's To Do · Doing · Done), and goes straight on to picking its cards.

**Where sprints are planned from.** Sprints on one board almost always draw
from the same few lists — a team's backlog, an epic board's To Do. Choose
them once: when making a board from the Sprint planning template, **Plan
sprints from** lists the boards you can write to; tick a board, then, if you
want only some of its lists, tick those (none ticked means every list that
is not done or dropped). The same choice is under **Plan sprints from** in
the board's settings, and behind **Sources** in the picker; changing it takes
write access to the sprint board itself. Over the API it is
`PUT /api/boards/:board/sprints/sources`; on the command line `slipdock
sprint-sources <board> work:"To Do",Backlog home`.

**The plan.** With sources chosen, **Add cards…** opens on the plan: every
source list at once, grouped by board, each open card on a row with its
priority, the board's formula scores (RICE, ICE, value ÷ effort or your
own), votes, estimate — its own, or **Σ** what its open subcards add up to —
how far its subcards have got, and its due date. A card with subcards opens
in place with the chevron, as in the outline view, and its tasks can be
ticked on their own. **Order** puts each list in board order, or by score,
priority or estimate. As you tick, the foot keeps count: the cards and hours
ticked, what the sprint already holds, and the two together over the
sprint's days (a task inside a ticked epic is not counted twice). **Other
boards…** switches to the board-by-board picker below for anything outside
the sources; ticks are kept between the two. `slipdock sprint-plan
<sprint-id>` prints the same plan.

**Add cards… without sources.** On a sprint — the button in its card's
Subcards section, or in the header of the sprint's own board — with no
sources chosen this opens a picker. Choose a board
you can write to and its lists appear, each open card with a tick box and
each list with **tick all**. A card that has subcards has a **subcards ›**
button to step into them, which is where an epic's tasks are. Ticks are kept
while you move between boards, so one sitting can draw from several; **Add to
sprint** moves everything ticked into the sprint's first to-do list. Nothing
needs doing in one go: open the picker again whenever there is more.

Picked cards are *moved*, exactly as [Moving a card to another
board](calendar.md#moving-a-card-to-another-board) does it — subcards, comments and
history go with them; tags travel by name; custom fields only where the
sprint's tree has the same one. Completed and archived cards are not
offered. On a sprint board itself the cards are other sprints, so they cannot
be ticked whole; step into one to take what it left unfinished.

**Stand-ins.** A card picked into a sprint leaves a *stand-in* in the slot it
came from — a dashed tile with the card's title, the sprint it is in and a
status badge (To do, In progress, Done, Dropped) — so whoever put it on that
board does not lose track of it. Nothing on the stand-in is its own: the
title, the sprint and the status are read live from the real card, the
status from its list's category rather than its list's name, so the two
boards' lists need not match. Clicking it opens the real card on the sprint's
board, where its comments, checklist and history are; somebody who can see
the board it left but not the sprint still sees the title and status, but
cannot open it.

A stand-in can be dragged about its board and dismissed with its **×**, but
not edited. It is not work: it does not count towards a list's WIP limit, the
account's allowance, a parent's rollup or a sprint's burndown, it is not
offered for sprints or found by search, and automations ignore it. When the
real card reaches a done list, its stand-in moves to the done list of its own
board. A card carried over into the next sprint leaves no second stand-in —
the first one already follows it. Moved back to the board it came from, the
card takes its stand-in's slot and the stand-in goes. If the real card is
archived or deleted, the stand-in says so and waits to be dismissed. Exports
leave stand-ins out.

**Charts.** The **Charts** button in a sprint board's header, or in the
header of a sprint's own board, opens two charts (anyone who can read the
board can see them):

- **Burndown** — a sprint's work still open at the end of each day from its
  start to its due date, against a dashed ideal line falling straight to
  zero. The work is the cards on the sprint's own board, not archived; the
  scope is what is in the sprint now, so a card added halfway counts from
  the first day. Days still to come are left blank. On the sprint board it
  opens on the sprint running today (else the latest to have started), and
  **Burndown for** switches to another.
- **Velocity** — on the sprint board only: for each sprint, oldest first,
  the cards committed (everything in it) beside the cards completed, and a
  dashed line at the average of the finished sprints. A sprint counts as
  finished once it is completed or past its due date; a running one's bar is
  paler.

Both read when each card was completed, which a card records from the moment
it is ticked done (or lands in a done list) and forgets when it is reopened.
Cards completed before this was recorded use the last time they changed.

---

← [A board's default view](a-boards-default-view.md) · [Contents](../manual.md) · [Roll-ups, the outline and My work](roll-ups-the-outline-and-my-work.md) →
