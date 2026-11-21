[Slipdock — the manual](../manual.md)

## Table

The **Table** button shows one row per card. Click a header to sort by it
(again to flip the direction), choose which columns to show under
**Display** (list, priority, assignee, flags, tags, due, done, checklist,
comments, dependencies, subcards, cover, created, updated, id; title, list,
priority, assignee, tags, due and done to start with), and pick **Group by**
to split the rows into collapsible groups by any attribute, including date
buckets. List, priority, due date and done are edited in place: at rest a
cell reads as plain text, and its control (the select's caret, the date's
calendar and clear) appears when you point at the row or Tab to the cell.
Tab moves through the editable cells row by row. Due is one date coloured
by its state (overdue, due soon, done); a card with no due date of its own
shows its subcards' latest in muted italics. Tags stay on one line, the
first two and *+N*, with every tag in the tooltip, so rows are all one
height. On a phone the stacked rows keep their controls showing. The title
opens the card. The filter menu, search, density and saved views are shared
with the swimlane view, and a saved view remembers which of the two it was
made in. `slipdock table <board>` prints the same thing in the terminal.

**Custom fields as columns.** Each of the board's custom fields can be a
column (*Display*), and a writer edits its values in place, as on the card.
Whoever may change the board's fields (a writer of the tree's top board,
as in board settings) has a **+** at the end of the header: give the field
a name and a type (and a choice its options, and whether it allows
several), and it is added as a column
with its first cell ready to type in. Units, a formula's expression and
the rest are set in board settings.

---

← [Card views](card-views.md) · [Contents](../manual.md) · [Timeline](timeline.md) →
